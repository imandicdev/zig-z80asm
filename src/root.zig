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
    /// Address of the first byte when the source does not start with ORG.
    origin: u16 = 0,
    /// The symbol table is a hash table of a power of two slots, at most half
    /// full, so the capacity is this rounded up to a power of two.
    max_symbols: usize = 2048,
    max_diagnostics: usize = 16,
};

fn ComptimeWorkspace(comptime options: ComptimeOptions) type {
    const slots = std.math.ceilPowerOfTwoAssert(usize, @max(1, Assembler.slots_per_entry * options.max_symbols));
    return Workspace(0x10000, slots, options.max_diagnostics);
}

/// Assembles source text at compile time. Errors become compile errors.
pub fn comptimeAssemble(comptime source: []const u8, comptime options: ComptimeOptions) []const u8 {
    comptime {
        @setEvalBranchQuota(std.math.maxInt(u32));
        var ws: ComptimeWorkspace(options) = undefined;
        return finish(Assembler.assemble(source, .{ .origin = options.origin }, ws.buffers()));
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
        return finish(Assembler.run(.{ .origin = options.origin }, ws.buffers(), ctx, body));
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
    const image = result.bytes[0..result.bytes.len].*;
    return &image;
}

test {
    _ = @import("Lexer.zig");
    _ = Assembler;
}
