//! Z80 assembler for Zig, usable at comptime and at runtime.
//!
//! Runtime:
//!     var ws: z80.Workspace(0x10000, 4096, 32) = undefined;
//!     const result = z80.assemble(source, .{}, ws.buffers());
//!     if (!result.ok()) for (result.diagnostics) |d| std.debug.print("{f}\n", .{d});
//!
//! Comptime:
//!     const rom = z80.comptimeAssemble(@embedFile("rom.asm"), .{});

const std = @import("std");

pub const isa = @import("isa.zig");
pub const Assembler = @import("Assembler.zig");
pub const formats = @import("formats.zig");
pub const Format = formats.Format;
pub const Machine = @import("machine.zig").Machine;

pub const Options = Assembler.Options;
pub const Buffers = Assembler.Buffers;
pub const Result = Assembler.Result;
pub const Diagnostic = Assembler.Diagnostic;
pub const Workspace = Assembler.Workspace;
pub const assemble = Assembler.assemble;
pub const run = Assembler.run;

/// Options of the comptime entry points. At runtime the buffers set the
/// capacity instead.
pub const ComptimeOptions = struct {
    /// Address of the first byte when the source does not start with ORG;
    /// without it, the machine's origin, or 0.
    origin: ?u16 = null,
    /// A preset of the output format and the default origin (see `Machine`).
    machine: ?Machine = null,
    /// The format of the returned file; without it, the machine's, or bin.
    format: ?Format = null,
    /// The symbol table is a hash table of a power of two slots, at most half
    /// full, so the capacity is this rounded up to a power of two.
    max_symbols: usize = 2048,
    max_diagnostics: usize = 16,

    /// The same choices as options of the runtime entry points.
    pub fn assemblerOptions(o: ComptimeOptions) Options {
        return .{ .origin = o.origin, .machine = o.machine, .format = o.format };
    }
};

fn ComptimeWorkspace(comptime options: ComptimeOptions) type {
    const slots = std.math.ceilPowerOfTwoAssert(usize, @max(1, Assembler.slots_per_entry * options.max_symbols));
    return Workspace(0x10000, slots, options.max_diagnostics);
}

/// Assembles source text at compile time into the file of the chosen format
/// (see `ComptimeOptions`). Errors become compile errors.
pub fn comptimeAssemble(comptime source: []const u8, comptime options: ComptimeOptions) []const u8 {
    comptime {
        @setEvalBranchQuota(std.math.maxInt(u32));
        var ws: ComptimeWorkspace(options) = undefined;
        return finish(Assembler.assemble(source, options.assemblerOptions(), ws.buffers()));
    }
}

/// Runs a Zig body (see `Assembler.run`) at compile time. Errors become compile errors.
pub fn comptimeBuild(
    comptime options: ComptimeOptions,
    comptime ctx: anytype,
    comptime body: fn (@TypeOf(ctx), *Assembler) Assembler.Error!void,
) []const u8 {
    comptime {
        @setEvalBranchQuota(std.math.maxInt(u32));
        var ws: ComptimeWorkspace(options) = undefined;
        return finish(Assembler.run(options.assemblerOptions(), ws.buffers(), ctx, body));
    }
}

fn finish(comptime result: Result) []const u8 {
    if (!result.ok()) {
        var message: []const u8 = "";
        for (result.diagnostics) |d| message = message ++ std.fmt.comptimePrint("\n{f}", .{d});
        if (result.diagnostics_dropped > 0) {
            message = message ++ std.fmt.comptimePrint("\n({d} more)", .{result.diagnostics_dropped});
        }
        @compileError("Z80 assembly failed:" ++ message);
    }
    var file: [formats.fileLen(result.format, result.bytes.len)]u8 = undefined;
    _ = formats.write(result.format, result.image(), &file);
    const final = file;
    return &final;
}

test {
    _ = @import("Lexer.zig");
    _ = Assembler;
    _ = formats;
}
