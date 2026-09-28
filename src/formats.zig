//! Output formats: the file for a machine, made from the finished memory
//! image. Pure functions, the same at comptime and at runtime; the caller
//! provides the output buffer.

/// CP/M's transient program area, where a .com file is loaded and started.
pub const cpm_tpa = 0x0100;

pub const Format = union(enum) {
    /// The memory image from the lowest to the highest address written.
    bin,
    /// CP/M program: the image, loaded and started at `cpm_tpa`.
    com,
};

/// A finished memory image and where it runs.
pub const Image = struct {
    bytes: []const u8,
    /// Address of bytes[0].
    origin: u16,
    /// Where execution starts; null when the source does not say.
    entry: ?u16 = null,
};

/// The origin the format loads the image at, when it fixes one. The assembler
/// reports an image that starts elsewhere.
pub fn requiredOrigin(format: Format) ?u16 {
    return switch (format) {
        .bin => null,
        .com => cpm_tpa,
    };
}

/// Length of the file for an image of `image_len` bytes.
pub fn fileLen(format: Format, image_len: usize) usize {
    return switch (format) {
        .bin, .com => image_len,
    };
}

/// Writes the file into `out`, which holds at least `fileLen` bytes, and
/// returns it. The image must meet the format's requirements (see
/// `requiredOrigin`).
pub fn write(format: Format, image: Image, out: []u8) []u8 {
    switch (format) {
        .bin, .com => {
            @memcpy(out[0..image.bytes.len], image.bytes);
            return out[0..image.bytes.len];
        },
    }
}
