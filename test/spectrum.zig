//! Preparation of the z00m128/zxs-rom source: the INCLUDE of the system
//! variables is replaced by that file's text and the OUTPUT line is dropped,
//! as INCLUDE and OUTPUT are not in z80asm 0.1. Works at comptime and runtime.

const std = @import("std");

pub fn preparedLength(source: []const u8, sysvars: []const u8) usize {
    return source.len + sysvars.len + 16;
}

pub fn prepare(buf: []u8, source: []const u8, sysvars: []const u8) []const u8 {
    var len: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const text = if (std.ascii.startsWithIgnoreCase(trimmed, "include"))
            sysvars
        else if (std.ascii.startsWithIgnoreCase(trimmed, "output"))
            ""
        else
            line;
        @memcpy(buf[len..][0..text.len], text);
        buf[len + text.len] = '\n';
        len += text.len + 1;
    }
    return buf[0..len];
}
