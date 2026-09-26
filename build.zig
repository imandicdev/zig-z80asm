const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const isa_mod = b.createModule(.{
        .root_source_file = b.path("src/z80isa.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests of the existing sources.
    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/z80parse.zig", "src/z80asm_test.zig" }) |path| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        }) });
        test_step.dependOn(&b.addRunArtifact(t).step);
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
