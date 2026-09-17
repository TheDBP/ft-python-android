# Build guide

Derived from the scripts in this repo. **It documents what they do, not an idealised
process** - if a step here disagrees with a script, the script is the truth.

> **Don't want to set any of this up by hand?** The Docker image
> ([`docker/README.md`](../docker/README.md)) bakes this entire environment and runs all
> the whole chain for you. This guide is the reference for the bare-metal path and for
> understanding what each stage actually does.

## Host assumptions

**Any x86_64 Linux with a glibc of 2.35 or newer.** Debian/Ubuntu package names are used
below because that is what the commands were captured on; translate them for your
distribution. Also required: Android **NDK r27c** (`27.3.13750724`) and a `flang-new`
build that can target Android.

> **On WSL2** this runs unmodified - it is ordinary Linux to every stage here. One
> caveat, and it is a real one: keep `FT_ROOT` on the WSL filesystem (`$HOME/...`), not
> under `/mnt/`. Builds on a `/mnt/` path are slow enough to look hung, and some stages
> need POSIX permissions the Windows filesystem driver does not reproduce.

Set the three variables first (see `env.example`):

```bash
export FT_ROOT="$HOME/ft-build"
export NDK="$FT_ROOT/android-sdk/ndk/27.3.13750724"
export FLANG_CACHE="$HOME/.cache/cibuildwheel"
```

Everything lands under `$FT_ROOT`. The tree gets to several GB; none of it belongs in git.

## Memory and parallelism

**Supported RAM floor: ~8 GB; 16 GB+ recommended.** scipy's C++ compiles (ducc0/pocketfft)
are RAM-heavy - roughly **2 GB per parallel compile job**. Running one job per core will
**OOM-kill the build** on a modest machine (measured: scipy at `-j`(all cores) SIGKILLs on a
16 GB host, with no error - just a sudden stop).

The build **auto-tunes** the job count from available memory so this doesn't happen:
`toolchain/build-jobs.sh` computes `jobs = clamp(1, nproc, floor((MemAvailable - 2 GB) / 2 GB))`,
and `docker/build-all.sh` threads it through every stage (`MAKEFLAGS` for the make-based
CPython/OpenBLAS stages, `-Ccompile-args=-jN` for the meson/ninja numpy+scipy stages). More
RAM ⇒ more parallel jobs ⇒ a faster build; less RAM ⇒ fewer jobs, but it still finishes.

Override the model when you know better (CI, a `--memory`-capped container whose cap
`/proc/meminfo` does not reflect, etc.):

```bash
FT_BUILD_JOBS=4 ...        # force an exact job count
FT_JOB_HEADROOM_GB=3 ...   # leave more RAM free (default 2)
FT_MEM_PER_JOB_GB=3 ...    # budget more RAM per job for a very heavy machine (default 2)
```

## 0. Sources this repo does NOT carry

Found by a clean-environment run - each stage assumes these exist:

```bash
git clone https://github.com/chaquo/chaquopy "$FT_ROOT/chaquopy"   # tested @ f004380
git -C "$FT_ROOT/chaquopy" checkout f004380
# THE LOAD-BEARING STEP a clean checkout misses: Chaquopy needs free-threading
# enablement - 9 files (the target build helpers AND the runtime's FT
# compatibility). Captured from the working tree as one patch:
git -C "$FT_ROOT/chaquopy" apply "$(pwd)/chaquopy/ft-enable.patch"
# OpenBLAS 0.3.34 source, unpacked:
mkdir -p "$FT_ROOT/openblas-build" && cd "$FT_ROOT/openblas-build"
wget -qO- https://github.com/OpenMathLib/OpenBLAS/releases/download/v0.3.34/OpenBLAS-0.3.34.tar.gz | tar xz
# numpy / scipy source trees under $FT_ROOT/src/ (versions the drivers cd into)

# The NDK, by direct zip (no sdkmanager, no Java). CPython's android-env.sh
# checks for sdkmanager's package.xml - stub it or the build tries to reinstall:
cd "$FT_ROOT"
wget -q https://dl.google.com/android/repository/android-ndk-r27c-linux.zip
unzip -q android-ndk-r27c-linux.zip && rm android-ndk-r27c-linux.zip
mkdir -p android-sdk/ndk && mv android-ndk-r27c android-sdk/ndk/27.3.13750724
touch android-sdk/ndk/27.3.13750724/package.xml
export ANDROID_HOME="$FT_ROOT/android-sdk"      # cpython's android-env.sh requires it

# The HOST build-python (the buildvenv the drivers put on PATH): a free-threaded
# host 3.14 of the SAME version you pass the cpython driver, plus the build tools.
curl -LsSf https://astral.sh/uv/install.sh | sh
uv python install 3.14t
uv venv --python 3.14t "$FT_ROOT/buildvenv"
uv pip install --python "$FT_ROOT/buildvenv/bin/python" pip build meson meson-python ninja cython
sudo apt-get install -y patchelf     # meson-python needs it for wheel fixups
sudo apt-get install -y cmake autoconf automake libtool   # stage 7 (audio) only:
                                     # the codecs and libsndfile are cmake projects,
                                     # libffi is autotools. Not implied by build-essential.
export PATH="$FT_ROOT/buildvenv/bin:$PATH"
```

All of the above was PROVEN by a clean-environment run (fresh WSL 24.04): stage 1
produces `libpython3.14t.so` + `python3.14t` with exactly this preparation. The
driver builds free-threaded BY DEFAULT; `DISABLE_GIL=0` gets the stock build.
```

## 1. CPython 3.14t for Android

```bash
cpython/build-cpython-314t-android.sh <PREFIX> <VERSION>
```

Takes a prefix and a version; produces the free-threaded target under
`$FT_ROOT/chaquopy/target/prefix/arm64-v8a`. This is Chaquopy's own target-build recipe
with free-threading enabled.

## 2. OpenBLAS

```bash
openblas/build_openblas.sh
```

Expects `OpenBLAS-0.3.34` unpacked at `$FT_ROOT/openblas-build/OpenBLAS-0.3.34`. Builds
with `CROSS=1 TARGET=ARMV8 HOSTCC=gcc USE_OPENMP=0 NUM_THREADS=8`, using
`aarch64-linux-android24-clang` and `toolchain/fc-android.sh` as the Fortran compiler.
Installs to `$FT_ROOT/openblas-android`.

> `USE_OPENMP=0` is deliberate. You are running a free-threaded interpreter; an OpenMP
> runtime underneath it is a second, competing thread pool.

## 3. numpy

```bash
numpy/build_numpy.sh
```

Needs `$FT_ROOT/buildvenv/bin` on `PATH` (the host-side build tools: meson, ninja, cython,
the cross `numpy-config`). The three environment variables that make cross-compilation
work are set inside the script:

* `_PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata_t_android_aarch64-linux-android` - the `_t`
  is the free-threaded ABI. **Get this wrong and you silently build for the wrong ABI.**
* `PYTHONPATH` -> the target's `lib/python3.14t`
* `PKG_CONFIG_LIBDIR` -> the target's `lib/pkgconfig`, so meson finds the cross libraries
  and not the host's

Cross file: `numpy/meson-cross-android-arm64.txt` (targets API 24).

## 4. scipy

```bash
scipy/build_scipy.sh
```

Same environment as numpy, plus `OPENBLAS=$FT_ROOT/openblas-android`, and it needs the
numpy from step 3 already installed into the target (unzip the wheel into the target's
`lib/python3.14t/site-packages/`), PLUS host-side build deps in the buildvenv:

```bash
uv pip install --python "$FT_ROOT/buildvenv/bin/python"   numpy==2.5.1 "pybind11>=2.13.2,<3.1.0" "pythran>=0.18.1,<0.19.0"
```

The driver applies `scipy/patches/*.patch` after entering the source - currently the
ducc0 Android fix (Bionic has no `pthread_*affinity_np`; the guard gains
`!defined(__ANDROID__)`). Tested at scipy **1.18.0**.

Cross file: `scipy/meson-cross-android-arm64.txt` - note this one targets **API 26**, not
24, and points `fortran` at `toolchain/fc-android.sh`.

> **The Fortran story, fully reproducible from public sources.**
>
> ⚠ **Correction (this section used to be wrong).** It previously named an AOSP
> `googlesource.com/.../+archive/refs/heads/main/clang-r522817.tar.gz` download. That URL
> is a **gitiles `+archive` endpoint, which SILENTLY TRUNCATES** on a tree that large - it
> returns a clang toolchain with **no flang at all**, and scipy then dies at meson with
> `Unknown compiler`. The real source (the one that actually populated the working build's
> flang cache, via **cibuildwheel**) is the **termux `ndk-toolchain-clang-with-flang` r27c
> release** - four `.tar.bz2` archives, assembled with the NDK's clang libs + sysroot.
>
> `toolchain/provision-flang.sh` does the whole thing (a port of cibuildwheel's
> `resources/android/fortran_shim.py`) - it drops `flang-new` + the Fortran runtime libs at
> `$FLANG_CACHE/flang-android-r27c`:
>
>    ```bash
>    FLANG_CACHE="$FLANG_CACHE" NDK="$NDK" toolchain/provision-flang.sh
>    ```
>
> `flang-rtlibs` is then three symlinks into the assembled sysroot:
>
>    ```bash
>    mkdir -p "$FT_ROOT/flang-rtlibs" && cd "$FT_ROOT/flang-rtlibs"
>    for l in libFortranRuntime libFortranDecimal libFortran_main; do
>      ln -s "$FLANG_CACHE/flang-android-r27c/sysroot/usr/lib/aarch64-linux-android/$l.a" .
>    done
>    ```

## 5. Package for Chaquopy

Needs `zip` (apt) and `ANDROID_HOME`/`NDK`/`CHAQUOPY_ROOT` exported as in stage 1.
Then retag the wheels (`chaquopy/retag-wheels.sh` - needs `wheel` in the buildvenv):
numpy -> `android_24_arm64_v8a`, scipy -> `android_26_arm64_v8a`.

### The clean-run verdict (2026-08-21)

A fresh WSL Ubuntu 24.04, this repo, and public downloads produced end to end:
the FT CPython 3.14.7 Maven target (`target-3.14.7-0-*.zip` + pom),
`libopenblas.so` (arm64), and Chaquopy-installable
`numpy-2.5.1-cp314-cp314t-android_24_arm64_v8a.whl` +
`scipy-1.18.0-cp314-cp314t-android_26_arm64_v8a.whl`.

### (original stage-5 notes follow)

```bash
chaquopy/package-target-ft.sh <target_dir> [prefixes...]
```

Assembles the built target into the layout Chaquopy's Gradle plugin consumes.

## 6. The chart stack (matplotlib, pillow, contourpy, kiwisolver)

```bash
matplotlib/build_matplotlib_chain.sh
```

Needs the target prefix from stage 1 and the cross numpy unzipped into the target's
site-packages (stage 3 does that). Independent of OpenBLAS and scipy, so if you only
want plotting you can skip stage 4.

It **retags its own wheels** rather than going through `chaquopy/retag-wheels.sh`,
because meson-python labels them for the build host. The chain is unattended by design:
one package failing never aborts the others, and the summary at the end names which
link broke. A partial result is more useful than "the build failed".

**Sdists are `curl`'d from the PyPI JSON API, never `pip download --no-binary`** - see
stage 0. This is the script that carries the scar.

## 7. The audio stack (libffi/cffi, libsndfile, soundfile)

```bash
audio/build_audio_chain.sh
audio/verify_audio_chain.sh      # do not skip this
```

Two independent halves that meet at the end: `libffi -> cffi`, and
`libogg + libvorbis + libFLAC + libopus -> libsndfile`. `soundfile` is a cffi binding
over libsndfile, so it needs both. It needs only the target prefix, so it can run any
time after stage 1, in parallel with stage 6.

It fetches its own pinned sources if they are absent and leaves existing trees alone.
Extra host packages: `cmake autoconf automake libtool`.

**All four codecs are mandatory.** libsndfile links `Vorbis::` and `Opus::`
unconditionally once external libs are on, so there is no "FLAC only" configuration -
cmake fails at configure time. You build four codecs to ship what is, in practice,
WAV + FLAC.

> ### ⚠ Why this stage has its own gate
>
> A libsndfile built without `ENABLE_EXTERNAL_LIBS` **still builds, still loads, and
> still round-trips WAV.** It simply cannot decode FLAC. Nothing in the build says so.
>
> A build in exactly that state once shipped for three weeks. It had been rebuilt to fix
> 16 KB page alignment, the rebuild dropped the external-libs flag, and the alignment
> gate went green - correctly, because the alignment genuinely was fixed.
>
> **A gate proves only the property it measures.** `verify_audio_chain.sh` checks codec
> symbols *and* alignment on the same artifact, which is the combination nothing was
> checking. Run it; a green build log is not evidence here.

## The retagging trap

A wheel built this way carries a platform tag Chaquopy will not install. It must be
retagged to `android_24_arm64_v8a` (matching `minSdk 24`). **If installation fails with
"no matching distribution", check the wheel tag before anything else** - it is almost
always this and almost never the build.

## Toolchain wrappers

| script | why it exists |
|---|---|
| `toolchain/fc-android.sh` | Fortran for Android via `flang-new` + explicit sysroot and runtime libs |
| `toolchain/pkgconf-wrap.sh` | keeps `pkg-config` pointed at the cross prefix |
| `toolchain/pybind11-config-cross.sh` | rewrites `pybind11-config` output for the cross target |
