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
| Preparation | `fetch.py` writes `zx-spectrum-rom.prepared.asm`: the `include "zx-spectrum-sysvars.asm"` line is replaced by that file's text and the `OUTPUT "48.ROM"` line is dropped, because INCLUDE and OUTPUT are not in z80asm 0.1. No other change. |
| Result | Identical: 16384 bytes, 0 differences, same SHA-1, at runtime and at comptime (`-Dprograms-comptime=true`). Times are under Performance. |

## Performance

The full Spectrum ROM (17,699 lines after preparation), before the
optimizations and in 0.1.0. Zig 0.16.0, Windows x86_64.

| | Before | 0.1.0 |
|---|---|---|
| Comptime: compile time | 28 min | 50 s |
| Comptime: peak memory | about 5 GB | 1,067 MB |
| Runtime, ReleaseFast | 13.1 ms | 3.4 ms |
| Runtime, Debug | 107.6 ms | 40.7 ms |

Comptime is the test's compile step with `-Dprograms-comptime=true`, in a
Debug build as the tests use, so it includes the 0xAA overwrite of line
copies. Peak memory for 0.1.0 is the largest working set of any zig
process during that build, from an empty cache; "before" is Zig's own
rounded MaxRSS ("5G"). Runtime is the median of 25 runs of `zig build bench`.

The goal of 1 GB is missed by about 7%. What is left is spread over parsing,
expressions and encoding at comptime, where every intermediate value stays
in the compiler's memory until the comptime call ends; no single part
accounts for 10%. The largest single one, the [64]Token array of each line,
is about 6%.

### Step by step

`zig build bench` times the full ROM and a slice of its first 2,528 lines and
writes that slice; `zig build bench-comptime -Dnonce=N` assembles the slice at
comptime (-Dbench-lines picks another length). Slice times are the compile
step from `--summary all`, including about 2 s and 260 MB that the same test
takes for a 10-line slice.

| Change | Runtime, full ROM (ReleaseFast / Debug) | Comptime, 2,528 lines | Comptime, full ROM |
|---|---|---|---|
| Baseline | 13.1 ms / 107.6 ms | 48 s, 720 MB | 28 min, 5 GB |
| Symbol hash table | 5.3 ms / 46.7 ms | 45 s, 717 MB | |
| Keyword, register and condition tables | 5.2 ms / 44.7 ms | 12 s, 320 MB | |
| Line ends found 32 bytes at a time | 5.3 ms / 43.9 ms | 11 s, 319 MB | 3 min 52 s, about 1 GB |
| Source read in 4 KB blocks | 5.4 ms / 44.1 ms | 8 s, 343 MB | |
| Overlap bitmap as a byte slice | 3.1 ms / 39.1 ms | 8 s, 312 MB | 49 s, 1,068 MB |
| Line copies overwritten after use (Debug) | 3.1 ms / 39.5 ms | | 48 s, 1,076 MB |
| DB and DW without a limit on values (not an optimization) | 3.4 ms / 40.7 ms | | 50 s, 1,067 MB |

The last change costs 0.3 ms at runtime without running any new code on
the ROM: the DB and DW lines there all fit in one token buffer. Moving the
new dispatch back out of `statement()` made it 3.5 ms, so the difference
comes from how the compiler lays out the changed functions.

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
