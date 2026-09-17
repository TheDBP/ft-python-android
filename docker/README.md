# Docker build (the recommended path)

**The entire pinned toolchain is baked into the image** — NDK, flang, the build Python —
so there is nothing to install and nothing to adapt. It is a pure `x86_64 → arm64-v8a`
cross-compile: no device, no emulator, no KVM.

[`../docs/BUILD.md`](../docs/BUILD.md) documents the same stages as standalone scripts,
for modifying or debugging one, or for hosts that cannot run containers. It is the
reference for what this image does — but it *describes* a toolchain where the image
*pins* one, and that difference is where cross-compiles usually go wrong.

## Use it

From the **repo root** (the build context must be the repo root, not `docker/`):

```bash
docker build -f docker/Dockerfile -t ft-python-android .
docker run --rm -v "$PWD/out:/out" ft-python-android
```

When it finishes, `out/` holds:

```
out/wheels/numpy-*-cp314-cp314t-android_24_arm64_v8a.whl
out/wheels/scipy-*-cp314-cp314t-android_26_arm64_v8a.whl
out/wheels/matplotlib-* pillow-* contourpy-* kiwisolver-*   # stage 6, the chart stack
out/wheels/cffi-*-cp314-cp314t-android_26_arm64_v8a.whl     # stage 7, the audio stack
out/wheels/soundfile-*-py3-none-android_26_arm64_v8a.whl    #   (bundles libsndfile)
out/target/target-3.14.7-0-arm64-v8a.zip                    # + -stdlib / -stdlib-pyc zips
out/target/target-3.14.7-0.pom
```

Stages 6 and 7 are independent of each other and of the BLAS chain — they need only the
target prefix from stage 1 (the chart stack additionally wants the cross numpy). If you
only want the scientific core, they are the two you can drop.

Drop the wheels into your Chaquopy app's `pip { }` install and point the target at the
Maven zip. The wheels are already retagged to `android_24/26_arm64_v8a`, so Chaquopy will
install them (that is the one trick the whole repo exists to get right).

## Knobs

Everything is pinned via build args — override to move a version:

```bash
docker build -f docker/Dockerfile \
  --build-arg PY_VERSION=3.14.7 \
  --build-arg NUMPY_VERSION=2.5.1 \
  --build-arg SCIPY_VERSION=1.18.0 \
  --build-arg OPENBLAS_VERSION=0.3.34 \
  -t ft-python-android .
```

Run-time knobs (via `-e`): `BUILD_NUM` (Maven build number, default `0`).

## What's inside

| layer | pinned input |
|---|---|
| host build tools | uv + free-threaded CPython `3.14t`, meson/ninja/cython/build/wheel |
| Android NDK | `r27c` (`27.3.13750724`), direct zip, stubbed `package.xml` |
| Fortran | AOSP flang prebuilt `clang-r522817` + the three `flang-rtlibs` symlinks |
| Chaquopy | `@f004380` + `chaquopy/ft-enable.patch` (the free-threading enablement) |
| BLAS / sci | OpenBLAS `0.3.34`, numpy `2.5.1`, scipy `1.18.0` source trees |

## Caveats — read these

* **The image is large** (several GB): a full NDK and a full flang prebuilt are the bulk.
  That is inherent to a self-contained cross toolchain.
* **The flang download tracks `refs/heads/main`** on android.googlesource.com — the same
  moving ref the bare-metal guide uses. If Google rotates that archive, pin a commit.
* **This orchestration is authored from the stage scripts + `BUILD.md`, not yet proven by
  a from-scratch `docker build`.** The stage scripts themselves are the ones that carry the
  "clean-run verdict"; `docker/build-all.sh` just automates the manual glue around them. If
  a stage trips, the fix belongs in the stage script (and `BUILD.md`), and the Dockerfile
  will inherit it. Expect the first real image build to shake out a rough edge or two.
