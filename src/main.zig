//! Command-line assembler: the runtime counterpart of comptimeAssemble, for
//! programs too large to assemble at comptime.

const std = @import("std");
const z80 = @import("z80asm");

/// Room for the whole address space, and for many more symbols and diagnostics
/// than the comptime defaults.
const output_size = 0x10000;
const symbol_slots = 16384;
const diagnostic_count = 64;
const max_source_size = 16 << 20;

const usage =
    \\usage: z80asm [--origin ADDR] [--machine NAME] INPUT.asm OUTPUT
    \\
    \\Writes the memory image from the lowest to the highest address written, as
    \\the file the machine runs.
    \\
    \\  --origin ADDR   address of the first byte when the source has no ORG
    \\  --machine cpm   CP/M: a .com file at 0x0100
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var options: z80.Options = .{};
    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        } else if (std.mem.eql(u8, arg, "--origin")) {
            i += 1;
            if (i == args.len) std.process.fatal("--origin needs an address", .{});
            options.origin = std.fmt.parseInt(u16, args[i], 0) catch
                std.process.fatal("invalid origin '{s}'", .{args[i]});
        } else if (std.mem.eql(u8, arg, "--machine")) {
            i += 1;
            if (i == args.len) std.process.fatal("--machine needs a name", .{});
            options.machine = std.meta.stringToEnum(z80.Machine, args[i]) orelse
                std.process.fatal("unknown machine '{s}'\n{s}", .{ args[i], usage });
        } else if (input == null) {
            input = arg;
        } else if (output == null) {
            output = arg;
        } else {
            std.process.fatal("unexpected argument '{s}'\n{s}", .{ arg, usage });
        }
    }
    const input_path = input orelse std.process.fatal("{s}", .{usage});
    const output_path = output orelse std.process.fatal("{s}", .{usage});

    const cwd = std.Io.Dir.cwd();
    const source = cwd.readFileAlloc(init.io, input_path, arena, .limited(max_source_size)) catch |err|
        std.process.fatal("cannot read '{s}': {t}", .{ input_path, err });

    const workspace = try arena.create(z80.Workspace(output_size, symbol_slots, diagnostic_count));
    const result = z80.assemble(source, options, workspace.buffers());
    if (!result.ok()) {
        for (result.diagnostics) |d| {
            if (d.line != 0) {
                std.debug.print("{s}:{d}: error: {s}\n", .{ input_path, d.line, d.message() });
            } else {
                std.debug.print("{s}: error: {s}\n", .{ input_path, d.message() });
            }
        }
        if (result.diagnostics_dropped > 0) std.debug.print("({d} more errors)\n", .{result.diagnostics_dropped});
        std.process.exit(1);
    }

    const file = try arena.alloc(u8, z80.formats.fileLen(result.format, result.bytes.len));
    const data = z80.formats.write(result.format, result.image(), file);
    cwd.writeFile(init.io, .{ .sub_path = output_path, .data = data }) catch |err|
        std.process.fatal("cannot write '{s}': {t}", .{ output_path, err });
}
