const std = @import("std");
const z80 = @import("z80asm");
const cases = @import("reject_cases.zig").cases;

var workspace: z80.Workspace(0x10000, 256, 8) = undefined;

test "runtime reports the same message as the comptime compile error" {
    const gpa = std.testing.allocator;
    var failures: usize = 0;
    for (cases) |case| {
        // The options are Zig source for comptimeAssemble, which is also ZON.
        const text = try gpa.dupeZ(u8, case.options);
        defer gpa.free(text);
        const options = try std.zon.parse.fromSliceAlloc(z80.ComptimeOptions, gpa, text, null, .{});
        defer std.zon.parse.free(gpa, options);
        const r = z80.assemble(case.source, options.assemblerOptions(), workspace.buffers());
        var buf: [200]u8 = undefined;
        const got = if (r.diagnostics.len > 0) try std.fmt.bufPrint(&buf, "{f}", .{r.diagnostics[0]}) else "(no error)";
        if (std.mem.eql(u8, got, case.expect)) continue;
        failures += 1;
        std.debug.print("{s}: expected \"{s}\", got \"{s}\"\n", .{ case.name, case.expect, got });
    }
    try std.testing.expectEqual(0, failures);
}
