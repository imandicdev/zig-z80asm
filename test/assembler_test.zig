const std = @import("std");
const z80 = @import("z80asm");
const isa = z80.isa;
const Assembler = z80.Assembler;

var workspace: z80.Workspace(0x10000, 1024, 16) = undefined;

fn runtime(source: []const u8) z80.Result {
    return z80.assemble(source, .{}, workspace.buffers());
}

/// Both modes must produce `expected`.
fn expectBytes(comptime source: []const u8, expected: []const u8) !void {
    const at_comptime = comptime z80.comptimeAssemble(source, .{});
    const r = runtime(source);
    try expectOk(r);
    try std.testing.expectEqualSlices(u8, expected, at_comptime);
    try std.testing.expectEqualSlices(u8, expected, r.bytes);
}

fn expectOk(r: z80.Result) !void {
    if (r.ok()) return;
    for (r.diagnostics) |d| std.debug.print("{f}\n", .{d});
    return error.TestUnexpectedDiagnostics;
}

fn expectDiagnostic(source: []const u8, expected: []const u8) !void {
    const r = runtime(source);
    try std.testing.expect(r.diagnostics.len > 0);
    var buf: [200]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try std.fmt.bufPrint(&buf, "{f}", .{r.diagnostics[0]}));
}

test "lines longer than the read buffer and labels used across buffer refills" {
    const long = "x" ** 5000;
    const source = "first: NOP\n; " ++ long ++ "\n" ++ ("  NOP ; filler\n" ** 400) ++
        "big: NOP ; " ++ long ++ "\n  JP first\n  JP big\n  JR last\nlast: NOP\n";
    const expected = [_]u8{0} ** 402 ++ [_]u8{ 0xC3, 0x00, 0x00, 0xC3, 0x91, 0x01, 0x18, 0x00, 0x00 };
    try expectBytes(source, &expected);
}

fn longLines(_: void, a: *Assembler) Assembler.Error!void {
    try a.line("start: NOP ; " ++ "y" ** 300);
    try a.line("short: JP start");
    try a.line("  JP short ; " ++ "z" ** 300);
}

test "Zig bodies may pass short and long lines to line()" {
    const expected = [_]u8{ 0x00, 0xC3, 0x00, 0x00, 0xC3, 0x01, 0x00 };
    try std.testing.expectEqualSlices(u8, &expected, comptime z80.comptimeBuild(.{}, {}, longLines));
    const r = z80.run(.{}, workspace.buffers(), {}, longLines);
    try expectOk(r);
    try std.testing.expectEqualSlices(u8, &expected, r.bytes);
}

/// "s0000 EQU 0\n" to "s(n-1) EQU n-1\n".
fn equs(comptime n: usize) *const [n * 15]u8 {
    comptime {
        @setEvalBranchQuota(20 * n);
        const pattern = "s0000 EQU 0000\n";
        var text: [n * pattern.len]u8 = undefined;
        for (0..n) |i| {
            const line = text[i * pattern.len ..][0..pattern.len];
            line.* = pattern.*;
            var v = i;
            for (0..4) |k| {
                line[4 - k] = '0' + @as(u8, @intCast(v % 10));
                line[13 - k] = line[4 - k];
                v /= 10;
            }
        }
        const done = text;
        return &done;
    }
}

test "the comptime symbol capacity can be raised" {
    const image = comptime z80.comptimeAssemble(equs(2100) ++ "  DW s2099\n", .{ .max_symbols = 2100 });
    try std.testing.expectEqualSlices(u8, &.{ 0x33, 0x08 }, image);
}

/// build.zig also runs this body with comptimeBuild and expects the same
/// message as a compile error.
pub fn codeAfterEnd(_: void, a: *Assembler) Assembler.Error!void {
    try a.emit(isa.nop());
    try a.line("  END");
    a.emit(isa.halt()) catch {};
    try a.bytes("x");
}

test "every emit after END in a Zig body is an error" {
    const r = z80.run(.{}, workspace.buffers(), {}, codeAfterEnd);
    try std.testing.expectEqual(2, r.diagnostics.len);
    for (r.diagnostics) |d| {
        var buf: [200]u8 = undefined;
        try std.testing.expectEqualStrings("code after END", try std.fmt.bufPrint(&buf, "{f}", .{d}));
    }
    try std.testing.expectEqualSlices(u8, &.{0x00}, r.bytes);
}

// Features that sjasmplus also accepts are checked against it in
// test/cases_test.zig. SDCC syntax is not, so it is checked here.

test "SDCC syntax" {
    try expectBytes(
        \\  .area _CODE
        \\_f::
        \\00101$:
        \\  ld a, #0x01
        \\  sub a, b
        \\  jr NZ, 00101$
        \\  .db #0x42
        \\  .ascii "ok"
        \\  .asciz "z"
    , &.{ 0x3E, 0x01, 0x90, 0x20, 0xFB, 0x42, 'o', 'k', 'z', 0 });
}

test "empty SDCC areas are accepted" {
    try expectBytes(
        \\  .area _DATA
        \\  .area _DABS (ABS)
        \\  .area _CODE
        \\  ret
        \\  .area _INITIALIZER
        \\  .area _CABS (ABS)
    , &.{0xC9});
}

test "sdas index operands, low/high byte and reusable local labels" {
    try expectBytes(
        \\_first::
        \\00101$:
        \\  ld e, 4 (ix)
        \\  ld -2 (iy), #0x0a
        \\  jr 00101$
        \\_second::
        \\00101$:
        \\  ld a, #<(_data)
        \\  ld a, #>(_data)
        \\  jr 00101$
        \\_data:
    , &.{ 0xDD, 0x5E, 0x04, 0xFD, 0x36, 0xFE, 0x0A, 0x18, 0xF7, 0x3E, 0x0F, 0x3E, 0x00, 0x18, 0xFA });
}

// 1. Range errors wait for the pass in which every value is known.

test "forward references are not range-checked before they have a value" {
    const source =
        \\  LD A,fwd
        \\  JR target
        \\  DS 3
        \\target: NOP
        \\fwd EQU 200
    ;
    try expectBytes(source, &.{ 0x3E, 200, 0x18, 0x03, 0, 0, 0, 0 });
    try std.testing.expectEqual(2, runtime(source).passes);
}

test "an EQU chain defined out of order still resolves" {
    const source = "  LD A,x\nx EQU y+1\ny EQU z*2\nz EQU 3\n";
    try expectBytes(source, &.{ 0x3E, 7 });
    try std.testing.expect(runtime(source).passes >= 3);
}

test "a real range error is still reported" {
    try expectDiagnostic("  JR far\n  DS 200\nfar: NOP\n", "line 1: relative jump out of range (200 bytes)");
    try expectDiagnostic("  LD A,big\nbig EQU 300\n", "line 1: value 300 does not fit in 8 bits");
}

// 2. Phase errors end after a bounded number of passes.

test "labels that never settle are a phase error" {
    const source = "p1: DS 1-(p2-p1)\np2: NOP\n";
    try std.testing.expectEqual(Assembler.max_passes, runtime(source).passes);
    try expectDiagnostic(source, "phase error: label 'p2' did not settle");
}

// 3. Extra passes only when something moved.

test "pass count" {
    try std.testing.expectEqual(1, runtime("start: NOP\n  JP start\n").passes);
    try std.testing.expectEqual(2, runtime("  JP later\nlater: NOP\n").passes);
    // A DS sized by a forward label moves the labels after it once.
    try std.testing.expectEqual(3, runtime("  DS n\nafter: NOP\nn EQU 2\n  DW after\n").passes);
}

// 4. The body runs once per pass (documented on Assembler.run).

fn countingBody(calls: *u32, a: *Assembler) Assembler.Error!void {
    calls.* += 1;
    try a.emit(isa.jp(try a.word("later")));
    try a.label("later");
}

test "the body is executed once per pass" {
    var calls: u32 = 0;
    const r = z80.run(.{}, workspace.buffers(), &calls, countingBody);
    try expectOk(r);
    try std.testing.expectEqual(r.passes, calls);
}

// 5. Overlap and image bounds.

test "writing an address twice is an error" {
    try expectDiagnostic("  ORG 0\n  NOP\n  ORG 0\n  NOP\n", "line 4: overlap at 0x0000: address written twice");
}

test "the image starts at the lowest address written" {
    const source = "  ORG 8000H\n  HALT\n  ORG 7FFEH\n  HALT\n";
    const r = runtime(source);
    try expectOk(r);
    try std.testing.expectEqual(0x7FFE, r.origin);
    try std.testing.expectEqualSlices(u8, &.{ 0x76, 0, 0x76 }, r.bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0x76, 0, 0x76 }, comptime z80.comptimeAssemble(source, .{}));
}

// Zig calls and text go through the same path.

fn zigProgram(_: void, a: *Assembler) Assembler.Error!void {
    a.org(0x100);
    try a.label("loop");
    try a.emit(isa.ldRrNn(.hl, try a.word("msg")));
    try a.emit(isa.ldRIdxD(.a, .ix, try a.displacement("offset")));
    try a.line("  DJNZ loop");
    try a.emit(isa.jr(try a.relative("loop")));
    try a.label("msg");
    try a.bytes("ok");
    try a.equ("offset", try a.eval("msg-loop"));
}

const text_program =
    \\  ORG 100H
    \\loop: LD HL,msg
    \\  LD A,(IX+offset)
    \\  DJNZ loop
    \\  JR loop
    \\msg: DB "ok"
    \\offset EQU msg-loop
;

test "Zig calls and source text give the same bytes" {
    const from_zig = comptime z80.comptimeBuild(.{}, {}, zigProgram);
    const from_text = comptime z80.comptimeAssemble(text_program, .{});
    try std.testing.expectEqualSlices(u8, from_text, from_zig);

    const r = z80.run(.{}, workspace.buffers(), {}, zigProgram);
    try expectOk(r);
    try std.testing.expectEqualSlices(u8, from_text, r.bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0x21, 0x0A, 0x01, 0xDD, 0x7E, 0x0A, 0x10, 0xF8, 0x18, 0xF6, 'o', 'k' }, from_zig);
}

/// `Result.entry` of a comptime assembly.
fn comptimeEntry(comptime source: []const u8) ?u16 {
    return comptime blk: {
        @setEvalBranchQuota(1_000_000);
        var ws: z80.Workspace(0x100, 64, 4) = undefined;
        break :blk z80.assemble(source, .{}, ws.buffers()).entry;
    };
}

test "END gives the entry address, also through a forward reference" {
    const source = "  ORG 8000h\n  JP main\n  NOP\nmain: RET\n  END main\n";
    try std.testing.expectEqual(@as(?u16, 0x8004), runtime(source).entry);
    try std.testing.expectEqual(@as(?u16, 0x8004), comptimeEntry(source));
    try std.testing.expectEqual(@as(?u16, null), runtime("  NOP\n").entry);
}

test "the cpm machine gives a com file at 0x0100" {
    const r = z80.assemble("  NOP\n", .{ .machine = .cpm }, workspace.buffers());
    try expectOk(r);
    try std.testing.expectEqual(0x0100, r.origin);
    try std.testing.expect(r.format == .com);

    const hello = @embedFile("cases/cpm_hello.asm");
    const reference = @embedFile("cases/cpm_hello.bin");
    try std.testing.expectEqualSlices(u8, reference, comptime z80.comptimeAssemble(hello, .{ .machine = .cpm }));
    const h = z80.assemble(hello, .{ .machine = .cpm }, workspace.buffers());
    try expectOk(h);
    var file: [reference.len]u8 = undefined;
    try std.testing.expectEqualSlices(u8, reference, z80.formats.write(h.format, h.image(), &file));
}

test "an explicit origin or format overrides the machine" {
    const r = z80.assemble("  NOP\n", .{ .machine = .cpm, .origin = 0x8000, .format = .bin }, workspace.buffers());
    try expectOk(r);
    try std.testing.expectEqual(0x8000, r.origin);
    try std.testing.expect(r.format == .bin);

    const bad = z80.assemble("  NOP\n", .{ .machine = .cpm, .origin = 0x8000 }, workspace.buffers());
    var buf: [100]u8 = undefined;
    try std.testing.expectEqualStrings("the com format needs origin 0x0100, not 0x8000", try std.fmt.bufPrint(&buf, "{f}", .{bad.diagnostics[0]}));
}

test "SDCC's #< and #> stay the low and high byte where an operand is expected" {
    try expectBytes(
        \\  LD A,#<1234h
        \\  LD A,#>1234h
        \\  LD A,1 < #>1234h
        \\  LD A,#>1234h > 1
        \\
    , &.{ 0x3E, 0x34, 0x3E, 0x12, 0x3E, 0xFF, 0x3E, 0xFF });
}
