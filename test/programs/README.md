# Known programs

`zig build programs -Dthirdparty=DIR` assembles real programs with z80asm and
compares the result byte for byte with the original binaries. None of the
third-party files are in this repository. `fetch.py DIR` downloads them from
pinned locations, checks their SHA-256, and builds the SDCC reference.

```
python test/programs/fetch.py ../z80asm-thirdparty
zig build programs -Dthirdparty=../z80asm-thirdparty
zig build programs -Dthirdparty=../z80asm-thirdparty -Dprograms-comptime=true
```

The last form also assembles the Spectrum ROM at comptime, which is slow.

## ZX Spectrum 48K ROM

| | |
|---|---|
| Source | [z00m128/zxs-rom](https://github.com/z00m128/zxs-rom) at `7e9972caa482db3b165e0af5560d58ec0af5a4b5`: `zx-spectrum-rom.asm`, `zx-spectrum-sysvars.asm` |
| Origin of the text | The Complete Spectrum ROM Disassembly (Dr. Ian Logan, Dr. Frank O'Hara), with corrections and comments by others; sjasmplus adaptation by z00m |
| Reference binary | `48.rom` from the Fuse emulator, SHA-1 `5ea7c2b824672e914525d1d5c419d71b84a426a2` (the value MAME lists for the 48K ROM) |
| License | The ROM code is copyright Amstrad plc. Amstrad allows distribution of the ROMs for use with emulators but keeps the copyright (message by Cliff Lawson, comp.sys.sinclair, 1999-08-31, reproduced in the repository's LICENSE.md). It may not be sold or included in this repository. |
| Preparation | The `include "zx-spectrum-sysvars.asm"` line is replaced by that file's text and the `OUTPUT "48.ROM"` line is dropped, because INCLUDE and OUTPUT are not in z80asm 0.1. No other change. |
| Result | Identical: 16384 bytes, 0 differences, same SHA-1. |

## SDCC

| | |
|---|---|
| Source | `sdcc_sample.c` in this directory, written for this test (functions, loops, switch, struct, const tables and strings; no globals, so everything is in `_CODE`) |
| Compiler | SDCC 4.5.0 #15242, `sdcc -mz80 -S` |
| Reference binary | `sdasz80`, `sdldz80 -b _CODE=0x0000`, `makebin`, cut to the range the linker filled |
| Result | Identical: 226 bytes. The SDCC output uses `d (ix)` operands, `#<` / `#>` low and high bytes and reusable `00101$` labels, which z80asm supports for this reason. |

## ZEXDOC (not done)

| | |
|---|---|
| Source | [agn453/ZEXALL](https://github.com/agn453/ZEXALL) at `8f71d418bae69a476a5a0e5c6e122c8801b8d9f4`, `zexdoc.z80` (Frank D. Cringle, GPL-2.0) |
| Status | Skipped: the source defines and uses macros (`tstr`, `tmsg`, lines 170-192, with M80-style `&lab` parameters and conditionals). Macros are planned after the first release. |
