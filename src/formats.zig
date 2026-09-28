//! Output formats: the file for a machine, made from the finished memory
//! image. Pure functions, the same at comptime and at runtime; the caller
//! provides the output buffer.

const std = @import("std");

/// CP/M's transient program area, where a .com file is loaded and started.
pub const cpm_tpa = 0x0100;

pub const Format = union(enum) {
    /// The memory image from the lowest to the highest address written.
    bin,
    /// CP/M program: the image, loaded and started at `cpm_tpa`.
    com,
    /// ZX Spectrum tape: a CODE header block and its data block, as SAVE ...
    /// CODE writes them; no BASIC loader.
    tap: Name,
    /// ZX Spectrum 48K snapshot: the registers, then the RAM from `zx_ram`,
    /// with the image in the memory that sjasmplus sets up for SAVESNA.
    sna,
    /// Amstrad CPC binary file: a 128-byte AMSDOS header and the image.
    amsdos: Name,
    /// TRS-80 /CMD: load records and a transfer record.
    cmd,
    /// MSX BLOAD file: a 7-byte header and the image.
    msx,

    pub const Tag = std.meta.Tag(Format);

    /// The format named `tag` (in any case), with `name` for tap and amsdos.
    pub fn named(tag: []const u8, name: []const u8) ?Format {
        inline for (@typeInfo(Tag).@"enum".fields) |f| {
            if (std.ascii.eqlIgnoreCase(f.name, tag)) {
                const payload = @FieldType(Format, f.name);
                return @unionInit(Format, f.name, if (payload == Name) .{ .name = name } else {});
            }
        }
        return null;
    }

    /// The name in the header, for the formats that have one.
    pub fn headerName(f: Format) ?[]const u8 {
        return switch (f) {
            .tap, .amsdos => |n| n.name,
            else => null,
        };
    }
};

/// The name in the header of a tap or amsdos file. Empty: spaces in a tap
/// header, zeros in an AMSDOS one (as sjasmplus writes them).
pub const Name = struct { name: []const u8 = "" };

/// A finished memory image and where it runs.
pub const Image = struct {
    bytes: []const u8,
    /// Address of bytes[0].
    origin: u16,
    /// Where execution starts; null when the source does not say, and then the
    /// formats that store an entry use the origin.
    entry: ?u16 = null,

    fn start(image: Image) u16 {
        return image.entry orelse image.origin;
    }
};

/// The origin the format loads the image at, when it fixes one. The assembler
/// reports an image that starts elsewhere.
pub fn requiredOrigin(format: Format) ?u16 {
    return switch (format) {
        .com => cpm_tpa,
        else => null,
    };
}

/// The lowest address the format holds, when it does not hold the whole
/// address space. The assembler reports an image that starts below it.
pub fn lowestAddress(format: Format) ?u16 {
    return switch (format) {
        .sna => zx_ram,
        else => null,
    };
}

/// The longest image the format holds, for the formats that store its length
/// in 16 bits (a tap data block counts its flag and checksum in it too). The
/// assembler reports a longer one.
pub fn maxLen(format: Format) ?usize {
    return switch (format) {
        .tap => std.math.maxInt(u16) - tap_flag_and_checksum,
        .amsdos => std.math.maxInt(u16),
        .bin, .com, .sna, .cmd, .msx => null,
    };
}

/// Characters of the name in a tap header.
pub const tap_name_len = 10;
const tap_header_len = 17;
/// A tap block is a 16-bit length, then a flag byte, the bytes and a checksum.
const tap_length_len = 2;
const tap_flag_and_checksum = 2;
const tap_block_overhead = tap_length_len + tap_flag_and_checksum;
const tap_header_flag = 0x00;
const tap_data_flag = 0xFF;
const tap_code = 3;
/// The second parameter of a CODE header, as the ROM's SAVE writes it.
const tap_code_param2 = 32768;

/// The ZX Spectrum's RAM, after its 16K ROM.
pub const zx_ram = 0x4000;
const sna_header_len = 27;
const sna_ram_len = 0x10000 - zx_ram;

/// The header of an sna file as sjasmplus 1.24.0 writes it for SAVESNA
/// (SaveSNA_ZX in sjasm/io_snapshots.cpp). `write` sets BC to the start, as
/// the ROM's USR does before it jumps there; HL is STACK_BC (0x2D2B), where
/// USR returns, and IY points at the system variables, as the ROM keeps it.
/// SP is set by `write` too.
const sna_header = [sna_header_len]u8{
    // I   L'    H'    E'    D'    C'    B'    F'    A'    L     H     E     D     C     B
    0x3F, 0x58, 0x27, 0x9B, 0x36, 0x00, 0x00, 0x44, 0x00, 0x2B, 0x2D, 0xDC, 0x5C, 0x00, 0x00,
    // IYL IYH   IXL   IXH   IFF2  R     F     A     SPL   SPH   IM    border
    0x3A, 0x5C, 0x3C, 0xFF, 0x00, 0x00, 0x54, 0x00, 0x00, 0x00, 0x01, 0x07,
};
const sna_bc = 13;
const sna_sp = 23;

// The RAM before the image goes in, as sjasmplus 1.24.0 sets it up for DEVICE
// ZXSPECTRUM48 (initZxLikeDevice and the tables at the end of
// sjasm/devices.cpp): as after CLEAR 0x5D5B and LOAD "" CODE in BASIC.
const zx_attributes = 0x5800;
const zx_attributes_len = 0x300;
/// PAPER 7, INK 0.
const zx_black_on_white = 7 * 8;
const zx_sysvars = 0x5C00;
const zx_err_sp = 0x5C3D;
const zx_ramtop = 0x5CB2;
/// The system variables. sjasmplus then sets RAMTOP to `sna_ramtop` and
/// ERR_SP to `zx_stack`.
const zx_sysvars_data = [256]u8{
    0xff, 0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x14, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x06, 0x00, 0x0b, 0x00, 0x01, 0x00, 0x01, 0x00, 0x06, 0x00, 0x10, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3c, 0x40, 0x00, 0xff, 0xcc, 0x01, 0x54, 0xff, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x38, 0x00, 0x00, 0xcb, 0x5c, 0x00, 0x00, 0xb6,
    0x5c, 0xb6, 0x5c, 0xcb, 0x5c, 0x00, 0x00, 0xca, 0x5c, 0xcc, 0x5c, 0xcc, 0x5c, 0xcc, 0x5c, 0x00,
    0x00, 0xce, 0x5c, 0xce, 0x5c, 0xce, 0x5c, 0x00, 0x92, 0x5c, 0x10, 0x02, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x58, 0xff, 0x00, 0x00, 0x21,
    0x5b, 0x00, 0x21, 0x17, 0x00, 0x40, 0xe0, 0x50, 0x21, 0x18, 0x21, 0x17, 0x01, 0x38, 0x00, 0x38,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x57, 0xff, 0xff, 0xff, 0xf4, 0x09, 0xa8, 0x10, 0x4b, 0xf4, 0x09, 0xc4, 0x15, 0x53,
    0x81, 0x0f, 0xc4, 0x15, 0x52, 0xf4, 0x09, 0xc4, 0x15, 0x50, 0x80, 0x80, 0x0d, 0x80, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};
const sna_ramtop = 0x5D5B;
/// Under RAMTOP: MAIN_4 (0x1303), the error address that ERR_SP points at,
/// and at RAMTOP the end marker of the GO SUB stack.
const zx_stack_data = [4]u8{ 0x03, 0x13, 0x00, 0x3e };
const zx_stack = sna_ramtop + 1 - zx_stack_data.len;
/// The user-defined graphics, the letters A to U.
const zx_udg = 0xFF58;
const zx_udg_data = [168]u8{
    0x00, 0x3c, 0x42, 0x42, 0x7e, 0x42, 0x42, 0x00, 0x00, 0x7c, 0x42, 0x7c, 0x42, 0x42, 0x7c, 0x00,
    0x00, 0x3c, 0x42, 0x40, 0x40, 0x42, 0x3c, 0x00, 0x00, 0x78, 0x44, 0x42, 0x42, 0x44, 0x78, 0x00,
    0x00, 0x7e, 0x40, 0x7c, 0x40, 0x40, 0x7e, 0x00, 0x00, 0x7e, 0x40, 0x7c, 0x40, 0x40, 0x40, 0x00,
    0x00, 0x3c, 0x42, 0x40, 0x4e, 0x42, 0x3c, 0x00, 0x00, 0x42, 0x42, 0x7e, 0x42, 0x42, 0x42, 0x00,
    0x00, 0x3e, 0x08, 0x08, 0x08, 0x08, 0x3e, 0x00, 0x00, 0x02, 0x02, 0x02, 0x42, 0x42, 0x3c, 0x00,
    0x00, 0x44, 0x48, 0x70, 0x48, 0x44, 0x42, 0x00, 0x00, 0x40, 0x40, 0x40, 0x40, 0x40, 0x7e, 0x00,
    0x00, 0x42, 0x66, 0x5a, 0x42, 0x42, 0x42, 0x00, 0x00, 0x42, 0x62, 0x52, 0x4a, 0x46, 0x42, 0x00,
    0x00, 0x3c, 0x42, 0x42, 0x42, 0x42, 0x3c, 0x00, 0x00, 0x7c, 0x42, 0x42, 0x7c, 0x40, 0x40, 0x00,
    0x00, 0x3c, 0x42, 0x42, 0x52, 0x4a, 0x3c, 0x00, 0x00, 0x7c, 0x42, 0x42, 0x7c, 0x44, 0x42, 0x00,
    0x00, 0x3c, 0x40, 0x3c, 0x02, 0x42, 0x3c, 0x00, 0x00, 0xfe, 0x10, 0x10, 0x10, 0x10, 0x10, 0x00,
    0x00, 0x42, 0x42, 0x42, 0x42, 0x42, 0x3c, 0x00,
};

/// Offset in an sna file of the RAM byte at `address`.
fn snaAt(address: u16) usize {
    return sna_header_len + address - zx_ram;
}

/// Characters of the name and of the extension in an AMSDOS header.
pub const amsdos_name_len = 8;
pub const amsdos_ext_len = 3;
const amsdos_header_len = 128;
const amsdos_binary = 2;
/// Offsets in the AMSDOS header: the user number is at 0, and the length is
/// followed by the entry address.
const amsdos_name = 1;
const amsdos_type = 18;
const amsdos_load = 21;
const amsdos_length = 24;
const amsdos_file_length = 64;
const amsdos_checksum = 67;

/// Data bytes in one TRS-80 load record: its length byte counts them and the
/// two address bytes, and 0 means 256.
const cmd_record_data = 254;
const cmd_address_len = 2;
/// A record is a type byte, a length byte and the address, then the data.
const cmd_type_and_length = 2;
const cmd_record_overhead = cmd_type_and_length + cmd_address_len;
const cmd_load = 0x01;
const cmd_transfer = 0x02;
const cmd_transfer_len = cmd_record_overhead;

const msx_header_len = 7;
const msx_id = 0xFE;

/// Whether `name` fits an AMSDOS header: up to 8 characters, optionally a dot
/// and up to 3 more.
pub fn validAmsdosName(name: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse name.len;
    const ext_len = if (dot == name.len) 0 else name.len - dot - 1;
    return dot <= amsdos_name_len and ext_len <= amsdos_ext_len;
}

/// Length of the file for an image of `image_len` bytes.
pub fn fileLen(format: Format, image_len: usize) usize {
    return switch (format) {
        .bin, .com => image_len,
        .tap => tap_block_overhead + tap_header_len + tap_block_overhead + image_len,
        .sna => sna_header_len + sna_ram_len,
        .amsdos => amsdos_header_len + image_len,
        .cmd => (image_len + cmd_record_data - 1) / cmd_record_data * cmd_record_overhead + image_len + cmd_transfer_len,
        .msx => msx_header_len + image_len,
    };
}

/// Writes the file into `out`, which holds at least `fileLen` bytes, and
/// returns it. The image must meet the format's requirements, which the
/// assembler checks (origin, name lengths, `maxLen`).
pub fn write(format: Format, image: Image, out: []u8) []u8 {
    const file = out[0..fileLen(format, image.bytes.len)];
    // A bin, com or cmd image can fill the address space, 1 more than 16 bits;
    // they do not store the length, and the msx end address wraps with it.
    const len: u16 = @truncate(image.bytes.len);
    var o: Out = .{ .bytes = file };
    switch (format) {
        .bin, .com => o.all(image.bytes),
        .tap => |n| {
            o.word(tap_header_len + tap_flag_and_checksum);
            const header = o.at;
            o.byte(tap_header_flag);
            o.byte(tap_code);
            o.all(n.name);
            o.fill(' ', tap_name_len - n.name.len);
            o.word(len);
            o.word(image.origin);
            o.word(tap_code_param2);
            o.byte(xorOf(o.since(header)));
            o.word(len + tap_flag_and_checksum);
            o.byte(tap_data_flag);
            o.all(image.bytes);
            o.byte(tap_data_flag ^ xorOf(image.bytes));
        },
        .sna => {
            o.all(&sna_header);
            o.fill(0, sna_ram_len);
            o.at = snaAt(zx_attributes);
            o.fill(zx_black_on_white, zx_attributes_len);
            o.at = snaAt(zx_sysvars);
            o.all(&zx_sysvars_data);
            o.at = snaAt(zx_err_sp);
            o.word(zx_stack);
            o.at = snaAt(zx_ramtop);
            o.word(sna_ramtop);
            o.at = snaAt(zx_stack);
            o.all(&zx_stack_data);
            o.at = snaAt(zx_udg);
            o.all(&zx_udg_data);
            if (image.bytes.len != 0) {
                o.at = snaAt(image.origin);
                o.all(image.bytes);
            }
            // The start goes under the stack, where the loader's RETN takes it
            // from, if the image left the stack and the two bytes under it as
            // they were; otherwise, as in sjasmplus, at 0x4000, on the screen.
            const under = zx_stack - 2;
            const unchanged = [2]u8{ 0, 0 } ++ zx_stack_data;
            const sp: u16 = if (std.mem.eql(u8, file[snaAt(under)..][0..unchanged.len], &unchanged)) under else zx_ram;
            o.at = snaAt(sp);
            o.word(image.start());
            o.at = sna_bc;
            o.word(image.start());
            o.at = sna_sp;
            o.word(sp);
        },
        .amsdos => |n| {
            o.fill(0, amsdos_header_len);
            if (n.name.len != 0) {
                const dot = std.mem.indexOfScalar(u8, n.name, '.') orelse n.name.len;
                const ext = if (dot == n.name.len) "" else n.name[dot + 1 ..];
                o.at = amsdos_name;
                o.upper(n.name[0..dot]);
                o.fill(' ', amsdos_name_len - dot);
                o.upper(ext);
                o.fill(' ', amsdos_ext_len - ext.len);
            }
            o.at = amsdos_type;
            o.byte(amsdos_binary);
            o.at = amsdos_load;
            o.word(image.origin);
            o.at = amsdos_length;
            o.word(len);
            o.word(image.start());
            o.at = amsdos_file_length;
            o.word(len);
            var sum: u16 = 0;
            for (file[0..amsdos_checksum]) |b| sum +%= b;
            o.at = amsdos_checksum;
            o.word(sum);
            o.at = amsdos_header_len;
            o.all(image.bytes);
        },
        .cmd => {
            var offset: usize = 0;
            while (offset < image.bytes.len) : (offset += cmd_record_data) {
                const chunk = image.bytes[offset..@min(image.bytes.len, offset + cmd_record_data)];
                o.byte(cmd_load);
                o.byte(@truncate(chunk.len + cmd_address_len));
                o.word(image.origin +% @as(u16, @intCast(offset)));
                o.all(chunk);
            }
            o.byte(cmd_transfer);
            o.byte(cmd_address_len);
            o.word(image.start());
        },
        .msx => {
            o.byte(msx_id);
            o.word(image.origin);
            o.word(image.origin +% len -% 1); // the last address, as BSAVE writes it
            o.word(image.start());
            o.all(image.bytes);
        },
    }
    return file;
}

/// Writes a file from its start: bytes, little-endian words and runs.
const Out = struct {
    bytes: []u8,
    at: usize = 0,

    fn byte(o: *Out, b: u8) void {
        o.bytes[o.at] = b;
        o.at += 1;
    }

    fn word(o: *Out, w: u16) void {
        o.byte(@truncate(w));
        o.byte(@truncate(w >> 8));
    }

    fn all(o: *Out, s: []const u8) void {
        @memcpy(o.bytes[o.at..][0..s.len], s);
        o.at += s.len;
    }

    fn upper(o: *Out, s: []const u8) void {
        for (s) |c| o.byte(std.ascii.toUpper(c));
    }

    fn fill(o: *Out, b: u8, n: usize) void {
        @memset(o.bytes[o.at..][0..n], b);
        o.at += n;
    }

    /// What was written from `start` on.
    fn since(o: *const Out, start: usize) []const u8 {
        return o.bytes[start..o.at];
    }
};

fn xorOf(bytes: []const u8) u8 {
    var x: u8 = 0;
    for (bytes) |b| x ^= b;
    return x;
}
