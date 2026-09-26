//! Runtime timing of the Spectrum ROM and of a medium slice of it (its first
//! lines), and the slice itself for the comptime benchmark. Labels past the cut
//! become empty labels at the end of the slice: a JR across the cut then still
//! reaches, as the end is closer than its real target.
//!
//! usage: bench LINES MEDIUM.asm

const std = @import("std");
const z80 = @import("z80asm");
const spectrum = @import("spectrum");

const source = @embedFile("spectrum_rom_asm");
const sysvars = @embedFile("spectrum_sysvars_asm");
const rom = @embedFile("spectrum_48_rom");

const runs = 25;

var workspace: z80.Workspace(0x10000, 4096, 4096) = undefined;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) std.process.fatal("usage: bench LINES MEDIUM.asm", .{});
    const lines = try std.fmt.parseInt(usize, args[1], 10);

    const full = spectrum.prepare(try arena.alloc(u8, spectrum.preparedLength(source, sysvars)), source, sysvars);
    const r = z80.assemble(full, .{}, workspace.buffers());
    if (!r.ok() or !std.mem.eql(u8, r.bytes, rom)) std.process.fatal("the ROM does not assemble to 48.rom", .{});

    const medium = try slice(arena, full, lines);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = medium });

    std.debug.print("full ROM   {d:>6} lines  {f}\n", .{ std.mem.count(u8, full, "\n"), time(init.io, full) });
    std.debug.print("medium     {d:>6} lines  {f}\n", .{ std.mem.count(u8, medium, "\n"), time(init.io, medium) });
}

const Timing = struct {
    min_us: u64,
    median_us: u64,
    passes: u8,

    pub fn format(t: Timing, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("min {d}.{d:0>3} ms  median {d}.{d:0>3} ms  ({d} passes)", .{
            t.min_us / 1000,    t.min_us % 1000,
            t.median_us / 1000, t.median_us % 1000,
            t.passes,
        });
    }
};

fn time(io: std.Io, text: []const u8) Timing {
    var samples: [runs]u64 = undefined;
    var passes: u8 = 0;
    for (&samples) |*s| {
        const start = std.Io.Timestamp.now(io, .awake);
        const r = z80.assemble(text, .{}, workspace.buffers());
        s.* = @intCast(start.untilNow(io, .awake).toMicroseconds());
        passes = r.passes;
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    return .{ .min_us = samples[0], .median_us = samples[runs / 2], .passes = passes };
}

/// The first `lines` lines, plus an empty label for every symbol they use but
/// do not define. The names come from the "undefined symbol" diagnostics, which
/// is enough for this ROM; a cut where a missing label is used as an 8-bit
/// value or a displacement would need a real value and is reported as fatal.
fn slice(arena: std.mem.Allocator, full: []const u8, lines: usize) ![]const u8 {
    var end: usize = 0;
    for (0..lines) |_| {
        end = (std.mem.indexOfScalarPos(u8, full, end, '\n') orelse break) + 1;
    }
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, full[0..end]);

    const r = z80.assemble(full[0..end], .{}, workspace.buffers());
    if (r.diagnostics_dropped > 0) std.process.fatal("more than {d} diagnostics", .{workspace.diagnostics.len});
    var added: std.ArrayList([]const u8) = .empty;
    next: for (r.diagnostics) |d| {
        const prefix = "undefined symbol '";
        const m = d.message();
        if (!std.mem.startsWith(u8, m, prefix)) std.process.fatal("slice: {f}", .{d});
        const name = try arena.dupe(u8, m[prefix.len .. m.len - 1]);
        for (added.items) |seen| if (std.mem.eql(u8, seen, name)) continue :next;
        try added.append(arena, name);
        try out.print(arena, "{s}:\n", .{name});
    }
    const check = z80.assemble(out.items, .{}, workspace.buffers());
    for (check.diagnostics) |d| std.debug.print("medium: {f}\n", .{d});
    if (!check.ok()) std.process.fatal("the medium slice does not assemble", .{});
    return out.items;
}
