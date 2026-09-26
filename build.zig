const std = @import("std");
const reject_cases = @import("test/reject_cases.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const isa_mod = b.createModule(.{
        .root_source_file = b.path("src/z80isa.zig"),
        .target = target,
        .optimize = optimize,
    });
    const parse_mod = b.createModule(.{
        .root_source_file = b.path("src/z80parse.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests of the existing sources.
    const test_step = b.step("test", "Run unit tests and parser rejection tests");
    for ([_][]const u8{ "src/z80parse.zig", "src/z80asm_test.zig" }) |path| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        }) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Inputs the parser must reject: each must fail to compile with the expected message.
    const wf = b.addWriteFiles();
    for (reject_cases.cases) |case| {
        const src = b.fmt(
            "const p = @import(\"z80parse\");\ncomptime {{\n    _ = p.assemble(\"{s}\", 0x0100, 16);\n}}\n",
            .{escapeZigString(b, case.source)},
        );
        const mod = b.createModule(.{
            .root_source_file = wf.add(b.fmt("reject_{s}.zig", .{case.name}), src),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("z80parse", parse_mod);
        const obj = b.addObject(.{ .name = b.fmt("reject_{s}", .{case.name}), .root_module = mod });
        obj.expect_errors = .{ .contains = case.expect };
        test_step.dependOn(&obj.step);
    }

    // Encoder vs sjasmplus. Run `python compare/gen_isa.py` first.
    const isa_cmp_mod = b.createModule(.{
        .root_source_file = b.path("compare/isa_cases.zig"),
        .target = target,
        .optimize = optimize,
    });
    isa_cmp_mod.addImport("z80isa", isa_mod);
    const isa_cmp = b.addTest(.{ .root_module = isa_cmp_mod });
    const cmp_step = b.step("compare-isa", "Compare z80isa encoders against sjasmplus (run compare/gen_isa.py first)");
    cmp_step.dependOn(&b.addRunArtifact(isa_cmp).step);
}

/// Escape assembly text for use inside a Zig string literal.
fn escapeZigString(b: *std.Build, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '\n' => out.appendSlice(b.allocator, "\\n") catch @panic("OOM"),
            '"' => out.appendSlice(b.allocator, "\\\"") catch @panic("OOM"),
            '\\' => out.appendSlice(b.allocator, "\\\\") catch @panic("OOM"),
            else => out.append(b.allocator, c) catch @panic("OOM"),
        }
    }
    return out.items;
}
