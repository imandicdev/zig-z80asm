const std = @import("std");
const reject_cases = @import("test/reject_cases.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("z80asm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "z80asm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "z80asm", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);

    const assembler_tests = b.createModule(.{
        .root_source_file = b.path("test/assembler_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    assembler_tests.addImport("z80asm", mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = assembler_tests })).step);

    const cases_tests = b.createModule(.{
        .root_source_file = b.path("test/cases_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    cases_tests.addImport("z80asm", mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = cases_tests })).step);

    // Every reject case must fail to compile with its message; the runtime side
    // of the same cases is checked in test/reject_test.zig.
    const wf = b.addWriteFiles();
    for (reject_cases.cases) |case| {
        const src = b.fmt(
            \\const z80 = @import("z80asm");
            \\comptime {{
            \\    _ = z80.comptimeAssemble("{f}", .{{}});
            \\}}
            \\
        , .{std.zig.fmtString(case.source)});
        const case_mod = b.createModule(.{
            .root_source_file = wf.add(b.fmt("reject_{s}.zig", .{case.name}), src),
            .target = target,
            .optimize = optimize,
        });
        case_mod.addImport("z80asm", mod);
        const obj = b.addObject(.{ .name = b.fmt("reject_{s}", .{case.name}), .root_module = case_mod });
        obj.expect_errors = .{ .contains = case.expect };
        test_step.dependOn(&obj.step);
    }

    const reject_runtime = b.createModule(.{
        .root_source_file = b.path("test/reject_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    reject_runtime.addImport("z80asm", mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = reject_runtime })).step);

    // isa.zig against sjasmplus. Run `python compare/gen_isa.py` first.
    const isa_mod = b.createModule(.{
        .root_source_file = b.path("src/isa.zig"),
        .target = target,
        .optimize = optimize,
    });
    const isa_cmp = b.createModule(.{
        .root_source_file = b.path("compare/isa_cases.zig"),
        .target = target,
        .optimize = optimize,
    });
    isa_cmp.addImport("isa", isa_mod);
    const parse_cmp = b.createModule(.{
        .root_source_file = b.path("compare/parse_cases.zig"),
        .target = target,
        .optimize = optimize,
    });
    parse_cmp.addImport("z80asm", mod);
    const cmp_step = b.step("compare", "Compare isa.zig and the assembler against sjasmplus (run compare/gen_isa.py first)");
    cmp_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = isa_cmp })).step);
    cmp_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = parse_cmp })).step);
}
