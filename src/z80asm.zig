// z80asm.zig — Z80 assembler API (comptime)
//
// Two-pass assembler: pass 1 collects label addresses, pass 2 resolves them.
// Sections: _HEADER (0x0000), _CODE (0x0100), _COMMON (0xC000)
// Output: flat binary []const u8
//
// (c) 2026 Ilija Mandic

const isa = @import("z80isa.zig");
const std = @import("std");

pub const Encoding = isa.Encoding;
pub const R8 = isa.R8;
pub const R16 = isa.R16;
pub const R16af = isa.R16af;
pub const Idx = isa.Idx;
pub const Cc = isa.Cc;

// Maximum number of instructions in a program
const MAX_INSNS = 16384;
// Maximum number of labels
const MAX_LABELS = 4096;
// Maximum binary output size
const MAX_BIN = 65536;

// Label entry type (named to avoid anonymous struct mismatch)
const LabelEntry = struct { name: []const u8, addr: u16 };

// ============================================================================
// Instruction types — either raw bytes or a label reference needing resolution
// ============================================================================

pub const Insn = union(enum) {
    // Raw encoded instruction (no label references)
    raw: Encoding,
    // 3-byte instruction with label reference (JP nn, CALL nn)
    label_abs16: struct {
        opcode: u8, // first byte (0xC3 for JP, 0xCD for CALL, etc.)
        label: []const u8,
    },
    // 2-byte relative jump with label reference (JR, DJNZ)
    label_rel8: struct {
        opcode: u8, // 0x18 for JR, 0x10 for DJNZ, etc.
        label: []const u8,
    },
    // Data bytes
    data: []const u8,
    // Org directive — set current address
    org: u16,
    // Label definition
    label: []const u8,
    // Align to boundary
    align_to: u16,
    // Fill with value to reach target size
    fill: struct { target_addr: u16, value: u8 },
};

// ============================================================================
// Program builder
// ============================================================================

pub const Program = struct {
    insns: [MAX_INSNS]Insn = undefined,
    count: usize = 0,

    pub fn emit(self: *Program, insn: Insn) void {
        self.insns[self.count] = insn;
        self.count += 1;
    }

    // Convenience: emit a raw encoding
    pub fn raw(self: *Program, enc: Encoding) void {
        self.emit(.{ .raw = enc });
    }

    // Define a label at the current position
    pub fn label(self: *Program, name: []const u8) void {
        self.emit(.{ .label = name });
    }

    // Set origin address
    pub fn org(self: *Program, addr: u16) void {
        self.emit(.{ .org = addr });
    }

    // Emit data bytes
    pub fn data(self: *Program, bytes: []const u8) void {
        self.emit(.{ .data = bytes });
    }

    // JP to label
    pub fn jp_label(self: *Program, name: []const u8) void {
        self.emit(.{ .label_abs16 = .{ .opcode = 0xC3, .label = name } });
    }

    // JP cc to label
    pub fn jp_cc_label(self: *Program, cc: Cc, name: []const u8) void {
        self.emit(.{ .label_abs16 = .{ .opcode = 0xC2 | (@as(u8, @intFromEnum(cc)) << 3), .label = name } });
    }

    // CALL label
    pub fn call_label(self: *Program, name: []const u8) void {
        self.emit(.{ .label_abs16 = .{ .opcode = 0xCD, .label = name } });
    }

    // CALL cc, label
    pub fn call_cc_label(self: *Program, cc: Cc, name: []const u8) void {
        self.emit(.{ .label_abs16 = .{ .opcode = 0xC4 | (@as(u8, @intFromEnum(cc)) << 3), .label = name } });
    }

    // JR to label
    pub fn jr_label(self: *Program, name: []const u8) void {
        self.emit(.{ .label_rel8 = .{ .opcode = 0x18, .label = name } });
    }

    // JR cc to label
    pub fn jr_cc_label(self: *Program, cc: Cc, name: []const u8) void {
        const op: u8 = switch (cc) {
            .nz => 0x20, .z => 0x28, .nc => 0x30, .cy => 0x38,
            else => @compileError("JR only supports NZ, Z, NC, C"),
        };
        self.emit(.{ .label_rel8 = .{ .opcode = op, .label = name } });
    }

    // DJNZ to label
    pub fn djnz_label(self: *Program, name: []const u8) void {
        self.emit(.{ .label_rel8 = .{ .opcode = 0x10, .label = name } });
    }

    // LD rr, label (16-bit immediate = label address)
    pub fn ld_rr_label(self: *Program, dst: R16, name: []const u8) void {
        self.emit(.{ .label_abs16 = .{ .opcode = 0x01 | (@as(u8, @intFromEnum(dst)) << 4), .label = name } });
    }

    // LD HL, label
    pub fn ld_hl_label(self: *Program, name: []const u8) void {
        self.ld_rr_label(.hl, name);
    }

    // Fill to reach a target address
    pub fn fill_to(self: *Program, target_addr: u16, value: u8) void {
        self.emit(.{ .fill = .{ .target_addr = target_addr, .value = value } });
    }

    // Emit a string as data bytes
    pub fn string(self: *Program, s: []const u8) void {
        self.data(s);
    }

    // Emit a null-terminated string
    pub fn stringz(self: *Program, s: []const u8) void {
        self.data(s);
        self.raw(isa.db(0));
    }

    // ========================================================================
    // Assemble — two-pass label resolution, produces flat binary
    // ========================================================================

    pub fn assemble(self: *const Program, comptime base_addr: u16, comptime size: usize) [size]u8 {
        @setEvalBranchQuota(10000000);

        // Pass 1: collect label addresses
        var labels: [MAX_LABELS]LabelEntry = undefined;
        var label_count: usize = 0;
        var pc: u16 = base_addr;

        for (0..self.count) |i| {
            switch (self.insns[i]) {
                .raw => |enc| pc += enc.len,
                .label_abs16 => pc += 3,
                .label_rel8 => pc += 2,
                .data => |d| pc += @intCast(d.len),
                .org => |addr| pc = addr,
                .label => |name| {
                    for (labels[0..label_count]) |l| {
                        if (strEql(l.name, name)) @compileError("duplicate label: " ++ name);
                    }
                    labels[label_count] = .{ .name = name, .addr = pc };
                    label_count += 1;
                },
                .align_to => |boundary| {
                    while (pc % boundary != 0) pc += 1;
                },
                .fill => |f| {
                    if (pc < f.target_addr) pc = f.target_addr;
                },
            }
        }

        // Pass 2: emit bytes with resolved labels.
        // Track every byte we write so we can detect collisions where two
        // different `org` regions land on the same address. Silent overwrites
        // (e.g., a 3-byte JP at p.org(0x1B76) corrupting the middle of a
        // routine that started earlier at 0x1A50) used to take hours to find.
        // `written[i]` is true ONLY for real code/data (raw, label_*, data) —
        // not for fill_to/align_to passive fills. Real writes over fills are
        // expected and fine; real writes over real writes are bugs.
        var bin: [size]u8 = .{0} ** size;
        var written: [size]bool = .{false} ** size;
        pc = base_addr;
        // First-overlap address (0xFFFFFFFF = none). Reported via @compileError after pass 2.
        var overlap_addr: u32 = 0xFFFFFFFF;
        var overlap_prev_byte: u8 = 0;
        var overlap_new_byte: u8 = 0;

        for (0..self.count) |i| {
            switch (self.insns[i]) {
                .raw => |enc| {
                    for (0..enc.len) |b| {
                        const idx = pc - base_addr + b;
                        if (written[idx] and overlap_addr == 0xFFFFFFFF) {
                            overlap_addr = pc + b;
                            overlap_prev_byte = bin[idx];
                            overlap_new_byte = enc.bytes[b];
                        }
                        bin[idx] = enc.bytes[b];
                        written[idx] = true;
                    }
                    pc += enc.len;
                },
                .label_abs16 => |la| {
                    const target = lookupLabel(labels[0..label_count], la.label);
                    const bytes3 = [3]u8{ la.opcode, @truncate(target), @truncate(target >> 8) };
                    for (0..3) |b| {
                        const idx = pc - base_addr + b;
                        if (written[idx] and overlap_addr == 0xFFFFFFFF) {
                            overlap_addr = pc + b;
                            overlap_prev_byte = bin[idx];
                            overlap_new_byte = bytes3[b];
                        }
                        bin[idx] = bytes3[b];
                        written[idx] = true;
                    }
                    pc += 3;
                },
                .label_rel8 => |lr| {
                    const target = lookupLabel(labels[0..label_count], lr.label);
                    const from = pc + 2; // relative to instruction AFTER this one
                    const offset: i32 = @as(i32, target) - @as(i32, from);
                    if (offset < -128 or offset > 127) @compileError("JR offset out of range for label: " ++ lr.label);
                    const bytes2 = [2]u8{ lr.opcode, @bitCast(@as(i8, @intCast(offset))) };
                    for (0..2) |b| {
                        const idx = pc - base_addr + b;
                        if (written[idx] and overlap_addr == 0xFFFFFFFF) {
                            overlap_addr = pc + b;
                            overlap_prev_byte = bin[idx];
                            overlap_new_byte = bytes2[b];
                        }
                        bin[idx] = bytes2[b];
                        written[idx] = true;
                    }
                    pc += 2;
                },
                .data => |d| {
                    for (0..d.len) |b| {
                        const idx = pc - base_addr + b;
                        if (written[idx] and overlap_addr == 0xFFFFFFFF) {
                            overlap_addr = pc + b;
                            overlap_prev_byte = bin[idx];
                            overlap_new_byte = d[b];
                        }
                        bin[idx] = d[b];
                        written[idx] = true;
                    }
                    pc += @intCast(d.len);
                },
                .org => |addr| pc = addr,
                .label => {},
                .align_to => |boundary| {
                    // Passive fill — do NOT mark as written. Real code may overwrite.
                    while (pc % boundary != 0) {
                        bin[pc - base_addr] = 0;
                        pc += 1;
                    }
                },
                .fill => |f| {
                    // Passive fill — do NOT mark as written. Real code may overwrite.
                    while (pc < f.target_addr) {
                        bin[pc - base_addr] = f.value;
                        pc += 1;
                    }
                },
            }
        }

        if (overlap_addr != 0xFFFFFFFF) {
            @compileError(std.fmt.comptimePrint(
                "ROM overlap at 0x{X:0>4}: existing byte 0x{X:0>2} would be overwritten by 0x{X:0>2}. Two p.org() regions are colliding — find the second p.org that targets near this address and either move it or shrink the routine that crosses it.",
                .{ overlap_addr, overlap_prev_byte, overlap_new_byte },
            ));
        }

        return bin;
    }

    fn lookupLabel(labels: []const LabelEntry, name: []const u8) u16 {
        for (labels) |l| {
            if (strEql(l.name, name)) return l.addr;
        }
        @compileError("undefined label: " ++ name);
    }

    fn strEql(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |ca, cb| {
            if (ca != cb) return false;
        }
        return true;
    }
};
