# zig-z80asm

A Z80 assembler for Zig, as the package and module `z80asm`. The same code
assembles at comptime, where the result is a `[]const u8` constant and
errors are compile errors, and at runtime, where errors come back as data.
It needs no allocator and does no I/O: the caller provides the output,
symbol and diagnostic buffers.

## Why

Zig's comptime can run ordinary Zig code during compilation, so this
library turns the Zig compiler into a cross-assembler for a CPU it has no
backend for. A Z80 program is built by `zig build` with no external
assembler and no extra build step. Addresses, tables and constants are
defined once and shared between the Z80 code and the host tools, and a
mistake such as a jump out of range or an overlapping write stops the build.

## Use

Requires Zig 0.16.0.

```
zig fetch --save git+https://github.com/imandicdev/zig-z80asm#v0.1.0
```

and import the module in `build.zig`:

```zig
const z80asm = b.dependency("z80asm", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("z80asm", z80asm.module("z80asm"));
```

### At comptime

```zig
const z80 = @import("z80asm");

const rom = z80.comptimeAssemble(@embedFile("rom.asm"), .{});
```

Inside a function, write `comptime z80.comptimeAssemble(...)`. Any error
stops the build with the assembler's messages:

```
src/root.zig:69:9: error: Z80 assembly failed:
                          line 2: undefined symbol 'strat'
```

The options are `origin` (the address of the first byte when the source does
not start with ORG, default 0), `max_symbols` (default 2048) and
`max_diagnostics` (default 16).

### At runtime

```zig
var workspace: z80.Workspace(0x10000, 4096, 32) = undefined;

const result = z80.assemble(source, .{}, workspace.buffers());
if (!result.ok()) {
    for (result.diagnostics) |d| std.debug.print("{f}\n", .{d});
}
// result.bytes is the memory image, starting at result.origin.
```

`Workspace(output_size, symbol_slots, diagnostic_count)` is large (the
example is about 260 KB), so keep it global or on the heap. `symbol_slots`
must be a power of two; half of it is the symbol capacity.

### From Zig code

Source text and Zig calls go through the same path, so a program can be
written in assembly, built from Zig code, or both. A body gets an
`*Assembler` and can mix instruction calls from `z80.isa` with source lines.
Here a DJNZ loop runs `ADD A,3` B times and stores the result:

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

### Command line

`zig build` also installs a command-line assembler:

```
z80asm [--origin ADDR] INPUT.asm OUTPUT.bin
```

## Syntax

The syntax is that of sjasmplus for ordinary sources, plus what SDCC output
needs for sdasz80.

- Instructions: every documented Z80 instruction, and the common
  undocumented ones: SLL (also SLI), IXH/IXL/IYH/IYL, `IN F,(C)` / `IN (C)`
  and `OUT (C),0`.
- Numbers: `42`, `0x2A`, `$2A`, `2Ah`, `0b101010`, `101010b`, `%101010`,
  `#2A`, `'*'`.
- Expressions: `+ - * / %`, `& | ^ ~`, `<< >>`, parentheses, `$` for the
  address of the current statement, and SDCC's `#<x` and `#>x` for the low
  and high byte. Precedence from lowest: `|`, `^`, `&`, shifts, `+ -`,
  `* / %`.
- Labels: `name:`, `name::`, or a name in column 0. SDCC's `00101$` labels
  are local to the part between two ordinary labels. `name EQU value` and
  `name = value`.
- Directives: ORG; DB, DEFB, DEFM, DM; DW, DEFW; DS, DEFS (count and
  optional fill byte); END with an optional entry address; and the SDCC forms
  `.org .db .byte .dw .word .ds .ascii .asciz .area .globl .module .optsdcc`.
- Strings: sjasmplus escapes in `"..."`, `''` for a quote inside `'...'`.

Writing an address twice is an error. Forward references are resolved in up
to 8 passes.

## Differences from sjasmplus

Three, all deliberate:

- The output is a memory image from the lowest to the highest address
  written. Gaps between ORGs are zeros, and code after an ORG below earlier
  code goes to its own address. sjasmplus `--raw` writes the bytes in the
  order they are assembled and leaves the gaps out.
- `#` is a hex prefix only where SDCC cannot read the number as decimal:
  `#2A` and `#FF` are hex, `#5` is 5 either way, and `#4000` is an error
  instead of 0x4000. Otherwise `#` is SDCC's immediate marker, as in
  `#0x0a` or `#_table`.
- DB and DW take any number of values; sjasmplus stops at 128 bytes in one
  DB and 128 values in one DW.

## Not in 0.1

- Macros, INCLUDE, INCBIN and conditional assembly.
- sjasmplus local labels such as `.loop`: they are ordinary names, so a
  second `.loop` is a duplicate.
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
- The error cases in `test/reject_cases.zig` give the same message as a
  comptime compile error and as a runtime diagnostic (the two about
  comptime options only at comptime).

The full Spectrum ROM, 17,699 lines, assembles at comptime in 50 s with a
peak of about 1 GB of compiler memory, and at runtime in 3.4 ms
(ReleaseFast).

## Tests

```
zig build test
```

runs the unit tests, the cases in `test/cases` against their sjasmplus
output, and the reject cases in both modes. The reference files are in the
repository, so no other assembler is needed.

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

`python compare/gen_refs.py --sjasmplus PATH` regenerates `test/cases/*.bin`.
`zig build programs -Dthirdparty=DIR` assembles the known programs, which
are not in this repository; see [test/programs/README.md](test/programs/README.md).

## Authorship

Design and architecture are mine; parts of the implementation were written
with LLM assistance. Every instruction encoding is verified byte-for-byte
against sjasmplus, the documented ones also against z88dk z80asm, and the
full ZX Spectrum 48K ROM rebuilds byte-identical at comptime and at runtime.

## License

MIT, see [LICENSE](LICENSE).
