const formats = @import("formats.zig");

/// A machine the program is for: the CPU (the Z80 for all of them so far) and
/// the output format. A format in the options or from FORMAT overrides it.
pub const Machine = enum {
    /// CP/M 2.2: a .com file, loaded and started at 0x0100, which is also the
    /// origin when the source has no ORG.
    cpm,
    /// ZX Spectrum 48K: a tap file with a CODE block.
    zx48,
    /// Amstrad CPC: a binary file with an AMSDOS header.
    cpc,
    /// TRS-80: a /CMD file.
    trs80,
    /// MSX: a BLOAD file.
    msx,

    pub fn format(m: Machine) formats.Format {
        return switch (m) {
            .cpm => .com,
            .zx48 => .{ .tap = .{} },
            .cpc => .{ .amsdos = .{} },
            .trs80 => .cmd,
            .msx => .msx,
        };
    }

    /// The origin when the source has no ORG, for a machine that fixes one.
    pub fn origin(m: Machine) ?u16 {
        return switch (m) {
            .cpm => formats.cpm_tpa,
            else => null,
        };
    }
};
