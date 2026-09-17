# ft-python-android

**Free-threaded CPython 3.14t with the scientific, charting and audio stacks,
cross-compiled for Android arm64-v8a and installable by Chaquopy.**

These are working build drivers, extracted from a real project rather than written as a
demo. The produced runtime ships inside an Android app with the GIL disabled, and has
**confirmed real-time DSP operation on an LG V20 (2016) and a Pixel 3a XL (2019)** - a
continuous audio workload meeting every processing deadline, on hardware that is years
old. Run your own numbers; the point is that the ceiling is not where you would expect.

---

## Build it

```bash
docker build -f docker/Dockerfile -t ft-python-android .
docker run --rm -v "$PWD/out:/out" ft-python-android
```

That is the whole thing. The image carries the pinned toolchain - NDK, flang, the build
Python - and runs all seven stages plus three gates. It is a pure `x86_64 -> arm64-v8a`
cross-compile: no device, no emulator, no KVM, so it runs anywhere Docker does.

**Expect roughly 10-15 minutes** on a modern multi-core machine (scipy dominates), plus a
one-off image build that downloads a full NDK and a flang prebuilt. The image is several GB
- that is inherent to a self-contained cross toolchain.

**Use Docker unless you have a reason not to.** The difference is not convenience: in the
image the toolchain is *pinned*, on a bare-metal host it is *described*, and a description
is only as good as your host matching it. Most of what goes wrong in a cross-compile is a
version skew nothing announces.

### What you get in `./out`

```
out/wheels/numpy-*-cp314-cp314t-android_24_arm64_v8a.whl
out/wheels/scipy-*-cp314-cp314t-android_26_arm64_v8a.whl
out/wheels/matplotlib-* pillow-* contourpy-* kiwisolver-*      # the chart stack
out/wheels/cffi-*-cp314-cp314t-android_26_arm64_v8a.whl
out/wheels/soundfile-*-py3-none-android_26_arm64_v8a.whl       # bundles libsndfile
out/target/target-3.14.7-0-arm64-v8a.zip                       # + stdlib / stdlib-pyc
out/target/target-3.14.7-0.pom                                 # the Maven target
out/logs/...                                                   # every stage's log
```

Drop the wheels into your Chaquopy app's `pip { }` block and point the Gradle plugin at the
Maven target. The wheels are already retagged, so Chaquopy will install them.

### Building without Docker

[`docs/BUILD.md`](docs/BUILD.md) documents every stage as a standalone script, and is the
reference for what the container actually does. You want it if you are modifying a stage,
debugging one, or cannot run containers. Requires an `x86_64` Linux host with glibc 2.35+,
the Android NDK and a `flang-new` that can target Android.

Everything here is ordinary Linux and **WSL2 works unmodified** - one caveat, keep
`FT_ROOT` on the WSL filesystem rather than under `/mnt/` (performance and POSIX
permissions, not compatibility).

## Why this exists

Free-threaded Python on Android is not new by itself - CPython's own Android build system
supports `--disable-gil`, and there are public 3.14t builds for Termux. **What was missing
was the stack on top.** To run real DSP on-device you need `numpy`, `scipy` and a BLAS in
the free-threaded ABI, cross-compiled for `arm64-v8a`, wheel-tagged so Chaquopy installs
them, and packaged into an APK. Charts and audio I/O turned out to need the same treatment.

**What it buys you:** a genuinely parallel scientific Python runtime in an Android app, with
no GIL serialising your worker threads - numpy/scipy workloads scale across cores on-device
the way they do on a desktop.

**Not sure what to build with it?** [`docs/USE-CASES.md`](docs/USE-CASES.md) maps the fields
this opens up - seismic and structural sensing, bioacoustics, point-of-care health, SDR and
more.

## The three gates, and why they exist

Every gate here was written because of a defect that got past the previous one. They run on
what actually leaves the build, and they are the part of this repo worth copying even if you
never use the drivers.

| gate | what it catches |
|---|---|
| `audio/verify_audio_chain.sh` | codec support **and** 16 KB alignment on the SAME artifact |
| artifact completeness (in `docker/build-all.sh`) | a stage that failed quietly, leaving a wheel missing |
| `toolchain/check_16kb_align.py` | any `.so` in any wheel whose LOAD segments are not 16 KB aligned |

**`A GATE PROVES ONLY THE PROPERTY IT MEASURES.`** A libsndfile built without
`ENABLE_EXTERNAL_LIBS` still builds, still loads and still round-trips WAV - it simply
cannot decode FLAC, and an alignment-only check passes it happily. A build in exactly that
state shipped for three weeks behind a green gate, because the gate measured alignment and
the alignment was genuinely correct. Two independent properties; one checked.

Two corollaries are wired into the gates themselves:

* **"inspected nothing" is a FAILURE, not a pass.** Pointed at a directory of wheels, an
  earlier version of the alignment checker looked only for loose `.so`, found none, printed
  `0 ok, 0 MISALIGNED` and exited 0. "I checked everything and it was fine" and "I checked
  nothing" must never produce the same output.
* **a gate that inspects what it FINDS cannot notice an absence.** Hence the separate
  completeness gate, which knows what *should* be there.

## 16 KB page sizes

Android 15+ can use 16 KB memory pages, and a shared library whose `PT_LOAD` segments are
only 4 KB-aligned will not load there. Every native wheel this repo produces is built with
`-Wl,-z,max-page-size=16384`, and `toolchain/check_16kb_align.py` verifies it - pure stdlib,
no NDK tools, works on a wheel, an APK, a directory or a bare `.so`:

```bash
python toolchain/check_16kb_align.py out/wheels      # exit 1 if anything is misaligned
```

The flag has three different homes depending on the build system (meson `[built-in options]`,
setuptools `LDSHARED`, make `LDFLAGS`), which is exactly why it is verified rather than
assumed.

## Reproducibility

* **Versions are pinned** - the toolchain, and every sdist, fetched by exact version rather
  than "whatever is newest". An earlier version resolved `info.version` from PyPI, so two
  runs a week apart produced different wheels from identical inputs. A package with no pin
  is now refused rather than guessed at.
* **Downloads retry and fall back to a mirror.** A transient blip is a normal event on a
  network, not an exceptional one.
* **Build-machine paths are stripped** from every shipped `.so`
  (`toolchain/strip_build_rpath.sh`, run before the gates). A binary's contents should not
  depend on where it was built - those strings were the only thing standing between two
  machines' builds being byte-comparable.

## Layout

| folder | what it builds |
|---|---|
| `docker/` | **the recommended path** - `Dockerfile` (pinned toolchain) + `build-all.sh` (all seven stages and the gates) |
| `cpython/` | CPython **3.14t** for Android (GIL disabled), via Chaquopy's target build |
| `openblas/` | **OpenBLAS 0.3.34** cross-compiled, `TARGET=ARMV8`, `USE_OPENMP=0` |
| `numpy/` | numpy against that BLAS, with the meson cross file |
| `scipy/` | scipy - needs Fortran, see the toolchain notes |
| `matplotlib/` | the CHART stack - matplotlib, pillow, contourpy, kiwisolver |
| `audio/` | the AUDIO stack - libffi/cffi, and libogg/vorbis/FLAC/opus -> libsndfile -> soundfile, plus its gate |
| `chaquopy/` | packages the built target so Chaquopy consumes it, and retags wheels |
| `toolchain/` | cross wrappers (Fortran, `pkg-config`, `pybind11-config`), the 16 KB verifier, the RUNPATH strip |
| `docs/` | `BUILD.md` (stage-by-stage), `USE-CASES.md` (ideas to build) |

## Build order

The order matters - each stage consumes the previous one's output.

```
1. cpython/    -> a free-threaded 3.14t target for Android
2. openblas/   -> libopenblas.so for arm64-v8a
3. numpy/      -> numpy wheel, linked against that OpenBLAS
4. scipy/      -> scipy wheel (needs Fortran + the numpy from step 3)
5. chaquopy/   -> package the target so the Gradle plugin picks it up
6. matplotlib/ -> the chart stack (needs the target prefix + the cross numpy)
7. audio/      -> libffi -> cffi, and four codecs -> libsndfile -> soundfile
                  (needs only the target prefix; independent of BLAS)
   then: strip build-machine RUNPATHs, then the three gates
```

Steps 6 and 7 depend on step 5 and on nothing else, so they can run in either order or
concurrently. If you only want the scientific core, they are the two you can drop.

**All four codecs are mandatory for audio.** libsndfile links `Vorbis::` and `Opus::`
unconditionally once external libs are on, so there is no "FLAC only" configuration - cmake
fails at configure time. You build four codecs to ship what is, in practice, WAV + FLAC.

## Setup (bare metal only)

```bash
cp env.example .env        # or export these directly
export FT_ROOT=$HOME/ft-build                 # working root; everything lands under here
export NDK=$FT_ROOT/android-sdk/ndk/27.3.13750724
export FLANG_CACHE=$HOME/.cache/cibuildwheel  # where the flang-android toolchain lives
```

## The one non-obvious trick: wheel retagging

A wheel built this way comes out with a platform tag Chaquopy will not install - meson and
setuptools both label it for the BUILD host. The packaging step retags each to its real
cross target: `android_24_arm64_v8a` for numpy, `android_26_arm64_v8a` for scipy and the
chart/audio native wheels (API 26 is the Fortran and bionic floor), and
`py3-none-android_26_arm64_v8a` for soundfile, which is pure Python wrapping a bundled
library. **If an install fails with "no matching distribution", check the tag before
anything else** - it is almost always this and almost never the build.

## Troubleshooting

* **Read `out/logs/` first.** Every stage writes a detailed log and the console shows only a
  short tail; the logs are copied out on failure as well as success, because
  `docker run --rm` otherwise deletes the one artifact that explains what happened.
* **`Clock skew detected`** is an environment fault, not a build defect - a host whose clock
  jumps backwards (WSL2 does this) makes files a build just wrote look future-dated. Fix the
  clock, do not change the build.
* **Fortran is the hard part.** scipy needs a Fortran compiler targeting Android and there is
  no vendor one. We use a `flang-new` build wrapped by `toolchain/fc-android.sh` plus
  hand-supplied runtime libs, provisioned by `toolchain/provision-flang.sh`. On bare metal
  this is the step most likely to need work on your machine.
* **Out of memory on scipy?** `toolchain/build-jobs.sh` bounds the job count by available
  RAM; override with `FT_BUILD_JOBS`.

## Status and honesty

* These are **build drivers, not a polished distribution**, extracted from a working
  project.
* The Docker path has been run from clean **more than once, end to end**, producing all
  eight wheels plus the Chaquopy target with the gates green: 138 `.so` inspected, 0
  misaligned, 0 carrying build-machine paths. The audio artifact matched a known-good
  reference exactly on every measured property.
* Both consuming Android apps have been built and run against the output, including real
  audio capture through it.
* The drivers were developed on **Ubuntu 24.04** with Android **NDK r27c**; the image pins
  that same environment.
* The bare-metal path expects you to adapt paths and package names. The Docker path removes
  that.

## Support

This is unpaid work. Cross-compiling this stack for free-threaded Android is weeks of
finding out which of a dozen build systems silently did the wrong thing; if these wheels
saved you that, [a donation](https://www.paypal.com/donate/?hosted_button_id=7U8PDZLK7742Q)
keeps the next one coming.

## Licence

**Apache License 2.0** - see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

The build drivers in this repository are Apache-2.0, and **nothing they build is
redistributed here.** Each component carries its own licence and comes from its own project:
CPython (PSF-2.0), OpenBLAS/NumPy/SciPy/contourpy/kiwisolver (BSD-3), Chaquopy (MIT), Pillow
(MIT-CMU), matplotlib (PSF-style), cffi/libffi (MIT), libogg/libvorbis/libFLAC/libopus
(BSD-3), soundfile (BSD-3), LLVM/flang (Apache-2.0 with LLVM exceptions) and the Android NDK
(its own SDK licence).

> ### Two obligations worth knowing BEFORE you redistribute anything you build
> * **libsndfile is LGPL-2.1-or-later**, and the `soundfile` wheel **bundles** it while
>   shipping only soundfile's own BSD-3 text. Weak copyleft: proprietary code may link it,
>   but a redistributor owes the LGPL text, the exact version, a link to upstream source and
>   a path to relink against a user's own build.
> * **CPython is built MODIFIED here** (`--disable-gil` plus a ctypes abiflags patch), so
>   PSF-2.0 section 3 wants a statement of changes alongside anything you ship.
>
> `NOTICE` has the detail. These bind whoever ships the artifacts - not this repository.
