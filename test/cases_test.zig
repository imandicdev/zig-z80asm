//! Each test/cases/NAME.asm is assembled at comptime and at runtime; both must
//! equal NAME.bin, which sjasmplus produced (compare/gen_refs.py).

const std = @import("std");
const z80 = @import("z80asm");

const names = .{ "numbers", "expressions", "labels", "data", "long_data", "end", "end_entry", "regressions", "cpm_hello", "operators" };

var workspace: z80.Workspace(0x10000, 256, 16) = undefined;

test "assembly matches sjasmplus in both modes" {
    inline for (names) |name| {
        const source = @embedFile("cases/" ++ name ++ ".asm");
        const reference = @embedFile("cases/" ++ name ++ ".bin");

        const r = z80.assemble(source, .{}, workspace.buffers());
        for (r.diagnostics) |d| std.debug.print(name ++ ": {f}\n", .{d});
        try std.testing.expect(r.ok());
        std.testing.expectEqualSlices(u8, reference, r.bytes) catch |err| {
            std.debug.print("runtime output of {s} differs from sjasmplus\n", .{name});
            return err;
        };
        std.testing.expectEqualSlices(u8, reference, comptime z80.comptimeAssemble(source, .{})) catch |err| {
            std.debug.print("comptime output of {s} differs from sjasmplus\n", .{name});
            return err;
        };
    }
}
