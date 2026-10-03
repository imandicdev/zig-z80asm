//! Command-line assembler: the runtime counterpart of comptimeAssemble, for
//! programs too large to assemble at comptime. The assembler does no I/O, so
//! this tool reads the files that INCLUDE and INCBIN name and assembles again.

const std = @import("std");
const z80 = @import("z80asm");

/// Room for the whole address space, and for many more symbols and diagnostics
/// than the comptime defaults.
const output_size = 0x10000;
const symbol_slots = 16384;
const diagnostic_count = 64;
const max_source_size = 16 << 20;

const usage =
    \\usage: z80asm [--origin ADDR] [--machine NAME] [--format NAME] [-I DIR]... INPUT.asm [OUTPUT]
    \\
    \\Writes the memory image from the lowest to the highest address written, as
    \\the file the machine loads. Without OUTPUT, writes to the file that OUTPUT
    \\in the source names, next to INPUT.asm.
    \\
    \\  --origin ADDR   address of the first byte when the source has no ORG
    \\  --machine NAME  cpm (com at 0x0100), zx48 (tap), cpc (amsdos),
    \\                  trs80 (cmd) or msx (msx)
    \\  --format NAME   bin, com, tap, sna, amsdos, cmd or msx
    \\  -I DIR          where to look for INCLUDE and INCBIN files after the
    \\                  directory of the file that names them
    \\
    \\The format is the first of: --format, FORMAT in the source, the machine's,
    \\the output file's extension (.bin, .com, .tap, .sna or .cmd), and bin. A
    \\tap or AMSDOS header without a name takes the output file's name.
    \\
;

/// The files read for INCLUDE and INCBIN: the table the assembler searches, and
/// the path each one was read from.
const Files = struct {
    table: std.ArrayList(z80.File) = .empty,
    paths: std.ArrayList([]const u8) = .empty,

    /// The path of the file with the table name `name`; `input_path` for the
    /// main source, whose name is empty.
    fn pathOf(f: *const Files, name: []const u8, input_path: []const u8) []const u8 {
        if (name.len == 0) return input_path;
        for (f.table.items, f.paths.items) |file, path| {
            if (std.mem.eql(u8, file.name, name)) return path;
        }
        return name;
    }

    fn has(f: *const Files, name: []const u8) bool {
        for (f.table.items) |file| if (std.mem.eql(u8, file.name, name)) return true;
        return false;
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var options: z80.Options = .{};
    var include_dirs: std.ArrayList([]const u8) = .empty;
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
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i == args.len) std.process.fatal("--format needs a name", .{});
            options.format = z80.Format.named(args[i], "") orelse
                std.process.fatal("unknown format '{s}'\n{s}", .{ args[i], usage });
        } else if (std.mem.eql(u8, arg, "-I")) {
            i += 1;
            if (i == args.len) std.process.fatal("-I needs a directory", .{});
            try include_dirs.append(arena, args[i]);
        } else if (input == null) {
            input = arg;
        } else if (output == null) {
            output = arg;
        } else {
            std.process.fatal("unexpected argument '{s}'\n{s}", .{ arg, usage });
        }
    }
    const input_path = input orelse std.process.fatal("{s}", .{usage});
    if (output) |path| options.fallback_format = formatOfExtension(path);

    const cwd = std.Io.Dir.cwd();
    const source = cwd.readFileAlloc(init.io, input_path, arena, .limited(max_source_size)) catch |err|
        std.process.fatal("cannot read '{s}': {t}", .{ input_path, err });

    const workspace = try arena.create(z80.Workspace(output_size, symbol_slots, diagnostic_count));
    var files: Files = .{};
    var result = z80.assemble(source, options, workspace.buffers());
    // Each round reads what the last one reported missing; an included file can
    // name further files, one level more each round. The extension of the file
    // that OUTPUT names is known after the first round, and can change the
    // format.
    var not_found: ?z80.Missing = null;
    var round: usize = 0;
    while (round < z80.Assembler.max_include_depth) : (round += 1) {
        const named = if (output == null) if (result.output_name) |name| formatOfExtension(name) else null else null;
        const new_format = options.fallback_format == null and named != null;
        if (result.missing.len == 0 and !new_format) break;
        if (new_format) options.fallback_format = named;
        for (result.missing) |m| {
            const table_name = if (m.dir.len == 0) m.name else try std.fmt.allocPrint(arena, "{s}/{s}", .{ m.dir, m.name });
            if (files.has(table_name)) continue;
            const from = files.pathOf(m.from, input_path);
            const found = try readNear(init.io, arena, from, m.name, include_dirs.items) orelse {
                not_found = m;
                break;
            };
            try files.table.append(arena, .{ .name = table_name, .data = found.data });
            try files.paths.append(arena, found.path);
        }
        if (not_found != null) break;
        options.files = files.table.items;
        result = z80.assemble(source, options, workspace.buffers());
    }

    if (not_found) |m| {
        // The other diagnostics follow from the missing file.
        std.debug.print("{s}:{d}: error: '{s}' is neither next to it nor in an -I directory\n", .{ files.pathOf(m.from, input_path), m.line, m.name });
        std.process.exit(1);
    }
    if (!result.ok()) {
        for (result.diagnostics) |d| {
            const path = files.pathOf(d.file, input_path);
            if (d.line != 0) {
                std.debug.print("{s}:{d}: error: {s}\n", .{ path, d.line, d.message() });
            } else {
                std.debug.print("{s}: error: {s}\n", .{ path, d.message() });
            }
        }
        if (result.diagnostics_dropped > 0) std.debug.print("({d} more errors)\n", .{result.diagnostics_dropped});
        std.process.exit(1);
    }

    const output_path = output orelse if (result.output_name) |name|
        try near(arena, input_path, name)
    else
        std.process.fatal("no output file: give one after {s}, or name one with OUTPUT in the source", .{input_path});

    const format = try withName(arena, result.format, output_path);
    const file = try arena.alloc(u8, z80.formats.fileLen(format, result.bytes.len));
    const data = z80.formats.write(format, result.image(), file);
    cwd.writeFile(init.io, .{ .sub_path = output_path, .data = data }) catch |err|
        std.process.fatal("cannot write '{s}': {t}", .{ output_path, err });
}

/// The format that the extension of `path` names. AMSDOS and BLOAD files have
/// no extension of their own.
fn formatOfExtension(path: []const u8) ?z80.Format {
    const extension = std.fs.path.extension(path);
    if (extension.len == 0) return null;
    const format = z80.Format.named(extension[1..], "") orelse return null;
    return switch (format) {
        .bin, .com, .tap, .sna, .cmd => format,
        .amsdos, .msx => null,
    };
}

/// `format`, with the name of `path` in a header that has an empty one, cut to
/// fit the header.
fn withName(arena: std.mem.Allocator, format: z80.Format, path: []const u8) !z80.Format {
    const base = std.fs.path.basename(path);
    var named = format;
    switch (named) {
        .tap => |*n| if (n.name.len == 0) {
            const stem = std.fs.path.stem(base);
            n.name = stem[0..@min(stem.len, z80.formats.tap_name_len)];
        },
        .amsdos => |*n| if (n.name.len == 0) {
            const dot = std.mem.indexOfScalar(u8, base, '.') orelse base.len;
            const name = base[0..@min(dot, z80.formats.amsdos_name_len)];
            const extension = std.fs.path.extension(base);
            n.name = if (extension.len > 1)
                try std.fmt.allocPrint(arena, "{s}.{s}", .{ name, extension[1..@min(extension.len, 1 + z80.formats.amsdos_ext_len)] })
            else
                name;
        },
        else => {},
    }
    return named;
}

/// `name` with a backslash read as a slash, which works as a separator
/// everywhere.
fn slashes(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    const copy = try arena.dupe(u8, name);
    std.mem.replaceScalar(u8, copy, '\\', '/');
    return copy;
}

/// `name` in the directory of the file `from`, or `name` itself when it is
/// absolute.
fn near(arena: std.mem.Allocator, from: []const u8, name: []const u8) ![]const u8 {
    const path = try slashes(arena, name);
    if (std.fs.path.isAbsolute(path)) return path;
    const dir = std.fs.path.dirname(from) orelse return path;
    return std.fs.path.join(arena, &.{ dir, path });
}

const Found = struct { path: []const u8, data: []const u8 };

/// Reads the file `name` that the file `from` names: next to `from`, then in
/// each of `dirs`. Null when it is in none of them.
fn readNear(io: std.Io, arena: std.mem.Allocator, from: []const u8, name: []const u8, dirs: []const []const u8) !?Found {
    if (try readIfThere(io, arena, try near(arena, from, name))) |found| return found;
    const relative = try slashes(arena, name);
    if (std.fs.path.isAbsolute(relative)) return null;
    for (dirs) |dir| {
        if (try readIfThere(io, arena, try std.fs.path.join(arena, &.{ dir, relative }))) |found| return found;
    }
    return null;
}

fn readIfThere(io: std.Io, arena: std.mem.Allocator, path: []const u8) !?Found {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_source_size)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => std.process.fatal("cannot read '{s}': {t}", .{ path, err }),
    };
    return .{ .path = path, .data = data };
}
