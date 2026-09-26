"""Regenerates test/cases/*.bin with sjasmplus. The .bin files are committed,
so `zig build test` does not need sjasmplus.

Usage, from the repository root:
    python compare/gen_refs.py
"""

import glob
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "..", "test", "cases")
SJASM = os.path.join(HERE, "..", "tools", "sjasmplus", "sjasmplus-1.24.0.win", "sjasmplus.exe")

# sjasmplus rejects backslashes in paths, so run it next to the files.
for asm in sorted(os.path.basename(p) for p in glob.glob(os.path.join(CASES, "*.asm"))):
    out = asm[:-4] + ".bin"
    r = subprocess.run([SJASM, "--nologo", "--raw=" + out, asm], capture_output=True, text=True, cwd=CASES)
    noise = [l for l in r.stdout.splitlines() + r.stderr.splitlines()
             if l and not l.startswith("Pass") and not l.startswith("Errors: 0")]
    if r.returncode != 0 or noise:
        print("\n".join(noise))
        sys.exit("sjasmplus did not accept %s cleanly" % asm)
    print("%-18s %5d bytes" % (out, os.path.getsize(os.path.join(CASES, out))))
