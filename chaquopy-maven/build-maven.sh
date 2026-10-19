#!/usr/bin/env bash
# build-maven.sh - entrypoint of the chaquopy-maven image (see Dockerfile header).
#   /in   : target-<ver>-0-arm64-v8a.zip (+ -stdlib.zip, -stdlib-pyc.zip, .pom)
#   /out  : maven/ (plugin + runtime + that target) and maven.SHA256SUMS
set -euo pipefail
log() { printf '[chaquopy-maven %s] %s\n' "$(date +%H:%M:%S)" "$*"; }

Z="$(ls /in/target-*-arm64-v8a.zip 2>/dev/null | head -1)"
[ -n "$Z" ] || { echo "no /in/target-*-arm64-v8a.zip - mount the main image's out/target at /in" >&2; exit 2; }
VER="$(basename "$Z" | sed -E 's/^target-(.+)-arm64-v8a\.zip$/\1/')"       # e.g. 3.14.0-0
log "target $VER"

# The runtime links against the interpreter: rebuild the prefix from the target zip
# (include/python3.14t + jniLibs/arm64-v8a/libpython3.14t.so), then the two aliases the
# runtime CMake expects (it asks for -lpython3.14 / include/python3.14; the linker still
# records the real soname libpython3.14t.so - checked below).
P="$CHAQUOPY/target/prefix/arm64-v8a"
rm -rf "$P" && mkdir -p "$P" && unzip -q "$Z" -d "$P"
ln -sfn jniLibs/arm64-v8a "$P/lib"
test -f "$P/include/python3.14t/Python.h" && test -f "$P/lib/libpython3.14t.so"
ln -sfn python3.14t "$P/include/python3.14"
ln -sfn libpython3.14t.so "$P/lib/libpython3.14.so"

cd "$CHAQUOPY/product"
echo "sdk.dir=$ANDROID_HOME" > local.properties
log "gradle :runtime:publish :gradle:publish (JDK $(basename "$JAVA_HOME"), $(cython --version 2>&1))"
./gradlew --no-daemon --stacktrace :runtime:publish :gradle:publish

M="$CHAQUOPY/maven"
mkdir -p "$M/com/chaquo/python/target/$VER"
cp /in/target-"$VER"-*.zip /in/target-"$VER".pom "$M/com/chaquo/python/target/$VER/"

# GATE: every native runtime library must need the FREE-THREADED libpython. A runtime linked
# against a GIL libpython loads, then fails at the first call - nothing earlier notices.
# (The runtime publishes its native libraries as BARE .so artefacts -
#  runtime/{chaquopy,libchaquopy_java}/17.0.1/*-3.14-arm64-v8a.so - not inside zips.)
bad=0; n=0
while IFS= read -r so; do
  n=$((n+1))
  if readelf -d "$so" | grep -q 'NEEDED.*libpython3\.14t\.so'; then :; else
    echo "  FAIL - $so does not NEED libpython3.14t.so"; bad=1; fi
done < <(find "$M/com/chaquo/python/runtime" -name '*.so')
[ "$n" -gt 0 ] || { echo "  FAIL - no runtime .so found in the published maven"; bad=1; }
[ $bad -eq 0 ] || exit 1
log "PASS - $n runtime .so, every one NEEDS libpython3.14t.so"

rm -rf /out/maven && cp -r "$M" /out/maven
( cd /out && find maven -type f | sort | xargs sha256sum > maven.SHA256SUMS )
log "DONE - /out/maven ($(find /out/maven -type f | wc -l) files)"
