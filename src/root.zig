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

/// Capacity used by the comptime entry points.
const ComptimeWorkspace = Workspace(0x10000, 4096, 16);

/// Assembles source text at compile time. Errors become compile errors.
pub fn comptimeAssemble(comptime source: []const u8, comptime options: Options) []const u8 {
    comptime {
        @setEvalBranchQuota(std.math.maxInt(u32));
        var ws: ComptimeWorkspace = undefined;
        return finish(Assembler.assemble(source, options, ws.buffers()));
    }
}

/// Runs a Zig body (see `Assembler.run`) at compile time. Errors become compile errors.
pub fn comptimeBuild(
    comptime options: Options,
    comptime ctx: anytype,
    comptime body: fn (@TypeOf(ctx), *Assembler) Assembler.Error!void,
) []const u8 {
    comptime {
        @setEvalBranchQuota(std.math.maxInt(u32));
        var ws: ComptimeWorkspace = undefined;
        return finish(Assembler.run(options, ws.buffers(), ctx, body));
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
