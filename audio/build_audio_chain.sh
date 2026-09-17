#!/usr/bin/env bash
# build_audio_chain.sh - the cp314t-android AUDIO stack: libffi -> cffi, and
# libogg/vorbis/FLAC/opus -> libsndfile -> soundfile.
#
# WHY THIS IS A CHAIN AND NOT FOUR SCRIPTS: soundfile is a cffi binding over
# libsndfile, so it needs BOTH halves finished before it can be packed. The two
# halves are independent of each other and each fails in its own way, so they are
# separate stages here and the summary at the end says WHICH link broke.
#
#   1. libffi   (autotools, static)  -> links INTO _cffi_backend so the cffi
#                                       wheel is self-contained; no libffi.so
#   2. cffi     (setuptools cross)   -> cp314t-android wheel
#   3. libogg / libvorbis / libFLAC / libopus (cmake, STATIC) -> $PREFIX
#   4. libsndfile (cmake, SHARED)    -> one .so with all four linked in
#   5. soundfile                     -> hand-packed py3-none-android wheel that
#                                       bundles that .so
#
# ============================ THE TWO LAWS ==================================
#
# ** 1. ENABLE_EXTERNAL_LIBS=ON AND THE 16 KB FLAG ARE BOTH REQUIRED, TOGETHER. **
#   A libsndfile built without external libs still builds, still loads, still
#   round-trips WAV - and silently cannot do FLAC. A build without the alignment
#   flag is fine everywhere except 16 KB-page devices. For three weeks a build
#   existed that had alignment and NO codecs, because the alignment rebuild
#   dropped the external-libs flag and every gate stayed green: the alignment
#   gate measured alignment, which was correct.
#   ** A GATE PROVES ONLY THE PROPERTY IT MEASURES. ** verify_audio_chain.sh
#   checks BOTH, and so should anything downstream.
#
# ** 2. libsndfile LINKS Vorbis:: AND Opus:: UNCONDITIONALLY when external libs
#   are on. ** You cannot build "FLAC only" - all four codecs must be present or
#   cmake fails at configure. That is why step 3 builds four libraries to ship
#   what is, in practice, WAV + FLAC.
#
# Requires: FT_ROOT, NDK. Optional: SF (defaults to $FT_ROOT/sf-build).
set -uo pipefail          # NOT -e: a failing link must not hide the summary

FT="${FT_ROOT:?set FT_ROOT to your build root}"
NDKR="${NDK:?set NDK to the NDK root}"
SF="${SF:-$FT/sf-build}"
PREFIX="$SF/prefix"
TOOLCHAIN="$NDKR/build/cmake/android.toolchain.cmake"
ABI=arm64-v8a
API=26                                    # the min-sdk / FT-wheel floor
CC="$NDKR/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${API}-clang"
ALIGN="-Wl,-z,max-page-size=16384"
TARGET="$FT/chaquopy/target/prefix/$ABI"  # CPython 3.14t headers + libpython
WHEELS="$FT/wheels"
PY="$FT/buildvenv/bin/python"
LOGS="$SF/logs"; mkdir -p "$LOGS" "$PREFIX" "$WHEELS"

STATUS=""
say(){ echo "== $* =="; }
mark(){ STATUS="$STATUS
  $1 $2"; }

# Versions are pinned: these are the ones the shipping wheels were built from.
OGG_V=1.3.5; VORBIS_V=1.3.7; FLAC_V=1.4.3; OPUS_V=1.4
SNDFILE_V=1.2.2; FFI_V=3.4.6; CFFI_V=2.1.0; SOUNDFILE_V=0.14.0

# ---------------------------------------------------------------- 0. sources
# ** WHY THIS STAGE EXISTS. ** The stages below expect six source trees under $SF at
# FIXED names. On the machine this chain was developed on they were already there, so
# the script ran clean while quietly depending on state no clone or container has.
# Nothing downstream announces that: cmake on a missing directory is just an error
# about CMakeLists.txt, several stages deep.
#
# Idempotent BY DESIGN: an existing directory is left completely alone. That keeps a
# working tree (possibly with local patches) safe, and it is what makes this safe to
# add to a chain that already ran somewhere.
# ! RETRIES AND A MIRROR ARE NOT OPTIONAL. This used to be a bare `wget -q` with no
#   retry, and a single dropped connection threw away an 11-minute build: ogg and vorbis
#   downloaded fine, then flac and opus failed from the SAME host seconds later, and
#   both URLs returned 200 when checked immediately afterwards. A transient blip is a
#   normal event on a network, not an exceptional one - a build that treats it as fatal
#   is a build that fails for reasons unrelated to the code under test.
fetch(){   # $1=dest-dir-name  $2=url  $3=extracted-dir-name  [$4=mirror url]
  local dest="$SF/$1" url="$2" inner="$3" mirror="${4:-}"
  if [ -d "$dest" ]; then echo "    $1: present, left as-is"; return 0; fi
  local tarball="$SF/$(basename "$url")"
  echo "    $1: fetching $(basename "$url")"
  # -f so an HTTP error is a failure rather than a saved error page; --retry-all-errors
  # because without it curl only retries a subset it considers transient.
  if ! curl -fsSL --retry 4 --retry-delay 3 --retry-all-errors --max-time 600 \
            -o "$tarball" "$url" 2>/dev/null; then
    if [ -n "$mirror" ]; then
      echo "    $1: primary failed, trying mirror"
      curl -fsSL --retry 4 --retry-delay 3 --retry-all-errors --max-time 600 \
           -o "$tarball" "$mirror" 2>/dev/null \
        || { echo "    $1: DOWNLOAD FAILED (primary and mirror)" >&2; return 1; }
    else
      echo "    $1: DOWNLOAD FAILED" >&2; return 1
    fi
  fi
  tar xf "$tarball" -C "$SF" || return 1
  [ "$inner" = "$1" ] || mv "$SF/$inner" "$dest"
  rm -f "$tarball"
}

say "[0/5] sources (pinned; existing trees are never touched)"
mkdir -p "$SF"
XIPH=https://downloads.xiph.org/releases
SRC_OK=1
# Each xiph tarball has a GitHub release mirror; same version, same project, different
# CDN, so a bad day for one host does not stop the build.
GH=https://github.com/xiph
fetch "libffi-$FFI_V" "https://github.com/libffi/libffi/releases/download/v$FFI_V/libffi-$FFI_V.tar.gz" "libffi-$FFI_V" || SRC_OK=0
fetch ogg        "$XIPH/ogg/libogg-$OGG_V.tar.gz"          "libogg-$OGG_V" \
                 "$GH/ogg/releases/download/v$OGG_V/libogg-$OGG_V.tar.gz"          || SRC_OK=0
fetch vorbis     "$XIPH/vorbis/libvorbis-$VORBIS_V.tar.gz" "libvorbis-$VORBIS_V" \
                 "$GH/vorbis/releases/download/v$VORBIS_V/libvorbis-$VORBIS_V.tar.gz" || SRC_OK=0
fetch flac       "$XIPH/flac/flac-$FLAC_V.tar.xz"          "flac-$FLAC_V" \
                 "$GH/flac/releases/download/$FLAC_V/flac-$FLAC_V.tar.xz"          || SRC_OK=0
fetch opus       "$XIPH/opus/opus-$OPUS_V.tar.gz"          "opus-$OPUS_V" \
                 "$GH/opus/releases/download/v$OPUS_V/opus-$OPUS_V.tar.gz"         || SRC_OK=0
fetch libsndfile "https://github.com/libsndfile/libsndfile/releases/download/$SNDFILE_V/libsndfile-$SNDFILE_V.tar.xz" "libsndfile-$SNDFILE_V" || SRC_OK=0
# cffi and soundfile come from PyPI as sdists rather than release tarballs.
# ! CURL THE SDIST - DO NOT `pip download --no-binary`. That is a documented trap in
#   this repo (docs/BUILD.md, and build_matplotlib_chain.sh carries the scar): it
#   bootstraps build requirements from source just to resolve a download, and it has
#   HUNG SILENTLY rather than failing. Resolving a URL and fetching a file should not
#   invoke a build system at all.
pypi_sdist(){   # $1=package $2=version -> echoes the sdist URL for that EXACT version
  curl -s "https://pypi.org/pypi/$1/$2/json" | "$PY" -c \
    'import sys,json;print([f["url"] for f in json.load(sys.stdin)["urls"] if f["packagetype"]=="sdist"][0])' 2>/dev/null
}
fetch_pypi(){   # $1=package $2=version   (extracts to $SF/<pkg>-<ver>)
  local p="$1" v="$2" url tb
  if [ -d "$SF/$p-$v" ]; then echo "    $p-$v: present, left as-is"; return 0; fi
  echo "    $p-$v: fetching sdist from PyPI"
  url="$(pypi_sdist "$p" "$v")"
  [ -n "$url" ] || { echo "    $p-$v: no sdist URL for that version" >&2; return 1; }
  tb="$SF/$(basename "$url")"
  curl -sL "$url" -o "$tb" || return 1
  tar xf "$tb" -C "$SF" || return 1
  rm -f "$tb"
}
fetch_pypi cffi "$CFFI_V" || SRC_OK=0
[ "$SRC_OK" = 1 ] && mark sources OK || mark sources "FAILED (a source could not be fetched - the stages below will fail)"

# ! HOST cffi, for soundfile's BUILD backend - not the wheel stage 2 produces.
#   soundfile declares cffi>=1.0 as a build requirement, and with --no-isolation that
#   is checked against the BUILD interpreter. The stage-2 wheel is arm64-android: it
#   cannot be imported here and pip would refuse to install it anyway. Two different
#   cffis, for two different machines, and only one of them is a build dependency.
#   (The chart stack installs cppy/setuptools_scm the same way.)
"$PY" -m pip install -q "cffi>=1.0" >"$LOGS/builddeps.log" 2>&1 \
  && mark build-deps OK || mark build-deps "FAILED (see $LOGS/builddeps.log)"

cmake_static(){   # $1=srcdir  $2..=extra -D args
  local src="$1"; shift
  cmake -S "$src" -B "$src/b" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DANDROID_ABI="$ABI" -DANDROID_PLATFORM="android-$API" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    "$@" >/dev/null 2>&1 \
  && cmake --build "$src/b" -j"$(nproc)" >/dev/null 2>&1 \
  && cmake --install "$src/b" >/dev/null 2>&1
}

# ---------------------------------------------------------------- 1. libffi
say "[1/5] libffi $FFI_V (static, links into _cffi_backend)"
(
  cd "$SF/libffi-$FFI_V" || exit 1
  # --with-pic because it is linked into a shared object later.
  CC="$CC" ./configure --host=aarch64-linux-android --prefix="$PREFIX" \
      --enable-static --disable-shared --disable-docs --with-pic \
      >"$LOGS/libffi.log" 2>&1 \
  && make -j"$(nproc)" >>"$LOGS/libffi.log" 2>&1 \
  && MAKEFLAGS= make -j1 install >>"$LOGS/libffi.log" 2>&1
) && mark libffi OK || mark libffi "FAILED (see $LOGS/libffi.log)"

# ---------------------------------------------------------------- 2. cffi
say "[2/5] cffi $CFFI_V (cp314t-android)"
(
  cd "$SF/cffi-$CFFI_V" || exit 1
  # ! The host pyconfig.h multiarch-redirects to a path that does not exist under
  #   the NDK clang, so the TARGET include must come FIRST or the build silently
  #   uses the build machine's headers.
  # ! THE NAME CARRIES A `_t_`, AND PYTHONPATH IS NOT OPTIONAL. This is the
  #   free-threaded target, so the module is `_sysconfigdata_t_android_...`; the
  #   name without the `t` belongs to a GIL build and does not exist here. And
  #   setting the name alone is not enough - the module lives in the TARGET's
  #   stdlib, so PYTHONPATH has to point there or sysconfig falls back to the build
  #   interpreter's own data and reports ModuleNotFoundError from deep inside
  #   setuptools. numpy, scipy and the chart stack all set both, together; this
  #   stage set neither correctly, which is why it was the only one that failed.
  export _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata_t_android_aarch64-linux-android
  export PYTHONPATH="$TARGET/lib/python3.14t"
  export _PYTHON_HOST_PLATFORM="android_${API}_arm64_v8a"
  export CC="$CC"
  export CFLAGS="-I$TARGET/include/python3.14t -I$PREFIX/include"
  export LDFLAGS="-L$PREFIX/lib -L$TARGET/lib -lpython3.14t $ALIGN"
  "$PY" -m build --wheel --no-isolation -o "$WHEELS" >"$LOGS/cffi.log" 2>&1
) && mark cffi OK || mark cffi "FAILED (see $LOGS/cffi.log)"

# ------------------------------------------------- 3. the four static codecs
say "[3/5] libogg $OGG_V / libvorbis $VORBIS_V / libFLAC $FLAC_V / libopus $OPUS_V (static)"
cmake_static "$SF/ogg"    -DINSTALL_DOCS=OFF                     && mark libogg OK    || mark libogg FAILED
cmake_static "$SF/vorbis" -DOGG_INCLUDE_DIR="$PREFIX/include" \
                          -DOGG_LIBRARY="$PREFIX/lib/libogg.a"   && mark libvorbis OK || mark libvorbis FAILED
cmake_static "$SF/flac"   -DBUILD_PROGRAMS=OFF -DBUILD_EXAMPLES=OFF \
                          -DBUILD_DOCS=OFF -DBUILD_TESTING=OFF \
                          -DOGG_INCLUDE_DIR="$PREFIX/include" \
                          -DOGG_LIBRARY="$PREFIX/lib/libogg.a"   && mark libFLAC OK   || mark libFLAC FAILED
cmake_static "$SF/opus"                                          && mark libopus OK   || mark libopus FAILED

# ---------------------------------------------------------------- 4. libsndfile
say "[4/5] libsndfile $SNDFILE_V (SHARED, external libs ON, 16 KB aligned)"
(
  B="$SF/libsndfile/b-android"
  rm -rf "$B"
  cmake -S "$SF/libsndfile" -B "$B" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DANDROID_ABI="$ABI" -DANDROID_PLATFORM="android-$API" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_TESTING=OFF -DBUILD_PROGRAMS=OFF -DBUILD_EXAMPLES=OFF \
    -DENABLE_EXTERNAL_LIBS=ON \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
    -DCMAKE_PREFIX_PATH="$PREFIX" \
    -DOGG_INCLUDE_DIR="$PREFIX/include"  -DOGG_LIBRARY="$PREFIX/lib/libogg.a" \
    -DFLAC_INCLUDE_DIR="$PREFIX/include" -DFLAC_LIBRARY="$PREFIX/lib/libFLAC.a" \
    -DOPUS_INCLUDE_DIR="$PREFIX/include" -DOPUS_LIBRARY="$PREFIX/lib/libopus.a" \
    -DVorbis_LIBRARY="$PREFIX/lib/libvorbis.a" \
    -DVorbis_Enc_LIBRARY="$PREFIX/lib/libvorbisenc.a" \
    -DVorbis_File_LIBRARY="$PREFIX/lib/libvorbisfile.a" \
    -DCMAKE_SHARED_LINKER_FLAGS="$ALIGN" \
    >"$LOGS/libsndfile.log" 2>&1 \
  && cmake --build "$B" -j"$(nproc)" --target sndfile >>"$LOGS/libsndfile.log" 2>&1 \
  && {
    # ** STRIP DEBUG INFO. ** This was shipping unstripped: 6,759,352 -> 2,237,624 bytes,
    #   a 67% reduction in a library that goes inside an APK. It also removes 820 of the
    #   878 embedded build-root strings, which were almost entirely .debug_str and
    #   .debug_line. cmake's Release build type does not imply no -g here.
    #   ! --strip-debug, NOT --strip-all. Debug sections only; the dynamic symbol table
    #     stays, so the library still links and loads. Verified after stripping: FLAC
    #     support still present and min p_align still 0x4000 - the two properties
    #     verify_audio_chain.sh exists to protect.
    STRIP="$NDKR/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
    before=$(stat -c%s "$B/libsndfile.so" 2>/dev/null || echo 0)
    "$STRIP" --strip-debug "$B/libsndfile.so" >>"$LOGS/libsndfile.log" 2>&1
    after=$(stat -c%s "$B/libsndfile.so" 2>/dev/null || echo 0)
    echo "    stripped debug info: $before -> $after bytes"
  }
) && mark libsndfile OK || mark libsndfile "FAILED (see $LOGS/libsndfile.log)"

# ---------------------------------------------------------------- 5. soundfile
say "[5/5] soundfile $SOUNDFILE_V (hand-packed, bundling libsndfile)"
(
  SO="$SF/libsndfile/b-android/libsndfile.so"
  [ -f "$SO" ] || { echo "no libsndfile.so - step 4 did not finish" >&2; exit 1; }
  # ** THE CROSS-PACKAGING VARIABLES. WITHOUT THESE THE WHEEL BUILDS AND IS EMPTY. **
  #   setup.py names the library it packages as 'libsndfile_<arch>.so', where <arch>
  #   defaults to machine() - the BUILD host, x86_64. package_data then looks for
  #   libsndfile_x86_64.so, does not find it, and ships a wheel with no library in it
  #   at all. No error: package_data misses are silent, so the build reports success.
  #   setup.py offers these two variables precisely for cross-packaging; use them.
  #
  #   ! arm64, NOT aarch64. Upstream is asymmetric here: setup.py uses machine()
  #     verbatim, while soundfile.py at runtime maps aarch64/armv8* to the name
  #     'libsndfile_arm64.so'. The runtime is what has to find the file, so arm64 is
  #     the correct answer and it matches the shipping wheel.
  export PYSOUNDFILE_PLATFORM=linux
  export PYSOUNDFILE_ARCHITECTURE=arm64
  W="$SF/pack"; rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1
  # Same rule as stage 0: curl the sdist, never `pip download --no-binary`.
  SF_URL="$(pypi_sdist soundfile "$SOUNDFILE_V")"
  [ -n "$SF_URL" ] || { echo "no sdist URL for soundfile==$SOUNDFILE_V" >&2; exit 1; }
  curl -sL "$SF_URL" -o soundfile.tar.gz || exit 1
  tar xf soundfile.tar.gz && cd soundfile-* || exit 1
  # ! soundfile's packaged-library branch tests `sys.platform == 'linux'`, but
  #   CPython on Android reports 'android' - so without this it falls through to a
  #   find_library() lookup that cannot succeed and the import dies. Two sites.
  "$PY" - <<'PATCH'
import glob, io, re
for p in ('soundfile.py',):
    s = io.open(p, encoding='utf-8').read()
    n = len(re.findall(r"_sys\.platform\s*==\s*'linux'", s))
    s = re.sub(r"_sys\.platform\s*==\s*'linux'", "_sys.platform in ('linux', 'android')", s)
    io.open(p, 'w', encoding='utf-8').write(s)
    print("  patched %d platform check(s) in %s" % (n, p))
PATCH
  # ** CREATING _soundfile_data CHANGES HOW setup.py PACKAGES ITSELF. ** Its branch is
  #   `if libname and os.path.isdir('_soundfile_data')`, and taking it sets
  #   packages = ['_soundfile_data', 'licensing'] - so the moment we drop the library
  #   in, setup.py starts demanding TWO package directories. `licensing/` is not in the
  #   sdist at all, and `_soundfile_data` needs an __init__.py to be a package.
  #   This built in mid-2025 because setuptools only WARNED about a missing package
  #   directory; current setuptools makes it a hard error. Nothing in this repo
  #   changed - the toolchain tightened underneath it. Both directories are now
  #   created explicitly rather than relying on a warning staying a warning.
  mkdir -p _soundfile_data licensing
  cp "$SO" _soundfile_data/libsndfile_arm64.so
  : > _soundfile_data/__init__.py
  # license_notes.md documents libsndfile's LGPL terms. We are bundling libsndfile, so
  # shipping it is the correct outcome, not just the one that makes setup.py proceed.
  # Pinned to the release tag; a stub carrying the same pointer if the fetch fails,
  # because a missing licence note must not be silent.
  curl -sfL "https://raw.githubusercontent.com/bastibe/python-soundfile/$SOUNDFILE_V/licensing/license_notes.md" \
       -o licensing/license_notes.md \
    || printf '%s\n' \
       "This wheel bundles libsndfile (LGPL-2.1) in _soundfile_data/." \
       "Upstream licence notes: https://github.com/bastibe/python-soundfile/tree/$SOUNDFILE_V/licensing" \
       > licensing/license_notes.md
  "$PY" -m build --wheel --no-isolation -o "$W/out" >>"$LOGS/soundfile.log" 2>&1 || exit 1
  # meson/setuptools tags it for the build host; the payload is the cross target.
  # ! --python-tag py3 is deliberate. soundfile's setup.cfg still carries the old
  #   `universal = 1`, so depending on the setuptools version the wheel comes out
  #   tagged py2.py3 instead of py3. Both install, but the tag should describe the
  #   artifact rather than record which setuptools happened to build it - and the
  #   reference wheel this chain reproduces is py3.
  cd "$W/out" && "$PY" -m wheel tags --python-tag=py3 --platform-tag="android_${API}_arm64_v8a" \
      --remove soundfile-*.whl >>"$LOGS/soundfile.log" 2>&1 \
  && cp soundfile-*android*.whl "$WHEELS/"
) && mark soundfile OK || mark soundfile "FAILED (see $LOGS/soundfile.log)"

echo
say "audio chain summary"
echo "$STATUS"
echo
echo "Now gate it - a build is not a build until something checks BOTH properties:"
echo "  bash audio/verify_audio_chain.sh"
