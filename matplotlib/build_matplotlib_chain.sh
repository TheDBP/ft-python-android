#!/bin/bash
# build_matplotlib_chain.sh - the cp314t-android CHART stack: kiwisolver, contourpy,
# pillow, matplotlib.
#
# WHY: charts cannot render on Android at all - verified on-device, the app ships
# numpy/scipy/cffi/soundfile and NO matplotlib, while core/charts.py imports it
# unguarded. matplotlib 3.11.1 pulls FOUR native wheels; the other five runtime deps
# (cycler, fonttools, packaging, pyparsing, python-dateutil) are py3-none-any and need
# no build.
#
# Follows the Option-B recipe in external_source/docs/BUILD.md verbatim:
#   1. _PYTHON_SYSCONFIGDATA_NAME + PYTHONPATH  -> target ABI without running aarch64
#   2. meson cross-file (NDK clang + pkgconf-wrap.sh --define-prefix)
#   3. python -m build --wheel --no-isolation   -> no cmake bootstrap
#   4. retag linux_x86_64 -> android_26_arm64_v8a (meson-python mislabels it)
#
# ! SDISTS ARE CURL'd, NOT pip download'ed. docs/BUILD.md: "`--no-binary`/`pip download`
#   for the sdist is a TRAP (bootstraps cmake-from-source); `curl` the sdist from PyPI
#   JSON instead." Measured here too: a `pip download` hung silently.
#
# UNATTENDED BY DESIGN: every package is independent, a failure NEVER aborts the chain,
# and each one's status lands in the summary at the end. A partial result is the point -
# the next session needs to know WHICH link broke, not that "the build failed".
set -u
export PATH="${FT_ROOT:?set FT_ROOT to your build root}/buildvenv/bin:$PATH"
FT="${FT_ROOT:?set FT_ROOT to your build root}"
TARGET=$FT/chaquopy/target/prefix/arm64-v8a
SRC=$FT/src
WHEELS=$FT/wheels
LOGS=$FT/logs-mpl
PLAT=android_26_arm64_v8a

export _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata_t_android_aarch64-linux-android
export PYTHONPATH=$TARGET/lib/python3.14t
export PKG_CONFIG_LIBDIR=$TARGET/lib/pkgconfig

mkdir -p "$SRC" "$WHEELS" "$LOGS"
STATUS=$LOGS/STATUS.txt
: > "$STATUS"

# ! RENDER THE CXX CROSS FILE - DO NOT READ IT IN PLACE. It is a TEMPLATE: it contains
#   ${NDK} and ${FT_ROOT}, and meson does not expand either. This script used to point
#   straight at $FT/toolchain/... and that path only ever existed because a
#   host-specific sync script copied the rendered file there. A clone does not have it
#   and a container does not have it, so contourpy and matplotlib both died with
#   "Cannot find specified cross file" while kiwisolver and pillow (setuptools, no
#   cross file) built fine - which makes it look like a meson problem rather than a
#   missing file. numpy and scipy already render their own; this now matches them.
recipe_dir=$(dirname "$(realpath "$0")")
CROSS_CXX="$FT/toolchain/meson-cross-android-arm64-cxx.txt"
mkdir -p "$FT/toolchain"
envsubst < "$recipe_dir/../toolchain/meson-cross-android-arm64-cxx.txt" > "$CROSS_CXX"
# Fail loudly here rather than 60 lines deep in a meson log.
if grep -q '\${' "$CROSS_CXX"; then
    echo "cross file still has unexpanded vars - are NDK and FT_ROOT exported?" >&2
    exit 1
fi

say() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$STATUS"; }

# ** PINNED VERSIONS. ** This chain used to resolve `info.version` from PyPI - whatever
# was newest on the day you ran it - so two runs a week apart produced different wheels
# from identical inputs. That is not a build, it is a snapshot of PyPI. These are the
# versions this chain is verified against; bump them deliberately and re-run the gates.
MPL_V=3.11.2; PILLOW_V=12.3.0; CONTOURPY_V=1.4.0; KIWI_V=1.5.1
version_of() {
    case "$1" in
        matplotlib)   echo "$MPL_V" ;;
        pillow)       echo "$PILLOW_V" ;;
        contourpy)    echo "$CONTOURPY_V" ;;
        kiwisolver)   echo "$KIWI_V" ;;
        *)            echo "" ;;
    esac
}

fetch() {   # fetch <pkg> -> echoes the extracted source dir
    local p=$1 url tarball dir v
    url=$(cat "/tmp/$p.url" 2>/dev/null)
    if [ -z "$url" ]; then
        v=$(version_of "$p")
        # ! Ask for the EXACT version endpoint, not /json (which answers "latest").
        [ -n "$v" ] || { say "$p: NO PINNED VERSION - refusing to guess"; return 1; }
        url=$(curl -s "https://pypi.org/pypi/$p/$v/json" \
              | python3 -c 'import sys,json;print([f["url"] for f in json.load(sys.stdin)["urls"] if f["packagetype"]=="sdist"][0])' 2>/dev/null)
    fi
    [ -z "$url" ] && return 1
    tarball=$SRC/$(basename "$url")
    [ -f "$tarball" ] || curl -sL "$url" -o "$tarball" || return 1
    dir=$SRC/$(tar tzf "$tarball" 2>/dev/null | head -1 | cut -d/ -f1)
    [ -d "$dir" ] || tar xzf "$tarball" -C "$SRC" || return 1
    echo "$dir"
}

build_one() {   # build_one <pkg> [extra -Csetup-args...]
    local p=$1; shift
    local dir log
    say "=== $p: fetching"
    dir=$(fetch "$p") || { say "$p: FETCH FAILED"; return 1; }
    log=$LOGS/$p.log
    say "=== $p: building from $(basename "$dir")"
    ( cd "$dir" && rm -rf build-android && \
      python -m build --wheel --no-isolation \
        -Csetup-args="--cross-file=$FT/android-arm64.txt" \
        -Cbuilddir=build-android "$@" -o "$WHEELS" ) > "$log" 2>&1
    local rc=$?
    if [ $rc -ne 0 ]; then
        say "$p: BUILD FAILED (rc=$rc) - last lines:"
        tail -12 "$log" | sed 's/^/      /' | tee -a "$STATUS"
        return 1
    fi
    # Retag: meson-python labels it linux_x86_64 though the .so is aarch64.
    local whl
    whl=$(ls -t "$WHEELS"/${p//-/_}-*linux_x86_64.whl 2>/dev/null | head -1)
    if [ -n "$whl" ]; then
        python -m wheel tags --platform-tag $PLAT --remove "$whl" >> "$log" 2>&1 \
            && say "$p: OK (retagged $PLAT)" || say "$p: built but RETAG FAILED"
    else
        say "$p: OK ($(ls -t "$WHEELS"/${p//-/_}-*.whl 2>/dev/null | head -1 | xargs -r basename))"
    fi
    return 0
}

build_one_cxx() {   # build_one, but with the pybind11-config cross-file (GOTCHA A)
    local p=$1; shift
    local dir log
    say "=== $p: fetching"
    dir=$(fetch "$p") || { say "$p: FETCH FAILED"; return 1; }
    log=$LOGS/$p.log
    say "=== $p: building from $(basename "$dir") [cxx cross-file]"
    ( cd "$dir" && rm -rf build-android &&       python -m build --wheel --no-isolation         -Csetup-args="--cross-file=$FT/toolchain/meson-cross-android-arm64-cxx.txt"         -Cbuilddir=build-android "$@" -o "$WHEELS" ) > "$log" 2>&1
    local rc=$?
    [ $rc -ne 0 ] && { say "$p: BUILD FAILED (rc=$rc) - last lines:"; tail -12 "$log" | sed 's/^/      /' | tee -a "$STATUS"; return 1; }
    local whl
    whl=$(ls -t "$WHEELS"/${p//-/_}-*linux_x86_64.whl 2>/dev/null | head -1)
    [ -n "$whl" ] && python -m wheel tags --platform-tag $PLAT --remove "$whl" >> "$log" 2>&1
    say "$p: OK"
    return 0
}

build_setuptools() {   # build_setuptools <pkg> [setup.cfg body]
    # ! THE SETUPTOOLS PATH. Not every package is meson: kiwisolver and pillow both
    #   build with setuptools, so the meson cross-file is NEVER READ for them (proven
    #   at an earlier build by kiwisolver's own log - `build/temp.linux-x86_64-cpython-314t/`, the
    #   setuptools convention). The toolchain has to arrive through the environment.
    #
    # ! LDSHARED, NOT LDFLAGS - this is the bit that cost an iteration. setuptools
    #   builds the shared-object link command from sysconfig's LDSHARED and does NOT
    #   append LDFLAGS to it, so `-lpython3.14t` set in LDFLAGS never appeared on the
    #   link line (measured: 0 occurrences) and kiwisolver died with pages of
    #   `undefined symbol: PyType_FromSpec`. Overriding LDSHARED puts the NDK linker
    #   AND the libpython on the command that actually runs.
    local p=$1 cfg=${2:-} dir log ndk
    say "=== $p: fetching"
    dir=$(fetch "$p") || { say "$p: FETCH FAILED"; return 1; }
    log=$LOGS/$p.log
    ndk=$FT/android-sdk/ndk/27.3.13750724/toolchains/llvm/prebuilt/linux-x86_64
    rm -f "$dir/setup.cfg"
    if [ -n "$cfg" ]; then
        printf '[build_ext]
%s
' "$cfg" > "$dir/setup.cfg"
    fi
    say "=== $p: building from $(basename "$dir") [setuptools cross]"
    ( cd "$dir" && rm -rf build &&       CC="$ndk/bin/aarch64-linux-android26-clang"       CXX="$ndk/bin/aarch64-linux-android26-clang++"       AR="$ndk/bin/llvm-ar" RANLIB="$ndk/bin/llvm-ranlib" STRIP="$ndk/bin/llvm-strip"       LDSHARED="$ndk/bin/aarch64-linux-android26-clang -shared -L$TARGET/lib -lpython3.14t -Wl,-z,max-page-size=16384"       CFLAGS="-I$TARGET/include/python3.14t"       LDFLAGS="-L$TARGET/lib -lpython3.14t"       python -m build --wheel --no-isolation -o "$WHEELS" ) > "$log" 2>&1
    local rc=$?
    [ $rc -ne 0 ] && { say "$p: BUILD FAILED (rc=$rc) - last lines:"; tail -12 "$log" | sed 's/^/      /' | tee -a "$STATUS"; return 1; }
    local whl
    whl=$(ls -t "$WHEELS"/${p//-/_}-*linux_x86_64.whl 2>/dev/null | head -1)
    [ -n "$whl" ] && python -m wheel tags --platform-tag $PLAT --remove "$whl" >> "$log" 2>&1
    say "$p: OK"
    return 0
}

say "chart-stack build starting; wheels -> $WHEELS"
# ! BUILD-TIME deps the first an earlier build run named explicitly. These are HOST tools/headers used
#   to generate the extension sources - they are NOT shipped in the wheel, so installing
#   them in the buildvenv is correct and does not contaminate the target.
#     kiwisolver  -> "Missing setup required dependencies: cppy"
#     matplotlib  -> "Missing dependencies: setuptools_scm<10,>=7"
python -m pip install -q cppy "setuptools_scm>=7,<10" >> "$LOGS/builddeps.log" 2>&1     && say "build deps (cppy, setuptools_scm): OK" || say "build deps: FAILED"
say "pure-python deps first (no build needed)"
# Pinned for the same reason as the compiled ones: these are SHIPPED in the app, so
# "whatever pip resolved that day" is not an acceptable answer to what is in it.
# --only-binary is the safe direction (a prebuilt wheel, no build backend invoked);
# it is --no-binary that is the documented trap.
python -m pip download --only-binary :all: --dest "$WHEELS" \
    "cycler==0.12.1" "fonttools==4.65.0" "packaging==26.3" \
    "pyparsing==3.3.2" "python-dateutil==2.9.0.post0" "six==1.17.0" \
    >> "$LOGS/purepy.log" 2>&1 \
    && say "pure-python: OK" || say "pure-python: FAILED (see purepy.log)"

# EASIEST FIRST, so a partial night still shows forward motion and the log says where
# it stopped. Each is independent - matplotlib is attempted even if a dep failed, because
# the FAILURE MODE is the information we want.
# ! kiwisolver got PAST the include problem once GOTCHA C was fixed (the
#   /usr/local/include/python3.14t symlink) and then failed at LINK:
#       ld.lld: error: undefined symbol: PyUnicode_FromString
#   That is the scipy recipe's third fix seen from the sysconfig side: the leaked/blanked
#   BLDLIBRARY means nothing puts -lpython3.14t on the link line. meson takes it
#   through cpp_link_args.
# ! kiwisolver is a SETUPTOOLS build, not meson - proven by its own log
#   (`build/temp.linux-x86_64-cpython-314t/`, the setuptools path convention). The
#   meson cross-file was never read, so GOTCHA D could not apply. It compiles fine
#   once GOTCHA C is in place; only the LINK needs -lpython3.14t, which the
#   setuptools path supplies through LDFLAGS.
build_setuptools kiwisolver || true
build_one_cxx contourpy || true
# ! ZLIB COMES FROM THE NDK SYSROOT. Disabling platform guessing (above) stops
#   Pillow adding the HOST /usr/include - which is what we want, because
#   features-time64.h -> bits/wordsize.h is not there for aarch64 - but it also
#   removes the only place it was finding zlib. The NDK ships both:
#     sysroot/usr/include/zlib.h
#     sysroot/usr/lib/aarch64-linux-android/26/libz.so
#   PNG is the one codec we actually need (matplotlib's Agg writes PNG through
#   Pillow), and PNG needs zlib - so this is not optional.
NDKSR="${NDK:?set NDK to the NDK root}/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
build_setuptools pillow "disable_platform_guessing = 1
include_dirs = $NDKSR/usr/include
library_dirs = $NDKSR/usr/lib/aarch64-linux-android/26
disable_jpeg = 1
disable_jpeg2000 = 1
disable_tiff = 1
disable_webp = 1
disable_lcms = 1
disable_xcb = 1
disable_imagequant = 1
disable_raqm = 1
disable_freetype = 1" || true
# ! matplotlib IS meson, and it resolves Python through sysconfig's paths.include
#   (/usr/include/python3.14t) - which GOTCHA C's INCLUDEPY symlink does not cover.
#   The cxx cross-file prepends the TARGET include so it wins the search order.
build_one_cxx matplotlib || true

say "=== chain complete. Wheels present:"
ls -1 "$WHEELS"/*.whl 2>/dev/null | sed 's/^/      /' | tee -a "$STATUS"
