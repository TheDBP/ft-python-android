#!/bin/bash
set -e
cd ${FT_ROOT}/openblas-build/OpenBLAS-0.3.34
make clean || true
make -j${FT_JOBS:-$(nproc)}   CROSS=1   TARGET=ARMV8   HOSTCC=gcc   CC=${NDK}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang   FC=${FT_ROOT}/fc-android.sh   AR=${NDK}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar   RANLIB=${NDK}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ranlib   USE_OPENMP=0   NUM_THREADS=8   LDFLAGS="-Wl,-z,max-page-size=16384"   libs netlib shared
echo "=== make done, installing ==="
# ! Serial install, MAKEFLAGS cleared - see cpython/build-cpython-314t-android.sh for
#   the failure this prevents. A caller exporting MAKEFLAGS=-jN (docker/build-all.sh)
#   parallelises an install target that was only ever exercised serially, and the
#   symptom is a truncated library, not an obvious race.
MAKEFLAGS= make -j1 PREFIX=${FT_ROOT}/openblas-android   CROSS=1 TARGET=ARMV8 HOSTCC=gcc   CC=${NDK}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang   FC=${FT_ROOT}/fc-android.sh   AR=${NDK}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar RANLIB=${NDK}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ranlib   NUM_THREADS=8 LDFLAGS="-Wl,-z,max-page-size=16384" install
echo "ALLDONE_OPENBLAS"
