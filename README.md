# zig-z80asm

A Z80 assembler for Zig, as the package and module `z80asm`. It takes
ordinary Z80 assembly source, such as a `.asm` file, and turns it into
bytes: at comptime, where they become a `[]const u8` constant and errors
are compile errors, or at runtime, where errors come back as data. The
bytes can be the memory image or the file a machine loads: a CP/M `.com`, a
ZX Spectrum `.tap` or `.sna`, an Amstrad CPC file with its AMSDOS header, a
TRS-80 `/CMD` or an MSX BLOAD file. It needs no allocator and does no I/O:
the caller provides the output, symbol and diagnostic buffers, and the
files that INCLUDE and INCBIN name.

## Why

Zig's comptime can run ordinary Zig code during compilation, so this
library turns the Zig compiler into a cross-assembler for a CPU it has no
backend for. A Z80 program is built by `zig build` with no external
assembler and no extra build step. Addresses, tables and constants are
defined once and shared between the Z80 code and the host tools, and a
mistake such as a jump out of range or an overlapping write stops the build.

## Use

Write the program as ordinary Z80 assembly, for example `program.asm`:

```asm
        ORG 8000h
start:  LD B,5
        XOR A
loop:   ADD A,3         ; runs B times
        DJNZ loop
        LD (result),A
        RET
result: DB 0
```

### At comptime

One line in the Zig program assembles the file while it compiles:

```zig
const z80 = @import("z80asm");

const program = z80.comptimeAssemble(@embedFile("program.asm"), .{});
```

`program` is a `[]const u8` constant with the bytes, here
`06 05 AF C6 03 10 FC 32 0B 80 C9 00`. Inside a function, write
`comptime z80.comptimeAssemble(...)`. A mistake in the source stops the
build with the assembler's messages:

```
src/root.zig:88:9: error: Z80 assembly failed:
                          line 2: undefined symbol 'strat'
```

The options are `origin` (the address of the first byte when the source does
not start with ORG, default 0), `machine` and `format` (see Output formats),
`files` (the files INCLUDE and INCBIN can name), `max_symbols` (default 2048)
and `max_diagnostics` (default 16). With a format, the constant is that
file:

```zig
const game = z80.comptimeAssemble(@embedFile("game.asm"), .{
    .format = .{ .tap = .{ .name = "game" } },
    .files = &.{.{ .name = "font.bin", .data = @embedFile("font.bin") }},
});
```

### At runtime

The same source text, read or generated while the program runs:

```zig
var workspace: z80.Workspace(0x10000, 4096, 32) = undefined;

const result = z80.assemble(source, .{}, workspace.buffers());
if (!result.ok()) {
    for (result.diagnostics) |d| std.debug.print("{f}\n", .{d});
}
// result.bytes is the memory image, starting at result.origin, and
// result.entry the operand of END. The file of the chosen format:
const file = try allocator.alloc(u8, z80.formats.fileLen(result.format, result.bytes.len));
const data = z80.formats.write(result.format, result.image(), file);
```

`Workspace(output_size, symbol_slots, diagnostic_count)` is large (the
example is about 260 KB), so keep it global or on the heap. `symbol_slots`
must be a power of two; half of it is the symbol capacity. A name in
INCLUDE or INCBIN is relative to the directory of the file that names it:
what `lib/util.inc` includes as `data.inc` is `lib/data.inc` in `.files`.
A file that `.files` does not have is an error, and `result.missing` lists
it with that directory and the file and line that name it, so a caller that
can read files adds them and assembles again, as the command-line tool does.

### Command line

`zig build` in this repository also installs a command-line assembler:

```
z80asm [--origin ADDR] [--machine NAME] [--format NAME] [-I DIR]... INPUT.asm [OUTPUT]
```

It reads the files that INCLUDE and INCBIN name, next to the file that names
them or in an `-I` directory. Without OUTPUT it writes to the file that
OUTPUT in the source names, next to INPUT.asm. `z80asm game.asm game.tap`
writes a tap file named `game`.

### Installing

Requires Zig 0.16.0.

```
zig fetch --save git+https://github.com/imandicdev/zig-z80asm#v0.3.1
```

and import the module in `build.zig`:

```zig
const z80asm = b.dependency("z80asm", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("z80asm", z80asm.module("z80asm"));
```

### Generating code from Zig (optional)

The assembler can also be driven from Zig, for code that is easier to
compute than to write, such as tables. These calls go through the same path
as source text and can be mixed with source lines. The program above,
partly as calls:

```zig
fn program(_: void, a: *z80.Assembler) z80.Assembler.Error!void {
    a.org(0x8000);
    try a.line("times EQU 5");
    try a.line("  LD B,times");
    try a.emit(z80.isa.aluR(.xor, .a)); // A = 0
    try a.label("loop");
    try a.emit(z80.isa.aluN(.add, 3)); // runs B times
    try a.line("  DJNZ loop");
    try a.emit(z80.isa.ldMemA(try a.word("result")));
    try a.emit(z80.isa.ret());
    try a.label("result");
    try a.bytes(&.{0});
}

const image = z80.comptimeBuild(.{}, {}, program);
// or at runtime: z80.run(.{}, workspace.buffers(), {}, program)
```

The body runs once per pass, so it must do the same thing every time. Names
given to `label` and `equ`, and text given to `line`, are not copied and must
stay valid until assembly ends.

## Syntax

The syntax is that of sjasmplus for ordinary sources, plus what SDCC output
needs for sdasz80.

- Instructions: every documented Z80 instruction, and the common
  undocumented ones: SLL (also SLI), IXH/IXL/IYH/IYL, `IN F,(C)` / `IN (C)`
  and `OUT (C),0`.
- Numbers: `42`, `0x2A`, `$2A`, `2Ah`, `0b101010`, `101010b`, `%101010`,
  `#2A`, `'*'`.
- Expressions: `+ - * / %`, `& | ^ ~`, `<< >>`, `== != < > <= >=`,
  `&& || !`, parentheses, `$` for the address of the current statement, and
  SDCC's `#<x` and `#>x` for the low and high byte. Precedence from lowest,
  as in sjasmplus: `||`, `&&`, `|`, `^`, `&`, `== !=`, `< > <= >=`, shifts,
  `+ -`, `* / %`. True is -1 and false 0, as in sjasmplus, so `DB 1==1` gives
  FF.
- Labels: `name:`, `name::`, or a name in column 0 that is not an
  instruction or directive. `name EQU value` and `name = value`. sjasmplus
  local labels: `.loop` after the label `outer` (or after an EQU or `=`) is
  `outer.loop`, which can be used anywhere. SDCC's `00101$` labels are local
  to the part between two ordinary labels.
- Directives: ORG; DB, DEFB, DEFM, DM; DW, DEFW; DS, DEFS (count and
  optional fill byte); END with an optional entry address; INCLUDE "file";
  INCBIN "file"[, offset[, length]]; OUTPUT "file"; FORMAT name[, "title"];
  and the SDCC forms
  `.org .db .byte .dw .word .ds .ascii .asciz .area .globl .module .optsdcc`.
- Conditional assembly: IF, IFDEF, IFNDEF, ELSEIF, ELSE and ENDIF, up to 32
  deep. A skipped block is only scanned for these, so it may hold code for
  another assembler. IF may use a forward reference.
- Strings: sjasmplus escapes in `"..."`, `''` for a quote inside `'...'`.

Writing an address twice is an error. Forward references are resolved in up
to 8 passes. INCLUDE nests up to 16 files deep.

## Output formats

| Format | File | Machine | Extension | Checked against |
|---|---|---|---|---|
| bin | the memory image | | `.bin` | |
| com | CP/M: the image, which must start at 0x0100 | `cpm` | `.com` | sjasmplus `--raw`; cpm2sim runs it |
| tap | ZX Spectrum tape: a CODE header block and its data block, without a BASIC loader | `zx48` | `.tap` | sjasmplus `SAVETAP` |
| sna | ZX Spectrum 48K snapshot: registers and the RAM from 0x4000 | | `.sna` | sjasmplus `SAVESNA` |
| amsdos | Amstrad CPC: the image after a 128-byte AMSDOS header | `cpc` | | sjasmplus `SAVEAMSDOS`, z88dk appmake `+cpc` |
| cmd | TRS-80 /CMD: load records and a transfer record | `trs80` | `.cmd` | appmake `+trs80 --cmd` |
| msx | MSX BLOAD: the header FE, start, end, entry, and the image | `msx` | | appmake `+msx` |

The format is the first of: `.format` in the options (`--format` in the
command-line tool), `FORMAT name[, "title"]` in the source, the machine's,
the extension of the output file (command-line tool only), and bin. A
machine is the CPU, the Z80 for all of them, and a format; `cpm` also makes
0x0100 the origin when the source has no ORG.

- The entry address is the operand of END, or the origin without one: BC and
  the stack in sna, and the entry fields of amsdos, cmd and msx.
- The title of FORMAT, or `.name` in `.format`, is the name in a tap or
  AMSDOS header; the command-line tool fills an empty one from the output
  file's name.
- sna holds the RAM as sjasmplus sets it up for DEVICE ZXSPECTRUM48 (the
  attributes, the system variables, a stack under RAMTOP 0x5D5B and the UDG
  letters) with the image in it, the registers that SAVESNA writes, and the
  start on the stack, or at 0x4000 when the image covers that stack. The
  image must lie in 0x4000-0xFFFF.
- The msx end address is the last byte, which Disk BASIC's BSAVE writes and
  BLOAD reads; appmake writes 2 more.

## Differences from sjasmplus

Seven, all deliberate:

- The output is a memory image from the lowest to the highest address
  written. Gaps between ORGs are zeros, and code after an ORG below earlier
  code goes to its own address. sjasmplus `--raw` writes the bytes in the
  order they are assembled and leaves the gaps out, and in an sna file it
  keeps the memory it set up in the gaps.
- `#` is a hex prefix only where SDCC cannot read the number as decimal:
  `#2A` and `#FF` are hex, `#5` is 5 either way, and `#4000` is an error
  instead of 0x4000. Otherwise `#` is SDCC's immediate marker, as in
  `#0x0a` or `#_table`.
- DB and DW take any number of values; sjasmplus stops at 128 bytes in one
  DB and 128 values in one DW.
- An instruction or directive in column 0 is assembled as one: `NOP` there
  gives 00. sjasmplus reads anything in column 0 as a label, so the same
  line defines a label NOP and emits nothing.
- IFDEF and IFNDEF test symbols (labels and EQU) defined earlier in the
  pass. In sjasmplus they test DEFINE names, which z80asm does not have.
- A shift by a count outside 0..31 gives 0. sjasmplus gives what the x86
  shift instruction does with the count mod 32 (`1 << 32` is 1), which its
  C++ source leaves undefined.
- `SUB A,B`, `AND A,B`, `XOR A,B`, `OR A,B` and `CP A,B` are `SUB B` and so
  on, as Zilog's notation, M80 and z88dk read them. sjasmplus reads the
  comma as a second instruction: `AND A,B` is `AND A` followed by `AND B`.

## Not in 0.3

- Macros and REPT (planned for 0.5), and DEFINE.
- sjasmplus DEVICE and its SAVE directives: FORMAT and the options choose
  the file instead.
- A BASIC loader in tap files, and snapshots other than the 48K sna.
- `=` as equality inside expressions; it only defines a symbol.
- Listing and symbol files.
- SDCC areas other than `_CODE`: they may appear, but without code or labels.
- More than 64 tokens on a line, except in DB and DW, which take any number
  of values of up to 62 tokens each.

## Verification

- Every documented instruction form is byte-identical to sjasmplus and
  z88dk z80asm (810 cases, all 696 opcodes of the documented list); the
  undocumented ones are checked against sjasmplus (106 cases). This holds for
  the encoders in `z80.isa` and for the assembler at comptime and at runtime.
- The ZX Spectrum 48K ROM, assembled from its disassembly, is identical to
  the original ROM at comptime and at runtime, and SDCC 4.5.0 output is
  identical to what sdasz80 makes of it. See
  [test/programs/README.md](test/programs/README.md).
- The output formats are byte-identical to what sjasmplus or z88dk appmake
  write for the same program, at comptime, at runtime and from the
  command-line tool (msx apart from its end address), and a CP/M program
  assembled for the `cpm` machine prints its text in cpm2sim.
- The error cases in `test/reject_cases.zig` give the same message as a
  comptime compile error and as a runtime diagnostic (the two about
  comptime options only at comptime).

The full Spectrum ROM, 17,699 lines, assembles at comptime in about a
minute with a peak of about 1 GB of compiler memory, and at runtime in about
4 ms (ReleaseFast); the measurements are in
[test/programs/README.md](test/programs/README.md).

## Tests

```
zig build test
```

runs the unit tests, the cases in `test/cases` against their sjasmplus
output, the output formats in `test/formats` against the files of sjasmplus
and appmake, and the reject cases in both modes. The reference files are in
the repository, so no other assembler is needed.

```
zig build cpm
```

assembles `test/cases/cpm_hello.asm` for the `cpm` machine and runs it in
the ZEX harness of cpm2sim, a CP/M simulator in a separate repository
(`-Dcpm2sim=DIR` or `CPM2SIM`, by default
`../cpm2sim`), which must print its text. cpm2sim builds with Zig 0.15,
which `-Dcpm2sim-zig` or `CPM2SIM_ZIG` names. Without cpm2sim the step is
skipped with a message.

```
python compare/gen_isa.py --sjasmplus PATH --z88dk-z80asm PATH
zig build compare
```

compares every instruction form with the reference assemblers. The paths
can also be given in the `SJASMPLUS` and `Z88DK_Z80ASM` environment
variables, and the scripts check the versions:

| Assembler | Version | Build used | SHA-256 of the archive |
|---|---|---|---|
| [sjasmplus](https://github.com/z00m128/sjasmplus/releases/tag/v1.24.0) | 1.24.0 | `sjasmplus-1.24.0.win.zip` | `7e1f8840842039bdb97e51a59abda2e5c25a9da160097e8f79a62583ab72d0e0` |
| [z88dk](https://github.com/z88dk/z88dk/releases/tag/v2.4) | 2.4 (z88dk-z80asm 23854-4d530b6eb7-20251002) | `z88dk-win32-2.4.zip` | `26d9880ee2e43077808ac86a4b6247a81f5dadc30563ca7cedc58bc4fb5ccb57` |

`python compare/gen_refs.py --sjasmplus PATH` regenerates `test/cases/*.bin`,
and `python compare/gen_formats.py --sjasmplus PATH --z88dk-appmake PATH`
the files in `test/formats` (appmake is `z88dk-appmake` from the same z88dk
archive).
`zig build programs -Dthirdparty=DIR` assembles the known programs, which
are not in this repository; see [test/programs/README.md](test/programs/README.md).

## Authorship

Design and architecture are mine; parts of the implementation were written
with LLM assistance. Every instruction encoding is verified byte-for-byte
against sjasmplus, the documented ones also against z88dk z80asm, and the
full ZX Spectrum 48K ROM rebuilds byte-identical at comptime and at runtime.

## License

MIT, see [LICENSE](LICENSE).
