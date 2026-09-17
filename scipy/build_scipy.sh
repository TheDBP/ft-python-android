#!/bin/bash
export PATH=${FT_ROOT}/buildvenv/bin:$PATH
set -eu -o pipefail
# Render the repo's cross file (it carries ${NDK}/${FT_ROOT} placeholders
# meson will not expand) to the path the meson invocation uses.
recipe_dir=$(dirname "$(realpath "$0")")
# The cross file names ${FT_ROOT}/{pkgconf-wrap,fc-android,pybind11-config-cross}.sh;
# place all three toolchain wrappers where it expects them.
for w in pkgconf-wrap.sh fc-android.sh pybind11-config-cross.sh; do
  install -m 0755 "$recipe_dir/../toolchain/$w" "${FT_ROOT}/$w"
done
envsubst < "$recipe_dir/meson-cross-android-arm64.txt" > "${FT_ROOT}/android-arm64-scipy.txt"
TARGET=${FT_ROOT}/chaquopy/target/prefix/arm64-v8a
OPENBLAS=${FT_ROOT}/openblas-android
export _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata_t_android_aarch64-linux-android
export PYTHONPATH=$TARGET/lib/python3.14t
NUMPYPC=$(${FT_ROOT}/buildvenv/bin/python -c "import numpy,os;print(os.path.join(os.path.dirname(numpy.__file__),'_core','lib','pkgconfig'))")
export PKG_CONFIG_LIBDIR=$OPENBLAS/lib/pkgconfig:$TARGET/lib/pkgconfig:$NUMPYPC
SCIPYSRC=$(ls -d ${FT_ROOT}/src/scipy-*/ | head -1)
cd "$SCIPYSRC"
# Android source patches (found by the clean-env run: the live build carried
# these by hand). -N = idempotent on reruns.
for pf in "$recipe_dir"/patches/*.patch; do
  [ -e "$pf" ] && patch -p1 -N -r- < "$pf" || true
done
echo "=== building scipy in: $SCIPYSRC ==="
rm -rf build-android
# Memory-aware ninja job count (set by docker/build-all.sh; computed here if run
# standalone). scipy's ducc0/pocketfft C++ compiles are RAM-heavy - one per core
# OOM-kills the build on modest machines.
JOBS="${FT_JOBS:-$(bash "$recipe_dir/../toolchain/build-jobs.sh")}"
${FT_ROOT}/buildvenv/bin/python -m build --wheel --no-isolation \
  -Ccompile-args="-j${JOBS}" \
  -Csetup-args="--cross-file=${FT_ROOT}/android-arm64-scipy.txt" \
  -Csetup-args="-Dblas=openblas" \
  -Csetup-args="-Dlapack=openblas" \
  -Csetup-args="-Duse-pythran=false" \
  -Csetup-args="-Dc_args=-ftls-model=global-dynamic" \
  -Csetup-args="-Dcpp_args=-ftls-model=global-dynamic" \
  -Cbuilddir=build-android \
  -o ${FT_ROOT}/wheels
echo "SCIPY_BUILD_EXIT=$?"
echo "ALLDONE_SCIPY"
