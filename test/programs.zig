//! Known programs assembled with z80asm and compared byte for byte with the
//! original binaries. The sources and binaries are third-party and are not in
//! the repository; see test/programs/README.md for where they come from.
//! Run with: zig build programs -Dthirdparty=DIR [-Dprograms-comptime=true]

const std = @import("std");
const z80 = @import("z80asm");
const options = @import("options");

var workspace: z80.Workspace(0x10000, 4096, 16) = undefined;

fn expectImage(name: []const u8, source: []const u8, expected: []const u8) !void {
    const r = z80.assemble(source, .{}, workspace.buffers());
    for (r.diagnostics) |d| std.debug.print("{s}: {f}\n", .{ name, d });
    try std.testing.expect(r.ok());
    try expectSame(name, "runtime", expected, r.bytes);
}

fn expectSame(name: []const u8, mode: []const u8, expected: []const u8, got: []const u8) !void {
    if (std.mem.eql(u8, expected, got)) return;
    const n = @min(expected.len, got.len);
    const at = for (0..n) |i| {
        if (expected[i] != got[i]) break i;
    } else n;
    std.debug.print("{s} ({s}): {d} bytes, expected {d}; first difference at offset 0x{X:0>4}\n", .{ name, mode, got.len, expected.len, at });
    return error.TestExpectedEqual;
}

// ZX Spectrum 48K ROM: z00m128/zxs-rom as prepared by fetch.py.

const spectrum_source = @embedFile("spectrum_rom_asm");
const spectrum_rom = @embedFile("spectrum_48_rom");

test "ZX Spectrum 48K ROM is identical to the original" {
    try expectImage("48.rom", spectrum_source, spectrum_rom);
}

test "ZX Spectrum 48K ROM at comptime" {
    if (!options.programs_comptime) return error.SkipZigTest;
    try expectSame("48.rom", "comptime", spectrum_rom, comptime z80.comptimeAssemble(spectrum_source, .{}));
}

// SDCC: test/programs/sdcc_sample.c compiled with `sdcc -mz80 -S`, compared
// with sdasz80 + sdldz80 + makebin output cut to the linked range.

const sdcc_source = @embedFile("sdcc_sample_asm");
const sdcc_reference = @embedFile("sdcc_sample_bin");

test "SDCC output matches sdasz80" {
    try expectImage("sdcc_sample", sdcc_source, sdcc_reference);
    try expectSame("sdcc_sample", "comptime", sdcc_reference, comptime z80.comptimeAssemble(sdcc_source, .{}));
}
