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

    // Every reject case must fail to compile with its message; test/reject_test.zig
    // checks `cases` at runtime.
    const wf = b.addWriteFiles();
    for (reject_cases.cases ++ reject_cases.comptime_only) |case| {
        const src = b.fmt(
            \\const z80 = @import("z80asm");
            \\comptime {{
            \\    _ = z80.comptimeAssemble("{f}", {s});
            \\}}
            \\
        , .{ std.zig.fmtString(case.source), case.options });
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

    // The same for a Zig body that emits code after END.
    const after_end = b.createModule(.{
        .root_source_file = wf.add("reject_code_after_end.zig",
            \\const z80 = @import("z80asm");
            \\comptime {
            \\    _ = z80.comptimeBuild(.{}, {}, @import("assembler_test").codeAfterEnd);
            \\}
            \\
        ),
        .target = target,
        .optimize = optimize,
    });
    after_end.addImport("z80asm", mod);
    after_end.addImport("assembler_test", assembler_tests);
    const after_end_obj = b.addObject(.{ .name = "reject_code_after_end", .root_module = after_end });
    after_end_obj.expect_errors = .{ .contains = "code after END" };
    test_step.dependOn(&after_end_obj.step);

    const reject_runtime = b.createModule(.{
        .root_source_file = b.path("test/reject_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    reject_runtime.addImport("z80asm", mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = reject_runtime })).step);

    // Known third-party programs, kept outside the repository.
    if (b.option([]const u8, "thirdparty", "Directory with the third-party programs (test/programs/README.md)")) |dir| {
        const programs_comptime = b.option(bool, "programs-comptime", "Also assemble the large programs at comptime (slow)") orelse false;
        const build_options = b.addOptions();
        build_options.addOption(bool, "programs_comptime", programs_comptime);
        const programs = b.createModule(.{
            .root_source_file = b.path("test/programs.zig"),
            .target = target,
            .optimize = optimize,
        });
        programs.addImport("z80asm", mod);
        programs.addOptions("options", build_options);
        embedThirdParty(b, programs, dir, &.{ "spectrum_rom_asm", "spectrum_48_rom", "sdcc_sample_asm", "sdcc_sample_bin" });
        const programs_step = b.step("programs", "Compare known programs with their original binaries");
        programs_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = programs })).step);

        // Performance measurement on the Spectrum ROM (see test/programs/README.md).
        const bench = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = optimize,
        });
        bench.addImport("z80asm", mod);
        embedThirdParty(b, bench, dir, &.{ "spectrum_rom_asm", "spectrum_48_rom" });
        const bench_run = b.addRunArtifact(b.addExecutable(.{ .name = "bench", .root_module = bench }));
        bench_run.addArg(b.fmt("{d}", .{b.option(usize, "bench-lines", "Lines in the medium slice") orelse 2500}));
        const medium = bench_run.addOutputFileArg("rom-medium.asm");
        bench_run.has_side_effects = true; // print the timings on every run
        b.step("bench", "Time the Spectrum ROM and a medium slice of it at runtime").dependOn(&bench_run.step);

        const nonce_options = b.addOptions();
        nonce_options.addOption(u64, "nonce", b.option(u64, "nonce", "Forces the comptime benchmark to recompile") orelse 0);
        const bench_comptime = b.createModule(.{
            .root_source_file = b.path("bench/comptime_medium.zig"),
            .target = target,
            .optimize = optimize,
        });
        bench_comptime.addImport("z80asm", mod);
        bench_comptime.addOptions("options", nonce_options);
        bench_comptime.addAnonymousImport("rom_medium_asm", .{ .root_source_file = medium });
        b.step("bench-comptime", "Assemble the medium slice at comptime")
            .dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = bench_comptime })).step);
    }

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

/// Files that test/programs/fetch.py puts in the -Dthirdparty directory.
const third_party_files = [_]struct { name: []const u8, path: []const u8 }{
    .{ .name = "spectrum_rom_asm", .path = "spectrum-rom/zx-spectrum-rom.prepared.asm" },
    .{ .name = "spectrum_48_rom", .path = "spectrum-rom/48.rom" },
    .{ .name = "sdcc_sample_asm", .path = "sdcc/sdcc_sample.asm" },
    .{ .name = "sdcc_sample_bin", .path = "sdcc/sdcc_sample.sdas.bin" },
};

/// Makes the named third-party files available to @embedFile under their names.
fn embedThirdParty(b: *std.Build, m: *std.Build.Module, dir: []const u8, names: []const []const u8) void {
    for (names) |name| {
        const file = for (third_party_files) |f| {
            if (std.mem.eql(u8, f.name, name)) break f;
        } else std.debug.panic("unknown third-party file '{s}'", .{name});
        m.addAnonymousImport(name, .{ .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ dir, file.path }) } });
    }
}
