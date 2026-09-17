"""check_16kb_align.py - which native libs are ACTUALLY 16 KB-misaligned?

Android 15+ can use 16 KB memory pages. A shared library whose PT_LOAD segments are
only 4 KB-aligned will not load on such a device. Every native wheel this repo builds
has to clear that bar, and the failure is invisible until you run on the hardware.

** WHY MEASURED, NOT INFERRED. ** Device-side compatibility warnings are a poor aiming
device: they tend to name one library concretely and report "Unknown error" for the
rest, which on a debuggable build may be checker noise rather than a verdict. Rebuilding
a whole cross toolchain on that evidence is days of work aimed by a guess. This reads
the ELF program headers directly and reports each PT_LOAD's alignment, so the question
"which libraries are actually wrong" gets a measured answer in about a second.

`p_align >= 0x4000` on every LOAD segment = 16 KB-ready. Pure stdlib - no NDK tools, no
device, nothing to install.

Run: python toolchain/check_16kb_align.py <apk-or-wheel-or-dir-or-so> [...]
Exit 1 if anything is misaligned, so it works as a post-build gate.

** A SECOND COPY OF THIS FILE EXISTS, DELIBERATELY. ** The project these drivers were
extracted from keeps its own copy, because it gates finished APKs and is wired into that
project's doc-audit tooling, while this copy gates wheels here. The duplication is
intentional: sharing one file would make this repo depend on a tree it must be able to
build without. The logic is ~40 lines against a frozen ELF specification, which is what
makes the duplication affordable - it would not be for anything that changes. **If you
change the alignment logic, the other copy needs the same change.**

** THIS CHECKS ALIGNMENT AND NOTHING ELSE. ** A library can be perfectly 16 KB aligned
and still be built wrong in ways this cannot see - most notably with its optional codec
support switched off. That exact combination (aligned, codec-less, and green on every
gate) shipped once, because the gate in place measured alignment and alignment was
correct. If you are checking a library that has build-time feature flags, check those
separately; `audio/verify_audio_chain.sh` is the worked example. A GATE PROVES ONLY THE
PROPERTY IT MEASURES.
"""
import io
import os
import struct
import sys
import zipfile

REQUIRED = 0x4000


def elf_load_aligns(data):
    """Yield p_align of every PT_LOAD in an ELF64 image, or None if not ELF64."""
    if data[:4] != b"\x7fELF":
        return None
    if data[4] != 2:                       # ELFCLASS64 only (arm64)
        return None
    e_phoff = struct.unpack_from("<Q", data, 0x20)[0]
    e_phentsize = struct.unpack_from("<H", data, 0x36)[0]
    e_phnum = struct.unpack_from("<H", data, 0x38)[0]
    aligns = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type = struct.unpack_from("<I", data, off)[0]
        if p_type == 1:                    # PT_LOAD
            aligns.append(struct.unpack_from("<Q", data, off + 0x30)[0])
    return aligns


def check_blob(name, data, bad, ok):
    aligns = elf_load_aligns(data)
    if not aligns:
        return
    worst = min(aligns)
    (ok if worst >= REQUIRED else bad).append((name, worst))


def check_archive(path, label, bad, ok):
    """Check every .so INSIDE a zip-shaped file (wheel, APK, plain zip)."""
    z = zipfile.ZipFile(path)
    for n in z.namelist():
        if n.endswith(".so"):
            check_blob("%s::%s" % (label, n), z.read(n), bad, ok)


def main(paths):
    bad, ok = [], []
    checked_containers = 0
    missing = [p for p in paths if not os.path.exists(p)]
    if missing:
        # A path that is not there is a broken invocation, and it should say so in one
        # line. Falling through to open() gives a traceback that looks like a bug in
        # the gate rather than a typo in the caller.
        for p in missing:
            print("16KB ALIGN: no such path: %s" % p)
        return 1
    for p in paths:
        if os.path.isdir(p):
            for root, _, fs in os.walk(p):
                for f in fs:
                    full = os.path.join(root, f)
                    rel = os.path.relpath(full, p)
                    if f.endswith(".so"):
                        check_blob(rel, io.open(full, "rb").read(), bad, ok)
                        checked_containers += 1
                    # ! RECURSE INTO ARCHIVES FOUND IN A DIRECTORY. Pointing this at a
                    #   directory of wheels used to check NOTHING: the walk only looked
                    #   for loose .so files, and the zip branch below only fired when
                    #   the PATH ITSELF was an archive. It printed "0 ok, 0 MISALIGNED"
                    #   and exited 0 - a gate reporting success for having looked at
                    #   nothing, which is the exact failure the docstring warns about.
                    elif f.endswith((".whl", ".apk", ".zip", ".aar")):
                        check_archive(full, rel, bad, ok)
                        checked_containers += 1
        # APKs and wheels are both zips; this walks either without being told which.
        elif zipfile.is_zipfile(p):
            check_archive(p, os.path.basename(p), bad, ok)
            checked_containers += 1
        else:
            check_blob(os.path.basename(p), io.open(p, "rb").read(), bad, ok)
            checked_containers += 1
    for name, a in sorted(bad):
        print("MISALIGNED  %-70s p_align=0x%x" % (name, a))
    # ** FOUND NOTHING IS A FAILURE, NOT A PASS. ** This gate ran in a real build over a
    # directory of wheels, inspected zero libraries, printed "0 ok, 0 MISALIGNED" and
    # exited 0. A green gate and a gate that looked at nothing must never be the same
    # output: "I checked everything and it was fine" and "I checked nothing" are
    # opposite facts, and only one of them should let a build continue.
    if not ok and not bad:
        print("16KB ALIGN: NOTHING INSPECTED - no ELF64 .so found in: %s"
              % ", ".join(paths))
        print("            This is a FAILURE, not a pass. Either the paths are wrong")
        print("            or the artifacts are empty; both need looking at.")
        return 1
    print("16KB ALIGN: %d ok, %d MISALIGNED (need p_align >= 0x4000)"
          % (len(ok), len(bad)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or ["."]))
