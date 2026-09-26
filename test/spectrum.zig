//! Preparation of the z00m128/zxs-rom source: the INCLUDE of the system
//! variables is replaced by that file's text and the OUTPUT line is dropped,
//! as INCLUDE and OUTPUT are not in z80asm 0.1. Works at comptime and runtime.

const std = @import("std");

/// Whether `line` is `directive operand`, with any spaces or tabs around them.
fn isLine(line: []const u8, directive: []const u8, operand: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t\r");
    if (!std.ascii.startsWithIgnoreCase(t, directive)) return false;
    const rest = t[directive.len..];
    if (rest.len == 0 or (rest[0] != ' ' and rest[0] != '\t')) return false;
    return std.mem.eql(u8, std.mem.trim(u8, rest, " \t"), operand);
}

fn isInclude(line: []const u8) bool {
    return isLine(line, "include", "\"zx-spectrum-sysvars.asm\"");
}

fn isOutput(line: []const u8) bool {
    return isLine(line, "output", "\"48.ROM\"");
}

pub fn preparedLength(source: []const u8, sysvars: []const u8) usize {
    @setEvalBranchQuota(10_000_000); // used for an array length at comptime
    var includes: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (isInclude(line)) includes += 1;
    }
    return source.len + includes * sysvars.len + 1;
}

pub fn prepare(buf: []u8, source: []const u8, sysvars: []const u8) []const u8 {
    var len: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const text = if (isInclude(line)) sysvars else if (isOutput(line)) "" else line;
        @memcpy(buf[len..][0..text.len], text);
        buf[len + text.len] = '\n';
        len += text.len + 1;
    }
    return buf[0..len];
}
