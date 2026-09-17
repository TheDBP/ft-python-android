#!/usr/bin/env bash
# One-shot driver: runs all seven stages inside the image and copies the
# artifacts to /out. This encodes BUILD.md end to end — including the two
# between-stage steps that live in the prose, not in any single script
# (place the toolchain wrappers; unzip the numpy wheel into the target before
# scipy). The stage scripts themselves are unchanged and remain the truth.
set -euo pipefail

PY_VERSION="${PY_VERSION:?}"          # e.g. 3.14.7 (set in the image)
BUILD_NUM="${BUILD_NUM:-0}"           # Maven build number: target-<ver>-<BUILD_NUM>
VS="${PY_VERSION%.*}t"                # short free-threaded tag, e.g. 3.14t
RECIPE=/src
TARGET="${FT_ROOT}/chaquopy/target/prefix/arm64-v8a"

export PATH="${FT_ROOT}/buildvenv/bin:${PATH}"

log() { echo -e "\n\033[1;36m== $* ==\033[0m"; }

# ** SALVAGE THE LOGS ON THE WAY OUT, WHETHER OR NOT THE BUILD SUCCEEDED. **
# The stage scripts write detailed per-package logs inside the container, and the
# console only ever shows a 12-line tail. With `docker run --rm` - which is how this
# is documented and how everyone runs it - a failure destroys the one artifact that
# explains it, and the next step is to re-run the whole chain just to read a file.
# `set -e` means a failing stage jumps straight past the collection step, so this has
# to be a trap rather than a line at the end.
salvage_logs() {
    local rc=$?
    mkdir -p /out/logs 2>/dev/null || return $rc
    for d in "${FT_ROOT}/logs-mpl" "${FT_ROOT}/sf-build/logs" "${FT_ROOT}/logs"; do
        [ -d "$d" ] && cp -r "$d" /out/logs/ 2>/dev/null
    done
    [ $rc -ne 0 ] && echo "=== build failed (rc=$rc); stage logs saved to /out/logs ==="
    return $rc
}
trap salvage_logs EXIT

# The CPython Android build (and the packaging step) call `python3.14t` by name;
# a uv free-threaded venv may only expose `python`. Guarantee the name resolves.
if ! command -v "python${VS}" >/dev/null 2>&1; then
    ln -sf "${FT_ROOT}/buildvenv/bin/python" "${FT_ROOT}/buildvenv/bin/python${VS}"
fi

# Place the toolchain wrappers where the cross files / OpenBLAS expect them.
# OpenBLAS (stage 2) references $FT_ROOT/fc-android.sh and nothing else places
# it first; numpy/scipy re-place their own, which is harmless.
for w in fc-android.sh pkgconf-wrap.sh pybind11-config-cross.sh; do
    install -m 0755 "${RECIPE}/toolchain/${w}" "${FT_ROOT}/${w}"
done

# Memory-aware parallelism. The heavy scipy/numpy compiles OOM-kill the build on
# modest machines when ninja runs one job per core (measured: scipy at -j(all
# cores) SIGKILLs on a 16 GB host). Bound the job count by available RAM once here
# and thread it through: MAKEFLAGS caps the make-based stages (CPython), FT_JOBS
# the meson/ninja ones (numpy, scipy) and OpenBLAS. Override with FT_BUILD_JOBS.
JOBS="$(bash "${RECIPE}/toolchain/build-jobs.sh")"
export FT_JOBS="${JOBS}"
export MAKEFLAGS="-j${JOBS} ${MAKEFLAGS:-}"
# ⚠ EXPORTING MAKEFLAGS REACHES EVERY `make` IN EVERY STAGE, INCLUDING `make install`.
#   Install targets are the ones most likely to have missing internal dependencies,
#   because they are almost always exercised serially - CPython's installs libpython
#   while linking modules against it, and in parallel a module gets a half-written
#   library ("section header table goes past the end of the file"). This is a
#   container-only failure: the bare-metal runbook never sets MAKEFLAGS, so a stage can
#   be correct there and race here. Stages that install now clear MAKEFLAGS and pass
#   -j1 explicitly. If you add a stage that runs `make install`, do the same.
log "Parallel build jobs: ${JOBS} (memory-aware; override with FT_BUILD_JOBS)"

log "Stage: CPython ${PY_VERSION}t for Android"
"${RECIPE}/cpython/build-cpython-314t-android.sh" "${TARGET}" "${PY_VERSION}"

log "Stage: OpenBLAS (arm64, USE_OPENMP=0)"
"${RECIPE}/openblas/build_openblas.sh"

log "Stage: numpy"
"${RECIPE}/numpy/build_numpy.sh"

# BUILD.md step 4 prerequisite: scipy needs the cross-built numpy present in the
# target's site-packages. Unzip (tag-agnostic) the wheel we just produced.
log "  · installing cross numpy into the target for scipy"
SP="${TARGET}/lib/python${VS}/site-packages"
mkdir -p "${SP}"
NPWHL="$(ls "${FT_ROOT}"/wheels/numpy-*.whl | head -1)"
unzip -o -q "${NPWHL}" -d "${SP}"

log "Stage: scipy (Fortran via flang; OpenBLAS)"
"${RECIPE}/scipy/build_scipy.sh"

log "Stage: retag wheels + package the Chaquopy target"
"${RECIPE}/chaquopy/retag-wheels.sh"
MAVEN="${FT_ROOT}/maven/com/chaquo/python/target/${PY_VERSION}-${BUILD_NUM}"
rm -rf "${MAVEN}"
"${RECIPE}/chaquopy/package-target-ft.sh" "${MAVEN}" "${TARGET}"

log "Stage: chart stack (matplotlib, pillow, contourpy, kiwisolver)"
# Independent of stages 1-4 except that it needs the target prefix and the cross
# numpy already unzipped into the target's site-packages (done above, before scipy).
# It runs its OWN retag, so it does not depend on chaquopy/retag-wheels.sh.
"${RECIPE}/matplotlib/build_matplotlib_chain.sh"

log "Stage: audio chain (libffi/cffi, four codecs, libsndfile, soundfile)"
# Same shape as the chart stack: needs only the target prefix, so it is independent
# of OpenBLAS/numpy/scipy and of the chart stack. It hand-packs and tags its own
# soundfile wheel rather than going through chaquopy/retag-wheels.sh.
"${RECIPE}/audio/build_audio_chain.sh"
# ! GATE IT HERE, not at collection time. A libsndfile built without external libs
#   still builds and still passes an alignment check - it just cannot decode FLAC.
#   Failing the build is the point: a codec-less wheel that reaches /out looks
#   identical to a good one.
"${RECIPE}/audio/verify_audio_chain.sh"

log "Stage: strip build-machine RUNPATH from every shipped .so"
# Cross-linking bakes the target prefix into each module as DT_RUNPATH, so wheels ship
# with the absolute path of the machine that built them. Not a loading bug on Android -
# those directories do not exist, so the linker skips them and falls through to the
# app's native library directory - but a binary should not depend on WHERE it was built.
# ! Runs BEFORE the alignment gate ON PURPOSE. patchelf rewrites ELF headers and is
#   entirely capable of disturbing segment alignment, which would be a far worse
#   regression than the paths it removes. The 16 KB gate immediately after is what
#   proves it did not.
"${RECIPE}/toolchain/strip_build_rpath.sh"

log "Collecting artifacts into /out"
mkdir -p /out/wheels /out/target
cp "${FT_ROOT}"/wheels/*android_*_arm64_v8a.whl /out/wheels/ 2>/dev/null || true
cp "${MAVEN}"/target-*.zip "${MAVEN}"/*.pom      /out/target/ 2>/dev/null || true

log "Gate: every expected artifact is present"
# ** WHY THIS EXISTS. ** The chart stack is unattended BY DESIGN: one package failing
# never aborts the others, because knowing WHICH link broke is worth more than stopping
# at the first. That is the right behaviour for that script - but it means a stage can
# fail while the chain carries on, and until this gate existed the build then exited 0
# with a wheel missing. Observed exactly that: matplotlib failed, every other stage
# passed, both other gates passed (they only look at what IS there), and the run
# reported success while shipping an incomplete set.
#
# A gate that checks the artifacts it FINDS cannot notice the one that is absent. This
# is the only check here that knows what SHOULD exist.
missing=""
for w in numpy scipy matplotlib pillow contourpy kiwisolver cffi soundfile; do
    ls /out/wheels/${w}-*.whl >/dev/null 2>&1 || missing="${missing} ${w}"
done
for t in target-*-arm64-v8a.zip target-*-stdlib.zip target-*-stdlib-pyc.zip; do
    ls /out/target/${t} >/dev/null 2>&1 || missing="${missing} ${t}"
done
if [ -n "${missing}" ]; then
    echo "ARTIFACTS MISSING:${missing}"
    echo "A stage failed without aborting the chain. Check /out/logs for which one."
    exit 1
fi
echo "all 8 wheels and the Chaquopy target are present"

log "Gate: 16 KB page alignment across every collected wheel"
# Android 15+ can use 16 KB pages; a 4 KB-aligned .so will not load there, and nothing
# earlier in the build notices. Run it over /out rather than per-stage so it sees
# exactly what ships - including anything a stage retagged or repacked on the way out.
# ! Invoked THROUGH the interpreter, not by path. A .py called directly needs both a
#   shebang and the exec bit, and the exec bit is a file property no gate in this repo
#   measures - three stage scripts shipped 644 and would have died on Permission denied.
#   `python3 <file>` has neither dependency.
python3 "${RECIPE}/toolchain/check_16kb_align.py" /out/wheels

echo
echo "=== DONE — artifacts in /out ==="
find /out -type f -printf '  %p  (%s bytes)\n' 2>/dev/null || find /out -type f
