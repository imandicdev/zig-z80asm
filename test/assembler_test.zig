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
