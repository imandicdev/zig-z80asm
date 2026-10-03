//! Each test/cases/NAME.asm is assembled at comptime and at runtime; both must
//! equal NAME.bin, which sjasmplus produced (compare/gen_refs.py).

const std = @import("std");
const z80 = @import("z80asm");

const names = .{ "numbers", "expressions", "labels", "data", "long_data", "end", "end_entry", "regressions", "cpm_hello", "operators", "conditionals", "local_labels", "include", "include_dirs", "incbin" };

/// The files that the cases name in INCLUDE and INCBIN.
const files = [_]z80.File{
    .{ .name = "include_part.inc", .data = @embedFile("cases/include_part.inc") },
    .{ .name = "include_nested.inc", .data = @embedFile("cases/include_nested.inc") },
    .{ .name = "include_dirs/left/part.inc", .data = @embedFile("cases/include_dirs/left/part.inc") },
    .{ .name = "include_dirs/left/data.inc", .data = @embedFile("cases/include_dirs/left/data.inc") },
    .{ .name = "include_dirs/right/part.inc", .data = @embedFile("cases/include_dirs/right/part.inc") },
    .{ .name = "include_dirs/right/data.inc", .data = @embedFile("cases/include_dirs/right/data.inc") },
    .{ .name = "incbin_data.dat", .data = @embedFile("cases/incbin_data.dat") },
};

var workspace: z80.Workspace(0x10000, 256, 16) = undefined;

test "assembly matches sjasmplus in both modes" {
    inline for (names) |name| {
        const source = @embedFile("cases/" ++ name ++ ".asm");
        const reference = @embedFile("cases/" ++ name ++ ".bin");

        const r = z80.assemble(source, .{ .files = &files }, workspace.buffers());
        for (r.diagnostics) |d| std.debug.print(name ++ ": {f}\n", .{d});
        try std.testing.expect(r.ok());
        std.testing.expectEqualSlices(u8, reference, r.bytes) catch |err| {
            std.debug.print("runtime output of {s} differs from sjasmplus\n", .{name});
            return err;
        };
        std.testing.expectEqualSlices(u8, reference, comptime z80.comptimeAssemble(source, .{ .files = &files })) catch |err| {
            std.debug.print("comptime output of {s} differs from sjasmplus\n", .{name});
            return err;
        };
    }
}

test "the command-line tool reads each INCLUDE next to the file that names it" {
    try std.testing.expectEqualSlices(u8, @embedFile("cases/include_dirs.bin"), @embedFile("cli_include_dirs"));
}

test "the command-line tool reads an absolute INCLUDE path as it is" {
    try std.testing.expectEqualSlices(u8, &.{1}, @embedFile("cli_absolute"));
}
