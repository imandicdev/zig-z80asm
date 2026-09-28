"""Makes the reference files of test/formats with sjasmplus and z88dk's
appmake. The files are committed, so `zig build test` needs neither tool.

- program.tap: sjasmplus SAVETAP ..., CODE, "program" (appmake +zx writes 0
  where the ROM's SAVE ... CODE and sjasmplus write 32768, so it is not used)
- program.sna: sjasmplus SAVESNA
- sna_stack.sna: sjasmplus SAVESNA of sna_stack.asm, which covers the stack
- program.amsdos: sjasmplus SAVEAMSDOS, which leaves the name empty
- program_appmake.amsdos: appmake +cpc, with the name AM.CPC
- program.cmd: appmake +trs80 --cmd
- program.msx: appmake +msx (its end address differs; see test/formats_test.zig)

Usage, from the repository root:
    python compare/gen_formats.py --sjasmplus PATH --z88dk-appmake PATH
or with the paths in the SJASMPLUS and Z88DK_APPMAKE environment variables.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

import reference

HERE = os.path.dirname(os.path.abspath(__file__))
FORMATS = os.path.join(HERE, "..", "test", "formats")
# program.asm starts at 8000h, and without END its entry is its start.
ORG = "32768"

APPMAKE = reference.Tool("z88dk-appmake", "Z88DK_APPMAKE", "2.4", [], "The z88dk application generator")


def appmake_path(parser, args):
    """appmake prints no version, so the z88dk-z80asm next to it is checked."""
    exe = reference.path(parser, args, APPMAKE)
    z80asm = os.path.join(os.path.dirname(exe), "z88dk-z80asm" + os.path.splitext(exe)[1])
    r = subprocess.run([z80asm], capture_output=True, text=True)
    if reference.Z88DK_Z80ASM.banner not in r.stdout + r.stderr:
        sys.exit("%s is not from z88dk %s" % (exe, APPMAKE.version))
    return exe


def run(args, cwd, expected=()):
    """Runs a tool, which must print nothing but its progress and the
    warnings that contain one of `expected`."""
    r = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    noise = [l for l in r.stdout.splitlines() + r.stderr.splitlines()
             if l and not l.startswith(("Pass", "Errors: 0")) and not any(e in l for e in expected)]
    if r.returncode != 0 or (args[0].endswith(("sjasmplus", "sjasmplus.exe")) and noise):
        print("\n".join(noise))
        sys.exit("%s failed" % " ".join(args))


def main():
    parser = argparse.ArgumentParser(description="Makes test/formats/* with sjasmplus and appmake.")
    reference.add_option(parser, reference.SJASMPLUS)
    reference.add_option(parser, APPMAKE)
    args = parser.parse_args()
    sjasm = reference.path(parser, args, reference.SJASMPLUS)
    appmake = appmake_path(parser, args)

    with tempfile.TemporaryDirectory() as tmp:
        for name in ("program.asm", "sna_stack.asm"):
            shutil.copy(os.path.join(FORMATS, name), tmp)

        def source(name, text):
            with open(os.path.join(tmp, name), "w", newline="\n") as f:
                f.write(text)

        source("raw.asm", '        INCLUDE "program.asm"\n        END start\n')
        run([sjasm, "--nologo", "--raw=image.bin", "raw.asm"], tmp)
        source("zx.asm", '        DEVICE ZXSPECTRUM48\n        INCLUDE "program.asm"\n'
                         '        EMPTYTAP "program.tap"\n'
                         '        SAVETAP "program.tap", CODE, "program", start, program_end - start\n')
        run([sjasm, "--nologo", "zx.asm"], tmp)
        source("sna.asm", '        DEVICE ZXSPECTRUM48\n        INCLUDE "program.asm"\n'
                          '        SAVESNA "program.sna", start\n')
        run([sjasm, "--nologo", "sna.asm"], tmp)
        source("stack.asm", '        DEVICE ZXSPECTRUM48\n        INCLUDE "sna_stack.asm"\n'
                            '        SAVESNA "sna_stack.sna", start\n')
        # It warns that the start goes to 0x4000.
        run([sjasm, "--nologo", "stack.asm"], tmp, expected=("warning[sna48]",))
        source("cpc.asm", '        DEVICE AMSTRADCPC464\n        INCLUDE "program.asm"\n'
                          '        SAVEAMSDOS "sjasmplus.amsdos", start, program_end - start, start\n')
        run([sjasm, "--nologo", "cpc.asm"], tmp)
        run([appmake, "+cpc", "-b", "image.bin", "--org", ORG, "--exec", ORG, "-o", "am.cpc"], tmp)
        # appmake +trs80 names its output after the crt0 file and does nothing without one.
        run([appmake, "+trs80", "-b", "image.bin", "-c", "image", "--org", ORG, "--cmd"], tmp)
        run([appmake, "+msx", "-b", "image.bin", "--org", ORG, "-o", "am.msx"], tmp)

        for made, name in (("program.tap", "program.tap"), ("program.sna", "program.sna"),
                           ("sna_stack.sna", "sna_stack.sna"), ("sjasmplus.amsdos", "program.amsdos"),
                           ("am.cpc", "program_appmake.amsdos"), ("image.cmd", "program.cmd"),
                           ("am.msx", "program.msx")):
            shutil.copy(os.path.join(tmp, made), os.path.join(FORMATS, name))
            print("%-24s %5d bytes" % (name, os.path.getsize(os.path.join(FORMATS, name))))


if __name__ == "__main__":
    main()
