#!/usr/bin/env bash
# verify_audio_chain.sh - gate the packed soundfile wheel on BOTH properties.
#
# ** WHY THIS EXISTS, AND WHY IT CHECKS TWO THINGS. **
# A libsndfile built without ENABLE_EXTERNAL_LIBS still builds, still loads, and
# still round-trips WAV. It just cannot do FLAC. An alignment-only gate passes it,
# because alignment is exactly what that gate measures and the alignment WAS
# correct. A build like that shipped for three weeks: aligned, codec-less, green.
#
#   ** A GATE PROVES ONLY THE PROPERTY IT MEASURES. **
#
# So: FLAC symbols AND 16 KB alignment, on the SAME artifact, or this fails. The
# two properties were never held together until they were checked together.
#
# Usage: bash audio/verify_audio_chain.sh [path/to/soundfile-*.whl]
#        (defaults to the newest soundfile wheel in $FT_ROOT/wheels)
set -uo pipefail

WHL="${1:-}"
if [ -z "$WHL" ]; then
    FT="${FT_ROOT:?set FT_ROOT or pass a wheel path}"
    WHL="$(ls -t "$FT"/wheels/soundfile-*android*.whl 2>/dev/null | head -1)"
fi
[ -f "$WHL" ] || { echo "FAIL - no soundfile wheel found (looked for: ${WHL:-none})" >&2; exit 1; }
echo "== gating $(basename "$WHL") =="

python3 - "$WHL" <<'PY'
import sys, zipfile, struct, re, io

whl = sys.argv[1]
z = zipfile.ZipFile(whl)
fail = 0

# ---- the bundled library must BE there ------------------------------------
so_names = [n for n in z.namelist() if n.endswith('.so')]
if not so_names:
    print("  [1] FAIL - no .so in the wheel: nothing was bundled")
    sys.exit(1)
so = z.read(so_names[0])
print("  [1] PASS - bundles %s (%d bytes)" % (so_names[0], len(so)))

# ---- PROPERTY A: it can actually do FLAC ----------------------------------
# Symbol presence, not a format table: a codec-less libsndfile still advertises
# the FLAC *enum*, so counting FLAC__ symbols is what distinguishes the builds.
#
# ! THE COUNT IS NOT A STABLE NUMBER - ONLY `> 0` IS MEANINGFUL. It counts every
#   FLAC__ string in the file, including ones in debug sections. The same library
#   measured 942 unstripped and 293 after `llvm-strip --strip-debug`; both are
#   correct and both have full FLAC support. So do not tighten this into a
#   threshold, and do not read a drop as a regression.
#   ⚠ It does mean the proxy weakens as stripping gets more aggressive. Under
#   `--strip-all` the symbol table goes too and this could read near zero on a
#   GOOD library - a false red. If that day comes, the honest replacement is to
#   check the format table via sf_command(SFC_GET_FORMAT_INFO) on-device rather
#   than to guess at a lower bound here.
flac = len(re.findall(rb'FLAC__[A-Za-z_]+', so))
if flac > 0:
    print("  [2] PASS - FLAC support compiled in (%d FLAC__ symbols)" % flac)
else:
    print("  [2] FAIL - ZERO FLAC symbols: built without ENABLE_EXTERNAL_LIBS.")
    print("            WAV will work and FLAC will not. This is the exact")
    print("            regression this gate exists to catch.")
    fail = 1

# ---- PROPERTY B: every LOAD segment is 16 KB aligned ----------------------
ph = struct.unpack_from('<Q', so, 0x20)[0]
es = struct.unpack_from('<H', so, 0x36)[0]
n  = struct.unpack_from('<H', so, 0x38)[0]
aligns = [struct.unpack_from('<Q', so, ph + i*es + 0x30)[0]
          for i in range(n) if struct.unpack_from('<I', so, ph + i*es)[0] == 1]
worst = min(aligns) if aligns else 0
if worst >= 0x4000:
    print("  [3] PASS - 16 KB aligned (min p_align 0x%x)" % worst)
else:
    print("  [3] FAIL - min p_align 0x%x < 0x4000: will not load on a" % worst)
    print("            16 KB-page device. The linker flag did not reach the link.")
    fail = 1

# ---- the android platform patch survived packing --------------------------
# ! EXACT basename, not endswith: `_soundfile.py` also ends with "soundfile.py",
#   and it is the cffi out-of-line module which is CORRECTLY unpatched. Matching
#   loosely picked it and failed a good wheel - a false red on the first run of
#   this gate. A filter has to name what it wants, not what it resembles.
py = [n for n in z.namelist() if n.rsplit('/', 1)[-1] == 'soundfile.py']
if py:
    src = z.read(py[0]).decode('utf-8', 'replace')
    if "in ('linux', 'android')" in src:
        print("  [4] PASS - the android platform patch is in the packed wheel")
    else:
        print("  [4] FAIL - soundfile.py still tests `== 'linux'`: on Android it")
        print("            reports 'android', so the bundled library is never found.")
        fail = 1

print()
if fail:
    print("AUDIO CHAIN GATE FAILED - do not ship this wheel")
else:
    print("ALL AUDIO GATES PASSED - FLAC + 16 KB alignment on one artifact")
sys.exit(fail)
PY
