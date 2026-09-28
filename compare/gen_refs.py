"""Regenerates test/cases/*.bin with sjasmplus. The .bin files are committed,
so `zig build test` does not need sjasmplus.

sjasmplus takes at most 128 bytes in one DB and 128 values in one DW, so
longer data lines are split before it sees them. That gives the same bytes
as long as those lines do not use $.

Usage, from the repository root:
    python compare/gen_refs.py --sjasmplus PATH
or with the path in the SJASMPLUS environment variable.
"""

import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile

import reference

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "..", "test", "cases")

DATA = re.compile(r"^(\s+)(DB|DEFB|DW|DEFW)\s+(.*)$", re.IGNORECASE)
CHUNK = 64


def values(text):
    """The values of a data line, split at the commas outside strings."""
    out, start, quote, i = [], 0, None, 0
    while i < len(text):
        c = text[i]
        if quote:
            if c == "\\" and quote == '"':
                i += 1
            elif c == quote:
                quote = None
        elif c in "\"'":
            quote = c
        elif c == ";":
            break
        elif c == ",":
            out.append(text[start:i])
            start = i + 1
        i += 1
    out.append(text[start:i])
    return out


def split_data(source):
    lines = []
    for line in source.split("\n"):
        mo = DATA.match(line)
        vals = values(mo.group(3)) if mo else []
        if len(vals) <= CHUNK:
            lines.append(line)
            continue
        if any("$" in v for v in vals):
            sys.exit("a data line with more than %d values uses $: %s" % (CHUNK, line[:60]))
        for i in range(0, len(vals), CHUNK):
            lines.append("%s%s %s" % (mo.group(1), mo.group(2), ",".join(vals[i:i + CHUNK])))
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Regenerates test/cases/*.bin with sjasmplus.")
    reference.add_option(parser, reference.SJASMPLUS)
    sjasm = reference.path(parser, parser.parse_args(), reference.SJASMPLUS)

    # sjasmplus rejects backslashes in paths, so run it next to the files,
    # with the files that cases INCLUDE (*.inc) and INCBIN (*.dat).
    with tempfile.TemporaryDirectory() as tmp:
        for extra in glob.glob(os.path.join(CASES, "*.inc")) + glob.glob(os.path.join(CASES, "*.dat")):
            shutil.copy(extra, tmp)
        for asm in sorted(os.path.basename(p) for p in glob.glob(os.path.join(CASES, "*.asm"))):
            out = asm[:-4] + ".bin"
            with open(os.path.join(CASES, asm), newline="") as f:
                source = f.read()
            with open(os.path.join(tmp, asm), "w", newline="") as f:
                f.write(split_data(source))
            r = subprocess.run([sjasm, "--nologo", "--raw=" + out, asm], capture_output=True, text=True, cwd=tmp)
            # "include data: ..." is how sjasmplus reports each INCBIN.
            noise = [l for l in r.stdout.splitlines() + r.stderr.splitlines()
                     if l and not l.startswith(("Pass", "Errors: 0", "include data:"))]
            if r.returncode != 0 or noise:
                print("\n".join(noise))
                sys.exit("sjasmplus did not accept %s cleanly" % asm)
            shutil.copy(os.path.join(tmp, out), os.path.join(CASES, out))
            print("%-18s %5d bytes" % (out, os.path.getsize(os.path.join(CASES, out))))


if __name__ == "__main__":
    main()
