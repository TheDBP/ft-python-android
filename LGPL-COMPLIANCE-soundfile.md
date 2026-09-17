# soundfile wheel - LGPL compliance notes

**This file accompanies the `soundfile` release asset, which BUNDLES libsndfile.** It is the
reason that wheel is published as a separate, clearly-labelled release rather than alongside
the rest of the stack.

## What is bundled

| | |
|---|---|
| wheel | `soundfile-0.14.0-py3-none-android_26_arm64_v8a.whl` |
| `soundfile` itself | BSD-3-Clause |
| **bundled at `_soundfile_data/libsndfile_arm64.so`** | **libsndfile 1.2.2 - LGPL-2.1-or-later** |
| statically linked inside that `.so` | libogg 1.3.5, libvorbis 1.3.7, libFLAC 1.4.3, libopus 1.4 - all BSD-3-Clause |

The upstream `soundfile` wheel ships only soundfile's own BSD-3 licence. **The LGPL text is
not in it**, which is why `COPYING-libsndfile-LGPL-2.1.txt` is attached to the release.

## Why this matters, in plain terms

libsndfile is **weak copyleft**. Linking it from proprietary application code is fine and
explicitly intended - that is the difference between the LGPL and the GPL. What the licence
asks is that a user who receives your binary can **replace the LGPL part with their own
build of it**.

So the obligations fall on a REDISTRIBUTOR - whoever ships the wheel, or an app containing
it - not on the build drivers in this repository.

## What is provided here

1. **The licence text** - `COPYING-libsndfile-LGPL-2.1.txt`, taken verbatim from
   libsndfile 1.2.2's own `COPYING`.
2. **The exact version** - libsndfile **1.2.2**, unmodified. No patches of ours are applied;
   it is a clean upstream cross-compile.
3. **Upstream source** - <https://github.com/libsndfile/libsndfile/releases/tag/1.2.2>
4. **A relink path** - below.

## How to relink against your own libsndfile

The bundled library is a single `.so` inside a zip. Nothing is statically linked into the
Python extension, so replacing it is a file swap:

```bash
# 1. build your own libsndfile for android-aarch64. This repo's audio/build_audio_chain.sh
#    does exactly that and shows the flags used here, including 16 KB page alignment:
#      -DENABLE_EXTERNAL_LIBS=ON            (FLAC/vorbis/opus support)
#      -DCMAKE_SHARED_LINKER_FLAGS=-Wl,-z,max-page-size=16384
#
# 2. swap it into the wheel
unzip -o soundfile-0.14.0-py3-none-android_26_arm64_v8a.whl -d sf/
cp your-libsndfile.so sf/_soundfile_data/libsndfile_arm64.so
cd sf && zip -r ../soundfile-relinked.whl . && cd ..
```

⚠ **Two things that will bite you if you build your own:**

* **All four codecs are mandatory.** libsndfile links `Vorbis::` and `Opus::`
  unconditionally once `ENABLE_EXTERNAL_LIBS=ON`, so there is no "FLAC only" configuration -
  cmake fails at configure time. You need libogg, libvorbis, libFLAC and libopus present.
* **`ENABLE_EXTERNAL_LIBS=OFF` builds successfully and silently cannot decode FLAC.** It
  still builds, still loads, still round-trips WAV. Verify codec support rather than
  assuming it - `audio/verify_audio_chain.sh` in this repo checks for `FLAC__` symbols and
  16 KB alignment on the same artifact, because a build can have either without the other.

## If you ship an app containing this wheel

You inherit the same obligations. At minimum: include the LGPL-2.1 text, state the
libsndfile version, link the upstream source, and do not prevent a user from relinking.
An open-source-licences screen in the app is the usual way to discharge the first three.

> **Note on EULAs.** LGPL-2.1 section 6 requires permitting reverse engineering for
> debugging modifications to the library. If your app has an EULA with a
> no-reverse-engineering clause, it needs an explicit carve-out for the LGPL components,
> or the two terms conflict.

## Also in this release set: CPython is built MODIFIED

The interpreter in the `target-*` assets is CPython built with `--disable-gil` (PEP 703)
plus a ctypes abiflags patch. **PSF-2.0 section 3 requires a statement of changes** with
redistributed artifacts - that sentence is the statement, and the patch is in this
repository at `chaquopy/ft-enable.patch`.
