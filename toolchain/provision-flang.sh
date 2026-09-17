#!/bin/bash
# provision-flang.sh - assemble the Android flang-new toolchain from public,
# RELIABLE sources. This is a faithful port of cibuildwheel's
# resources/android/fortran_shim.py (download_flang), which is how the working
# original build actually obtained flang.
#
# ! WHY NOT THE AOSP URL: BUILD.md used to name
#   android.googlesource.com/.../+archive/refs/heads/main/clang-r522817.tar.gz
#   as flang's source. That gitiles `+archive` endpoint SILENTLY TRUNCATES on a
#   tree that large and ships a clang toolchain with NO flang at all - the scipy
#   stage then dies at meson with "Unknown compiler". The termux release tarballs
#   below are the real source and download reliably.
#
# Reads FLANG_CACHE and NDK from the environment (both set by the Docker image /
# the BUILD.md `export`s). Produces:
#   ${FLANG_CACHE}/flang-android-r27c/bin/flang-new  (+ merged sysroot + runtime libs)
set -euo pipefail

: "${FLANG_CACHE:?set FLANG_CACHE (e.g. \$HOME/.cache/cibuildwheel)}"
: "${NDK:?set NDK (the r27c NDK root)}"

RELEASE_URL="https://github.com/termux/ndk-toolchain-clang-with-flang/releases/download"
RELEASE_VERSION="r27c"
ARCHS="aarch64 x86_64"

CACHE_DIR="${FLANG_CACHE}/flang-android-${RELEASE_VERSION}"
if [ -x "${CACHE_DIR}/bin/flang-new" ]; then
    echo "flang already provisioned: ${CACHE_DIR}"
    exit 0
fi

NDK_TOOLCHAIN="${NDK}/toolchains/llvm/prebuilt/linux-x86_64"
[ -d "${NDK_TOOLCHAIN}" ] || { echo "ERROR: NDK toolchain not at ${NDK_TOOLCHAIN}" >&2; exit 1; }

TMP="${CACHE_DIR}.tmp"
rm -rf "${TMP}"; mkdir -p "${TMP}"; cd "${TMP}"

# Download + extract the four release archives (mirrors fortran_shim ARCHS list).
for a in package-flang-aarch64.tar.bz2 package-flang-x86_64.tar.bz2 \
         package-flang-host.tar.bz2 package-install.tar.bz2; do
    echo "downloading ${a}"
    curl -Lf --retry 5 --retry-all-errors -o "${a}" "${RELEASE_URL}/${RELEASE_VERSION}/${a}"
    tar xf "${a}"
    rm -f "${a}"
done

# Assemble the toolchain (mirrors fortran_shim.download_flang exactly).
FLANG_TC="${TMP}/toolchain"
mv "${TMP}/out/install/linux-x86/clang-dev" "${FLANG_TC}"

# Clang version = the single directory name under lib/clang; flang and the NDK must agree.
clang_ver() { ls "$1/lib/clang" | head -1; }
CLANG_VER="$(clang_ver "${NDK_TOOLCHAIN}")"
FLANG_CLANG_VER="$(clang_ver "${FLANG_TC}")"
if [ "${CLANG_VER}" != "${FLANG_CLANG_VER}" ]; then
    echo "ERROR: flang uses Clang ${FLANG_CLANG_VER}, NDK uses Clang ${CLANG_VER}" >&2
    exit 1
fi

CLANG_LIB="lib/clang/${CLANG_VER}/lib"
rm -rf "${FLANG_TC:?}/${CLANG_LIB}"

# Merge, in fortran_shim's order: per-arch Fortran runtime libs -> host tools ->
# the NDK's compiler-rt libs -> the NDK sysroot. `cp -a` preserves symlinks and
# merges into existing dirs (== copytree dirs_exist_ok=True, symlinks=True).
for arch in ${ARCHS}; do
    dst="${FLANG_TC}/sysroot/usr/lib/${arch}-linux-android"
    mkdir -p "${dst}"
    cp -a "${TMP}/build-${arch}-install/." "${dst}/"
done
cp -a "${TMP}/build-host-install/." "${FLANG_TC}/"
mkdir -p "${FLANG_TC}/$(dirname "${CLANG_LIB}")"
cp -a "${NDK_TOOLCHAIN}/${CLANG_LIB}" "${FLANG_TC}/${CLANG_LIB}"
cp -a "${NDK_TOOLCHAIN}/sysroot/." "${FLANG_TC}/sysroot/"

rm -rf "${CACHE_DIR}"
mv "${FLANG_TC}" "${CACHE_DIR}"
rm -rf "${TMP}"

echo "flang provisioned: ${CACHE_DIR}/bin/flang-new"
"${CACHE_DIR}/bin/flang-new" --version | head -1
