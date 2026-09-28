"""Downloads the third-party programs for `zig build programs` into a directory
outside the repository, checks their SHA-256 and builds the SDCC reference.

Usage, from the repository root:
    python test/programs/fetch.py ../z80asm-thirdparty
    zig build programs -Dthirdparty=../z80asm-thirdparty

The SDCC part needs sdcc, sdasz80, sdldz80 and makebin on PATH.
"""

import hashlib
import os
import shutil
import subprocess
import sys
import urllib.request

ZXS_ROM = "https://raw.githubusercontent.com/z00m128/zxs-rom/7e9972caa482db3b165e0af5560d58ec0af5a4b5/"
FILES = [
    ("spectrum-rom/zx-spectrum-rom.asm", ZXS_ROM + "zx-spectrum-rom.asm",
     "de6e4483fd482761a9f2579666db77af824d4e28340324888b3a8070ad77f019"),
    ("spectrum-rom/zx-spectrum-sysvars.asm", ZXS_ROM + "zx-spectrum-sysvars.asm",
     "70c1462e9842c3df33b0c6e8564be4b9469f5d319193faeb11305eb3413be7eb"),
    ("spectrum-rom/LICENSE.md", ZXS_ROM + "LICENSE.md",
     "cbabf234860cb58807a9b4155cda825c0a008157c0ead7d059e0523e6c94572f"),
    # The original ROM as shipped with the Fuse emulator; its SHA-1
    # 5ea7c2b824672e914525d1d5c419d71b84a426a2 is the one MAME lists.
    ("spectrum-rom/48.rom", "https://sourceforge.net/p/fuse-emulator/fuse/ci/master/tree/roms/48.rom?format=raw",
     "d55daa439b673b0e3f5897f99ac37ecb45f974d1862b4dadb85dec34af99cb42"),
]


def fetch(root):
    for rel, url, sha256 in FILES:
        path = os.path.join(root, rel)
        if not os.path.exists(path):
            os.makedirs(os.path.dirname(path), exist_ok=True)
            req = urllib.request.Request(url, headers={"User-Agent": "curl/8"})
            with urllib.request.urlopen(req) as r, open(path, "wb") as f:
                f.write(r.read())
        digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
        if digest != sha256:
            sys.exit("%s: SHA-256 %s, expected %s" % (rel, digest, sha256))
        print("ok  %s" % rel)


def build_sdcc_reference(root):
    out = os.path.join(root, "sdcc")
    os.makedirs(out, exist_ok=True)
    shutil.copy(os.path.join(os.path.dirname(os.path.abspath(__file__)), "sdcc_sample.c"), out)

    def run(*args):
        subprocess.run(args, cwd=out, check=True, stdout=subprocess.DEVNULL)

    run("sdcc", "-mz80", "-S", "sdcc_sample.c", "-o", "sdcc_sample.asm")
    run("sdasz80", "-o", "sdcc_sample.rel", "sdcc_sample.asm")
    run("sdldz80", "-i", "-b", "_CODE=0x0000", "sdcc_sample.ihx", "sdcc_sample.rel")
    run("makebin", "sdcc_sample.ihx", "sdcc_sample.full.bin")

    # makebin pads to 32K; keep the range the linker actually filled.
    lo, hi = None, 0
    for line in open(os.path.join(out, "sdcc_sample.ihx")):
        count, addr, kind = int(line[1:3], 16), int(line[3:7], 16), int(line[7:9], 16)
        if kind == 0 and count:
            lo = addr if lo is None else min(lo, addr)
            hi = max(hi, addr + count)
    image = open(os.path.join(out, "sdcc_sample.full.bin"), "rb").read()[lo:hi]
    open(os.path.join(out, "sdcc_sample.sdas.bin"), "wb").write(image)
    print("ok  sdcc/sdcc_sample.sdas.bin (%d bytes at 0x%04X)" % (len(image), lo))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    fetch(sys.argv[1])
    build_sdcc_reference(sys.argv[1])
