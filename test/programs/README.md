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
| Preparation | None. The source INCLUDEs `zx-spectrum-sysvars.asm`, which the test passes in `.files` and the command-line tool reads from next to it, and names its OUTPUT `48.ROM`. Up to 0.2, which had neither INCLUDE nor OUTPUT, `fetch.py` put the sysvars text in place of the INCLUDE and dropped the OUTPUT line. |
| Result | Identical: 16384 bytes, 0 differences, same SHA-1, at runtime, at comptime (`-Dprograms-comptime=true`) and from the command-line tool. Times are under Performance. |

## Performance

The full Spectrum ROM (17,699 lines with the sysvars file), before the
optimizations, in 0.1.0, 0.2.0, 0.3.0 and 0.3.1. Zig 0.16.0, Windows x86_64.

| | Before | 0.1.0 | 0.2.0 | 0.3.0 | 0.3.1 |
|---|---|---|---|---|---|
| Comptime: compile time | 28 min | 50 s | 48 s | 58 s | 51 s |
| Comptime: peak memory | about 5 GB | 1,067 MB | 1,040 MB | 1,053 MB | 1,053 MB |
| Runtime, ReleaseFast | 13.1 ms | 3.4 ms | 3.4 ms | 4.0 ms | 3.7 ms |
| Runtime, Debug | 107.6 ms | 40.7 ms | 40.7 ms | 41.3 ms | 39.9 ms |

Comptime is the test's compile step with `-Dprograms-comptime=true`, in a
Debug build as the tests use, so it includes the 0xAA overwrite of line
copies. Peak memory for 0.1.0 and 0.2.0 is the largest working set of any
zig process during that build, from an empty cache; "before" is Zig's own
rounded MaxRSS ("5G"). Runtime is the median of 25 runs of `zig build bench`.

0.2.0 is a code review cleanup with no new features. The table gives 0.1.0
as it was measured for that release. Measured on the same day as 0.2.0
(three comptime builds and five `zig build bench` runs each), 0.1.0 took
48 s, 1,069-1,070 MB, 3.39 ms and 41.07 ms, and 0.2.0 48-49 s, 1,040 MB,
3.42 ms and 40.70 ms.

0.3.0 was measured on a slower day than the columns before it. 0.2.0,
measured again that day (one comptime build and ten `zig build bench` runs,
interleaved with those of 0.3.0), took 59 s, 1,039 MB, 3.74 ms and 41.5 ms.
So at comptime 0.3.0 takes as long as 0.2.0 and 14 MB more, and at runtime
it is about 7% slower in ReleaseFast and as fast in Debug. The runtime cost
came with the comparison and logical operators and with conditional
assembly; later steps took back part of it (see Step by step).

0.3.1 fixes bugs and adds nothing. On its day 0.3.0 took 52 s, 1,052 MB,
3.76 ms and 39.5 ms, and 0.3.1 51 s, 1,053 MB, 3.71 ms and 39.9 ms (one
comptime build and 25 `zig build bench` runs each): the same.

The cleanup first made comptime about 2% slower. Three of its changes cost
time at comptime, where every function call is interpreted: the per-pass
fields in a nested struct (about 0.5 s on the ROM), std.hash.Fnv1a_32 with
its init, update and final calls (about 0.25 s) and prefix checks through a
helper around std.ascii.startsWithIgnoreCase (0.5 s). The first two are
undone and the third was not kept. A precedence table as a std.EnumArray
constant cost another 0.5 s, so it stays a switch. At runtime, register
lookups hashed names of up to 6 characters instead of 3, which is fixed.

To find these, the changes were added one at a time to 0.1.0 and the full
ROM assembled at comptime with `zig test` from an empty cache. A run takes
about 50 s and repeated runs spread by up to 2 s, so no single step stood
out; the candidates were then measured in pairs, five interleaved runs
each.

The goal of 1 GB is missed by about 4% in 0.2.0 and 5% in 0.3.0 (7% in 0.1.0). What is left is spread over parsing,
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
| Code review cleanup, 0.2.0 (not an optimization) | 3.4 ms / 40.7 ms | | 48 s, 1,040 MB |
| 0.2.0 again, on the day of the 0.3 steps | 3.61 ms / 41.5 ms | | 59 s, 1,039 MB |
| Entry address, the com format and the cpm machine | 3.63 ms / 42.8 ms | | 57 s, 1,040 MB |
| Comparison and logical operators | 3.79 ms / 42.0 ms | | 60 s, 1,070 MB |
| Conditional assembly | 4.09 ms / 42.5 ms | | 57 s, 1,094 MB |
| sjasmplus local labels | 4.16 ms / 42.3 ms | | 60 s, 1,095 MB |
| Fewer token tags, the label check only on IF lines | 4.07 ms / 40.8 ms | | 57 s, 1,060 MB |
| Directive and instruction aliases outside the Keyword enum | 3.96 ms / 40.7 ms | | 57 s, 1,048 MB |
| File table: INCLUDE, INCBIN, OUTPUT | 3.85 ms / 40.3 ms | | 57 s, 1,051 MB |
| Formats tap, amsdos, cmd and msx, FORMAT | 3.99 ms / 40.7 ms | | 57 s, 1,052 MB |
| Format sna | 3.82 ms / 41.7 ms | | 57 s, 1,052 MB |
| Review fixes, 0.3.0 | 3.81 ms / 41.3 ms | | 58 s, 1,053 MB |
| Bug fixes, 0.3.1 | 3.71 ms / 39.9 ms | | 51 s, 1,053 MB |

The DB and DW change costs 0.3 ms at runtime without running any new code on
the ROM: the DB and DW lines there all fit in one token buffer. Moving the
new dispatch back out of `statement()` made it 3.5 ms, so the difference
comes from how the compiler lays out the changed functions.

The 0.3 rows were measured on one day, starting with 0.2.0 again. The medians
of `zig build bench` spread by up to 0.5 ms that day, so their ReleaseFast
time is the lowest of the 25 runs, as the median of five runs interleaved
across the steps; Debug is the median of one run, and comptime one build
from an empty cache. Differences of about 0.1 ms and 2 s are within the
spread. From the file table on, the ROM is the unmodified source with its
INCLUDE. Comparisons, logical operators and conditional assembly cost
memory at comptime (up to 1,095 MB) until fewer token tags and the aliases
outside the Keyword enum took it back, since every tag of an enum that the
parser switches on costs compiler memory.

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
| Status | Skipped: the source defines and uses macros (`tstr`, `tmsg`, lines 170-192, with M80-style `&lab` parameters and conditionals). Macros are planned for 0.5, with ZEXDOC as their test. |
