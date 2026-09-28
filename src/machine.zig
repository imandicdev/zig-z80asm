const formats = @import("formats.zig");

/// A machine the program is for: a preset of the output format and of the
/// origin used when the source has no ORG. An explicit format or origin in the
/// options overrides it.
pub const Machine = enum {
    /// CP/M 2.2: a .com file, loaded and started at 0x0100.
    cpm,

    pub fn format(m: Machine) formats.Format {
        return switch (m) {
            .cpm => .com,
        };
    }

    pub fn origin(m: Machine) u16 {
        return switch (m) {
            .cpm => formats.cpm_tpa,
        };
    }
};
