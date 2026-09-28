//! Each output format of test/formats/program.asm (and sna of
//! sna_stack.asm), at comptime and at runtime, against the file that sjasmplus
//! or appmake made of it (compare/gen_formats.py).

const std = @import("std");
const z80 = @import("z80asm");

const source = @embedFile("formats/program.asm");
const origin = 0x8000;

var workspace: z80.Workspace(0x10000, 256, 16) = undefined;

/// The file of `format` at comptime and at runtime, which must be the same.
fn files(comptime program: []const u8, comptime format: z80.Format, runtime_file: []u8) ![2][]const u8 {
    const at_comptime = comptime z80.comptimeAssemble(program, .{ .format = format });
    const r = z80.assemble(program, .{ .format = format }, workspace.buffers());
    for (r.diagnostics) |d| std.debug.print("{f}\n", .{d});
    try std.testing.expect(r.ok());
    return .{ at_comptime, z80.formats.write(r.format, r.image(), runtime_file) };
}

fn expectFile(comptime program: []const u8, comptime format: z80.Format, expected: []const u8) !void {
    var buf: [0x10000]u8 = undefined;
    for (try files(program, format, &buf)) |file| try std.testing.expectEqualSlices(u8, expected, file);
}

test "tap is what sjasmplus SAVETAP ..., CODE writes" {
    try expectFile(source, .{ .tap = .{ .name = "program" } }, @embedFile("formats/program.tap"));
}

test "sna is what sjasmplus SAVESNA writes" {
    try expectFile(source, .sna, @embedFile("formats/program.sna"));
}

test "sna of a program over the stack is what sjasmplus SAVESNA writes, with the start at 0x4000" {
    const reference = @embedFile("formats/sna_stack.sna");
    try expectFile(@embedFile("formats/sna_stack.asm"), .sna, reference);
    // SP in the header, and the start at 0x4000, the first RAM byte.
    try std.testing.expectEqual(z80.formats.zx_ram, std.mem.readInt(u16, reference[23..25], .little));
    try std.testing.expectEqual(0x5D50, std.mem.readInt(u16, reference[27..29], .little));
}

test "amsdos without a name is what sjasmplus SAVEAMSDOS writes" {
    try expectFile(source, .{ .amsdos = .{} }, @embedFile("formats/program.amsdos"));
}

test "amsdos with a name is what appmake +cpc writes" {
    try expectFile(source, .{ .amsdos = .{ .name = "am.cpc" } }, @embedFile("formats/program_appmake.amsdos"));
}

test "cmd is what appmake +trs80 --cmd writes" {
    try expectFile(source, .cmd, @embedFile("formats/program.cmd"));
}

test "msx is what appmake +msx writes, apart from the end address" {
    const reference = @embedFile("formats/program.msx");
    const end = 3; // offset of the end address in the header
    var buf: [0x10000]u8 = undefined;
    for (try files(source, .msx, &buf)) |file| {
        try std.testing.expectEqual(reference.len, file.len);
        try std.testing.expectEqualSlices(u8, reference[0..end], file[0..end]);
        try std.testing.expectEqualSlices(u8, reference[end + 2 ..], file[end + 2 ..]);
        // BSAVE in Disk BASIC writes its end argument, the last address, and
        // saves end - start + 1 bytes; BLOAD reads that many back (BSAVE and
        // BLOAD in dskbasic.mac of Nextor, from MSX-DOS 2). appmake (msx.c)
        // writes start + length + 1 in both of its files: in a .cas file it
        // puts two zero bytes after the data, which that address covers, but
        // not in this one.
        const length = file.len - 7;
        try std.testing.expectEqual(origin + length - 1, std.mem.readInt(u16, file[end..][0..2], .little));
        try std.testing.expectEqual(origin + length + 1, std.mem.readInt(u16, reference[end..][0..2], .little));
    }
}

test "bin, cmd and msx hold the whole address space" {
    const full = "  ORG 0\n  DS 10000h, 0AAh\n";
    // 259 cmd load records of 4 bytes each, and a transfer record.
    var buf: [0x10000 + 0x1000]u8 = undefined;
    inline for (.{ z80.Format.bin, z80.Format.cmd, z80.Format.msx }) |format| {
        const r = z80.assemble(full, .{ .format = format }, workspace.buffers());
        try std.testing.expect(r.ok());
        try std.testing.expectEqual(0x10000, r.bytes.len);
        const file = z80.formats.write(r.format, r.image(), &buf);
        try std.testing.expectEqual(z80.formats.fileLen(format, r.bytes.len), file.len);
        if (format == .msx) try std.testing.expectEqual(0xFFFF, std.mem.readInt(u16, file[3..5], .little));
    }
}

test "the entry of END goes into the sna, amsdos, cmd and msx headers" {
    const with_entry = "  ORG 9000h\n  DB 1\nmain: RET\n  END main\n";
    const entry = 0x9001;
    // Offsets of the entry: BC in the sna header, in the AMSDOS header, in the
    // transfer record after the one load record of 2 bytes, and in the BLOAD
    // header.
    var buf: [0x10000]u8 = undefined;
    inline for (.{ .{ z80.Format.sna, 13 }, .{ z80.Format{ .amsdos = .{} }, 26 }, .{ z80.Format.cmd, 8 }, .{ z80.Format.msx, 5 } }) |case| {
        const r = z80.assemble(with_entry, .{ .format = case[0] }, workspace.buffers());
        try std.testing.expect(r.ok());
        const file = z80.formats.write(r.format, r.image(), &buf);
        try std.testing.expectEqual(entry, std.mem.readInt(u16, file[case[1]..][0..2], .little));
    }
}

test "the CLI takes the format from the extension or the machine, and the header name from the output file" {
    try std.testing.expectEqualSlices(u8, @embedFile("formats/program.tap"), @embedFile("cli_tap"));
    try std.testing.expectEqualSlices(u8, @embedFile("formats/program.sna"), @embedFile("cli_sna"));
    try std.testing.expectEqualSlices(u8, @embedFile("formats/program_appmake.amsdos"), @embedFile("cli_amsdos"));
    try std.testing.expectEqualSlices(u8, @embedFile("formats/program.cmd"), @embedFile("cli_cmd"));
}
