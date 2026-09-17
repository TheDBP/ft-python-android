#!/usr/bin/env bash
# strip_build_rpath.sh - remove build-machine paths from every shipped .so.
#
# ** THE PROBLEM. ** Cross-linking against the target prefix records that prefix as
# DT_RUNPATH in each extension module, so a wheel ships with the absolute path of the
# machine that built it baked in:
#
#     RUNPATH: /opt/ft-build/chaquopy/target/prefix/arm64-v8a/lib
#
# Measured before this step existed: 131 of 138 .so across numpy, scipy, matplotlib and
# contourpy.
#
# ** IT IS NOT A LOADING BUG, AND SAYING SO HONESTLY MATTERS. ** On Android those
# directories do not exist, the linker skips them, and resolution falls through to the
# app's own native library directory - which is where a Chaquopy app puts libpython and
# libopenblas anyway. Wheels carrying these paths have been shipping and working. This
# is a REPRODUCIBILITY and HYGIENE fix:
#
#   * a binary's contents should not depend on WHERE it was built. Two builds of the
#     same source on two machines differ only in these strings, which defeats any
#     byte-comparison between them.
#   * build-machine layout is not something a shipped artifact should disclose.
#   * a RUNPATH pointing at a path that does not exist is a false clue during debugging:
#     it says "look here", and there is no here.
#
# $ORIGIN-relative entries are KEPT. Those are relocatable by design and mean something
# at runtime - an auditwheel-style vendored library lives at an $ORIGIN offset.
#
# Requires: patchelf. Idempotent - running it twice is a no-op.
#
# ** LIMITATION, AND IT IS WORTH KNOWING BEFORE YOU DEBUG IT. ** This cleans a binary
# that still HAS a DT_RUNPATH entry, by overwriting the string and then dropping the
# entry. It CANNOT clean a binary whose entry was already removed by a bare
# `--remove-rpath`: the string is orphaned in .dynstr with nothing pointing at it, and
# patchelf has no rpath left to overwrite. Setting a fresh one just appends a new
# string and leaves the old one where it was.
#
# Practically: run this on wheels as they come off the build, which is what
# docker/build-all.sh does. Wheels stripped by the earlier one-step version cannot be
# repaired in place - rebuild them. The verification below will correctly REFUSE such a
# wheel rather than quietly pass it, which is the behaviour you want even though it
# looks like the tool failing.
set -uo pipefail

FT="${FT_ROOT:?set FT_ROOT}"
WHEELS="${1:-$FT/wheels}"
PY="$FT/buildvenv/bin/python"
WORK="$FT/rpath-work"

command -v patchelf >/dev/null 2>&1 || { echo "patchelf not found" >&2; exit 1; }

echo "== stripping build-machine RUNPATH from wheels in $WHEELS =="
rm -rf "$WORK"; mkdir -p "$WORK"
patched_total=0

for whl in "$WHEELS"/*android_*_arm64_v8a.whl; do
    [ -e "$whl" ] || continue
    base="$(basename "$whl")"
    d="$WORK/$(echo "$base" | tr '.' '_')"
    rm -rf "$d"; mkdir -p "$d"

    # ! `wheel unpack` / `wheel pack`, NOT zip surgery: editing a .so inside the archive
    #   invalidates its hash in RECORD, and pack REGENERATES RECORD. A wheel whose
    #   RECORD disagrees with its contents is a wheel that may fail verification on
    #   install, which would be a worse problem than the one being fixed.
    "$PY" -m wheel unpack -d "$d" "$whl" >/dev/null 2>&1 || { echo "  $base: UNPACK FAILED"; continue; }

    n=0
    while IFS= read -r so; do
        rp="$(patchelf --print-rpath "$so" 2>/dev/null)"
        [ -z "$rp" ] && continue
        case "$rp" in
            *'$ORIGIN'*) continue ;;          # relocatable - leave it alone
        esac
        case "$rp" in
            # ! TWO STEPS, AND THE ORDER IS THE WHOLE POINT. `--remove-rpath` alone
            #   drops the DT_RUNPATH entry but ORPHANS ITS STRING in .dynstr - patchelf
            #   does not compact the table, so the build path stays in the binary and
            #   `strings` still finds it. Measured on a shipped numpy module: after
            #   --remove-rpath the entry was gone and the path was still there, once.
            #   Setting a SHORTER rpath first overwrites the long string in place, and
            #   removing the entry afterwards leaves neither. Verified: entry gone AND
            #   zero byte occurrences, with alignment and all NEEDED entries intact.
            /*) patchelf --set-rpath '$ORIGIN' "$so" 2>/dev/null \
                  && patchelf --remove-rpath "$so" 2>/dev/null \
                  && n=$((n+1)) ;;
        esac
    done < <(find "$d" -name '*.so' 2>/dev/null)

    if [ "$n" -eq 0 ]; then
        echo "  $base: nothing to strip"
        continue
    fi

    inner="$(find "$d" -maxdepth 1 -mindepth 1 -type d | head -1)"
    # ! `wheel pack -d` does NOT create the destination directory - it opens the output
    #   path directly and dies with FileNotFoundError if the parent is missing. That
    #   read as "repack failed" for every wheel until the error was actually looked at.
    mkdir -p "$WORK/out"
    # ! Keep the error. Discarding it to /dev/null is what turned a one-line mkdir bug
    #   into a stage that failed opaquely across four wheels.
    if ! ( cd "$d" && "$PY" -m wheel pack -d "$WORK/out" "$inner" ) >"$WORK/pack.log" 2>&1; then
        echo "  $base: REPACK FAILED - original left untouched"
        sed 's/^/        /' "$WORK/pack.log" | tail -5
        continue
    fi
    repacked="$(ls -t "$WORK/out"/*.whl 2>/dev/null | head -1)"
    [ -n "$repacked" ] || { echo "  $base: repack produced nothing"; continue; }
    mv -f "$repacked" "$WHEELS/$base"
    patched_total=$((patched_total+n))
    echo "  $base: stripped $n"
done

# ---- verify, because a strip step that silently did nothing looks identical to one
#      that worked. Re-read every .so and fail if any absolute runpath survived.
echo "== verifying =="
rm -rf "$WORK/verify"; mkdir -p "$WORK/verify"
left=0; seen=0; residue=0
for whl in "$WHEELS"/*android_*_arm64_v8a.whl; do
    [ -e "$whl" ] || continue
    v="$WORK/verify/$(basename "$whl" .whl)"; mkdir -p "$v"
    "$PY" -c "
import zipfile,sys
z=zipfile.ZipFile('$whl')
[z.extract(n,'$v') for n in z.namelist() if n.endswith('.so')]" 2>/dev/null
    while IFS= read -r so; do
        seen=$((seen+1))
        rp="$(patchelf --print-rpath "$so" 2>/dev/null)"
        case "$rp" in
            *'$ORIGIN'*) : ;;
            /*) left=$((left+1)); echo "  STILL ABSOLUTE: $(basename "$so") -> $rp" ;;
        esac
        # ** BYTES ARE REPORTED, NOT ENFORCED - AND THE DISTINCTION IS DELIBERATE. **
        #    Checking DT_RUNPATH alone was not enough: the string survived in .dynstr
        #    after the entry was dropped, so the check measured the property that had
        #    been fixed rather than the one that was wanted. But a build path can reach
        #    a binary by routes this stage has no way to touch, and measuring found
        #    exactly that:
        #      .rodata      - the compiler embedding source paths (__FILE__, asserts).
        #                     Fixable only at compile time, with -ffile-prefix-map.
        #      .debug_str /
        #      .debug_line  - libsndfile ships unstripped debug info: 820 of its 878
        #                     occurrences are there. Fixable with a strip, not patchelf.
        #    FAILING the build for those would block it on work this stage cannot do.
        #    So: absolute RUNPATH entries are a hard failure (this stage owns them);
        #    leftover bytes are a WARNING with a count, so the residue stays visible
        #    instead of being silently accepted or silently fatal.
        if grep -qF "$FT" "$so" 2>/dev/null; then
            residue=$((residue+1))
        fi
    done < <(find "$v" -name '*.so' 2>/dev/null)
done
rm -rf "$WORK"

echo "  $seen .so inspected, $left with an absolute build-machine runpath (stripped $patched_total)"
# ** ZERO INSPECTED IS A FAILURE. ** This is the second time this exact hole appeared in
# this repo: check_16kb_align.py reported "0 ok, 0 MISALIGNED" and exited 0 for having
# opened nothing, and then THIS gate printed "RPATH OK" after inspecting 0 .so because
# every unpack had failed. Writing the lesson in one file did not prevent repeating it
# in the next one. A verifier that finds nothing has not verified anything.
if [ "$seen" -eq 0 ]; then
    echo "RPATH STRIP FAILED - inspected 0 .so, so nothing was verified."
    echo "  Either no wheels matched, or every unpack failed. Both are bugs, not passes."
    exit 1
fi
[ "$left" -eq 0 ] || { echo "RPATH STRIP FAILED - $left remain"; exit 1; }
if [ "$residue" -gt 0 ]; then
    echo "  NOTE: $residue of $seen .so still contain the build root as TEXT, from"
    echo "        routes this stage cannot touch - .rodata (compiler-embedded source"
    echo "        paths; needs -ffile-prefix-map) and .debug_* (unstripped debug info;"
    echo "        needs a strip). Nothing resolves through these: no DT_RUNPATH points"
    echo "        at them. Reported so the residue stays visible, not enforced."
fi
echo "RPATH OK - no absolute DT_RUNPATH in any shipped .so"
