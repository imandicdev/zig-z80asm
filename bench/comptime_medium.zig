//! Comptime benchmark: assembles the medium slice written by bench.zig at
//! comptime. build.zig passes a nonce so every run compiles from scratch; the
//! compile step's time and MaxRSS in `--summary all` are the measurement.

const std = @import("std");
const z80 = @import("z80asm");
const options = @import("options");

const source = @embedFile("rom_medium_asm");

var workspace: z80.Workspace(0x10000, 4096, 16) = undefined;

test "comptime and runtime give the same image" {
    std.mem.doNotOptimizeAway(options.nonce);
    const at_comptime = comptime z80.comptimeAssemble(source, .{});
    const r = z80.assemble(source, .{}, workspace.buffers());
    try std.testing.expect(r.ok());
    try std.testing.expectEqualSlices(u8, r.bytes, at_comptime);
}
