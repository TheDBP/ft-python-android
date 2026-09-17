#!/bin/bash
exec ${FLANG_CACHE}/flang-android-r27c/bin/flang-new --target=aarch64-linux-android26 --sysroot=${NDK}/toolchains/llvm/prebuilt/linux-x86_64/sysroot   -L${FT_ROOT}/flang-rtlibs -Wl,-z,max-page-size=16384 "$@"
