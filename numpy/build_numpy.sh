#!/bin/bash
export PATH=${FT_ROOT}/buildvenv/bin:$PATH
set -eu -o pipefail
# Render the repo's cross file (it carries ${NDK}/${FT_ROOT} placeholders
# meson will not expand) to the path the meson invocation uses.
recipe_dir=$(dirname "$(realpath "$0")")
# The cross file names ${FT_ROOT}/pkgconf-wrap.sh as its pkg-config; place it.
install -m 0755 "$recipe_dir/../toolchain/pkgconf-wrap.sh" "${FT_ROOT}/pkgconf-wrap.sh"
envsubst < "$recipe_dir/meson-cross-android-arm64.txt" > "${FT_ROOT}/android-arm64.txt"
TARGET=${FT_ROOT}/chaquopy/target/prefix/arm64-v8a
export _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata_t_android_aarch64-linux-android
export PYTHONPATH=$TARGET/lib/python3.14t
export PKG_CONFIG_LIBDIR=$TARGET/lib/pkgconfig
cd ${FT_ROOT}/src/numpy-2.5.1
rm -rf build-android
# Memory-aware ninja job count (set by docker/build-all.sh; computed here if run
# standalone). Prevents the compile from OOM-killing the build on modest RAM.
JOBS="${FT_JOBS:-$(bash "$recipe_dir/../toolchain/build-jobs.sh")}"
${FT_ROOT}/buildvenv/bin/python -m build --wheel --no-isolation \
  -Csetup-args="--cross-file=${FT_ROOT}/android-arm64.txt" \
  -Csetup-args="-Dallow-noblas=true" \
  -Ccompile-args="-j${JOBS}" \
  -Cbuilddir=build-android \
  -o ${FT_ROOT}/wheels
echo "NUMPY_BUILD_EXIT=$?"
