// z80isa.zig — Z80 instruction set encoder (comptime)
//
// Every Z80 instruction is a comptime function returning an Encoding.
// No runtime code — all evaluation happens at compile time.
//
// (c) 2026 Ilija Mandic

pub const Encoding = struct {
    bytes: [4]u8 = .{ 0, 0, 0, 0 },
    len: u3, // 1..4
};

// ============================================================================
// Register enums — match Z80 encoding bit fields
// ============================================================================

pub const R8 = enum(u3) {
    b = 0, c = 1, d = 2, e = 3, h = 4, l = 5, hl_ind = 6, a = 7,
};

pub const R16 = enum(u2) {
    bc = 0, de = 1, hl = 2, sp = 3,
};

pub const R16af = enum(u2) {
    bc = 0, de = 1, hl = 2, af = 3,
};

pub const Idx = enum(u1) { ix = 0, iy = 1 };

pub const Cc = enum(u3) {
    nz = 0, z = 1, nc = 2, cy = 3, po = 4, pe = 5, p = 6, m = 7,
};

// ============================================================================
// Helpers
// ============================================================================

fn e1(b0: u8) Encoding {
    return .{ .bytes = .{ b0, 0, 0, 0 }, .len = 1 };
}
fn e2(b0: u8, b1: u8) Encoding {
    return .{ .bytes = .{ b0, b1, 0, 0 }, .len = 2 };
}
fn e3(b0: u8, b1: u8, b2: u8) Encoding {
    return .{ .bytes = .{ b0, b1, b2, 0 }, .len = 3 };
}
fn e4(b0: u8, b1: u8, b2: u8, b3: u8) Encoding {
    return .{ .bytes = .{ b0, b1, b2, b3 }, .len = 4 };
}

fn lo(v: u16) u8 { return @truncate(v); }
fn hi(v: u16) u8 { return @truncate(v >> 8); }

fn idx_prefix(idx: Idx) u8 {
    return switch (idx) { .ix => 0xDD, .iy => 0xFD };
}

// ============================================================================
// 1-byte instructions
// ============================================================================

pub fn nop() Encoding { return e1(0x00); }
pub fn halt() Encoding { return e1(0x76); }
pub fn ret() Encoding { return e1(0xC9); }
pub fn ei() Encoding { return e1(0xFB); }
pub fn di() Encoding { return e1(0xF3); }
pub fn ex_af() Encoding { return e1(0x08); }
pub fn ex_de_hl() Encoding { return e1(0xEB); }
pub fn exx() Encoding { return e1(0xD9); }
pub fn rlca() Encoding { return e1(0x07); }
pub fn rrca() Encoding { return e1(0x0F); }
pub fn rla() Encoding { return e1(0x17); }
pub fn rra() Encoding { return e1(0x1F); }
pub fn cpl() Encoding { return e1(0x2F); }
pub fn scf() Encoding { return e1(0x37); }
pub fn ccf() Encoding { return e1(0x3F); }
pub fn daa() Encoding { return e1(0x27); }
pub fn ld_sp_hl() Encoding { return e1(0xF9); }
pub fn ex_sp_hl() Encoding { return e1(0xE3); }

// ============================================================================
// 2-byte ED-prefixed
// ============================================================================

pub fn reti() Encoding { return e2(0xED, 0x4D); }
pub fn retn() Encoding { return e2(0xED, 0x45); }
pub fn neg() Encoding { return e2(0xED, 0x44); }
pub fn im0() Encoding { return e2(0xED, 0x46); }
pub fn im1() Encoding { return e2(0xED, 0x56); }
pub fn im2() Encoding { return e2(0xED, 0x5E); }
pub fn ld_i_a() Encoding { return e2(0xED, 0x47); }
pub fn ld_a_i() Encoding { return e2(0xED, 0x57); }
pub fn ldir() Encoding { return e2(0xED, 0xB0); }
pub fn lddr() Encoding { return e2(0xED, 0xB8); }
pub fn cpir() Encoding { return e2(0xED, 0xB1); }
pub fn cpdr() Encoding { return e2(0xED, 0xB9); }
pub fn inir() Encoding { return e2(0xED, 0xB2); }
pub fn otir() Encoding { return e2(0xED, 0xB3); }
pub fn indr() Encoding { return e2(0xED, 0xBA); }
pub fn otdr() Encoding { return e2(0xED, 0xBB); }
pub fn ldi() Encoding { return e2(0xED, 0xA0); }
pub fn ldd() Encoding { return e2(0xED, 0xA8); }
pub fn cpi() Encoding { return e2(0xED, 0xA1); }
pub fn cpd() Encoding { return e2(0xED, 0xA9); }
pub fn ini() Encoding { return e2(0xED, 0xA2); }
pub fn ind() Encoding { return e2(0xED, 0xAA); }
pub fn outi() Encoding { return e2(0xED, 0xA3); }
pub fn outd() Encoding { return e2(0xED, 0xAB); }
pub fn rld() Encoding { return e2(0xED, 0x6F); }
pub fn rrd() Encoding { return e2(0xED, 0x67); }
pub fn ld_r_a() Encoding { return e2(0xED, 0x4F); }
pub fn ld_a_r() Encoding { return e2(0xED, 0x5F); }

// ============================================================================
// LD instructions
// ============================================================================

pub fn ld_r_r(dst: R8, src: R8) Encoding {
    return e1(0x40 | (@as(u8, @intFromEnum(dst)) << 3) | @intFromEnum(src));
}
pub fn ld_r_n(dst: R8, n: u8) Encoding {
    return e2(0x06 | (@as(u8, @intFromEnum(dst)) << 3), n);
}
pub fn ld_rr_nn(dst: R16, nn: u16) Encoding {
    return e3(0x01 | (@as(u8, @intFromEnum(dst)) << 4), lo(nn), hi(nn));
}
pub fn ld_hl_ind_n(n: u8) Encoding { return e2(0x36, n); }
pub fn ld_a_bc_ind() Encoding { return e1(0x0A); }
pub fn ld_a_de_ind() Encoding { return e1(0x1A); }
pub fn ld_bc_ind_a() Encoding { return e1(0x02); }
pub fn ld_de_ind_a() Encoding { return e1(0x12); }
pub fn ld_a_nn_ind(nn: u16) Encoding { return e3(0x3A, lo(nn), hi(nn)); }
pub fn ld_nn_ind_a(nn: u16) Encoding { return e3(0x32, lo(nn), hi(nn)); }
pub fn ld_hl_nn_ind(nn: u16) Encoding { return e3(0x2A, lo(nn), hi(nn)); }
pub fn ld_nn_ind_hl(nn: u16) Encoding { return e3(0x22, lo(nn), hi(nn)); }

pub fn ld_rr_nn_ind(dst: R16, nn: u16) Encoding {
    if (dst == .hl) return ld_hl_nn_ind(nn);
    const op: u8 = switch (dst) {
        .bc => 0x4B, .de => 0x5B, .sp => 0x7B, .hl => unreachable,
    };
    return e4(0xED, op, lo(nn), hi(nn));
}
pub fn ld_nn_ind_rr(nn: u16, src: R16) Encoding {
    if (src == .hl) return ld_nn_ind_hl(nn);
    const op: u8 = switch (src) {
        .bc => 0x43, .de => 0x53, .sp => 0x73, .hl => unreachable,
    };
    return e4(0xED, op, lo(nn), hi(nn));
}

pub fn ld_sp_idx(idx: Idx) Encoding { return e2(idx_prefix(idx), 0xF9); }
pub fn ld_idx_nn(idx: Idx, nn: u16) Encoding {
    return e4(idx_prefix(idx), 0x21, lo(nn), hi(nn));
}
pub fn ld_idx_d_r(idx: Idx, d: i8, src: R8) Encoding {
    return e3(idx_prefix(idx), 0x70 | @as(u8, @intFromEnum(src)), @bitCast(d));
}
pub fn ld_r_idx_d(dst: R8, idx: Idx, d: i8) Encoding {
    return e3(idx_prefix(idx), 0x46 | (@as(u8, @intFromEnum(dst)) << 3), @bitCast(d));
}
pub fn ld_idx_d_n(idx: Idx, d: i8, n: u8) Encoding {
    return e4(idx_prefix(idx), 0x36, @bitCast(d), n);
}
pub fn ld_idx_nn_ind(idx: Idx, nn: u16) Encoding {
    return e4(idx_prefix(idx), 0x2A, lo(nn), hi(nn));
}
pub fn ld_nn_ind_idx(nn: u16, idx: Idx) Encoding {
    return e4(idx_prefix(idx), 0x22, lo(nn), hi(nn));
}

// ============================================================================
// PUSH / POP
// ============================================================================

pub fn push(rr: R16af) Encoding { return e1(0xC5 | (@as(u8, @intFromEnum(rr)) << 4)); }
pub fn pop(rr: R16af) Encoding { return e1(0xC1 | (@as(u8, @intFromEnum(rr)) << 4)); }
pub fn push_idx(idx: Idx) Encoding { return e2(idx_prefix(idx), 0xE5); }
pub fn pop_idx(idx: Idx) Encoding { return e2(idx_prefix(idx), 0xE1); }

// ============================================================================
// INC / DEC
// ============================================================================

pub fn inc_r(r: R8) Encoding { return e1(0x04 | (@as(u8, @intFromEnum(r)) << 3)); }
pub fn dec_r(r: R8) Encoding { return e1(0x05 | (@as(u8, @intFromEnum(r)) << 3)); }
pub fn inc_rr(rr: R16) Encoding { return e1(0x03 | (@as(u8, @intFromEnum(rr)) << 4)); }
pub fn dec_rr(rr: R16) Encoding { return e1(0x0B | (@as(u8, @intFromEnum(rr)) << 4)); }
pub fn inc_idx(idx: Idx) Encoding { return e2(idx_prefix(idx), 0x23); }
pub fn dec_idx(idx: Idx) Encoding { return e2(idx_prefix(idx), 0x2B); }
pub fn inc_idx_d(idx: Idx, d: i8) Encoding { return e3(idx_prefix(idx), 0x34, @bitCast(d)); }
pub fn dec_idx_d(idx: Idx, d: i8) Encoding { return e3(idx_prefix(idx), 0x35, @bitCast(d)); }

// ============================================================================
// ALU: ADD, ADC, SUB, SBC, AND, OR, XOR, CP
// ============================================================================

fn alu_r(op: u3, src: R8) Encoding { return e1(0x80 | (@as(u8, op) << 3) | @intFromEnum(src)); }
fn alu_n(op: u3, n: u8) Encoding { return e2(0xC6 | (@as(u8, op) << 3), n); }

pub fn add_a_r(src: R8) Encoding { return alu_r(0, src); }
pub fn adc_a_r(src: R8) Encoding { return alu_r(1, src); }
pub fn sub_r(src: R8) Encoding { return alu_r(2, src); }
pub fn sbc_a_r(src: R8) Encoding { return alu_r(3, src); }
pub fn and_r(src: R8) Encoding { return alu_r(4, src); }
pub fn xor_r(src: R8) Encoding { return alu_r(5, src); }
pub fn or_r(src: R8) Encoding { return alu_r(6, src); }
pub fn cp_r(src: R8) Encoding { return alu_r(7, src); }

pub fn add_a_n(n: u8) Encoding { return alu_n(0, n); }
pub fn adc_a_n(n: u8) Encoding { return alu_n(1, n); }
pub fn sub_n(n: u8) Encoding { return alu_n(2, n); }
pub fn sbc_a_n(n: u8) Encoding { return alu_n(3, n); }
pub fn and_n(n: u8) Encoding { return alu_n(4, n); }
pub fn xor_n(n: u8) Encoding { return alu_n(5, n); }
pub fn or_n(n: u8) Encoding { return alu_n(6, n); }
pub fn cp_n(n: u8) Encoding { return alu_n(7, n); }

fn alu_idx_d(op: u3, idx: Idx, d: i8) Encoding { return e3(idx_prefix(idx), 0x86 | (@as(u8, op) << 3), @bitCast(d)); }

pub fn add_a_idx_d(idx: Idx, d: i8) Encoding { return alu_idx_d(0, idx, d); }
pub fn adc_a_idx_d(idx: Idx, d: i8) Encoding { return alu_idx_d(1, idx, d); }
pub fn sub_idx_d(idx: Idx, d: i8) Encoding { return alu_idx_d(2, idx, d); }
pub fn sbc_a_idx_d(idx: Idx, d: i8) Encoding { return alu_idx_d(3, idx, d); }
pub fn and_idx_d(idx: Idx, d: i8) Encoding { return alu_idx_d(4, idx, d); }
pub fn xor_idx_d(idx: Idx, d: i8) Encoding { return alu_idx_d(5, idx, d); }
pub fn or_idx_d(idx: Idx, d: i8) Encoding { return alu_idx_d(6, idx, d); }
pub fn cp_idx_d(idx: Idx, d: i8) Encoding { return alu_idx_d(7, idx, d); }

pub fn add_hl_rr(src: R16) Encoding { return e1(0x09 | (@as(u8, @intFromEnum(src)) << 4)); }
pub fn adc_hl_rr(src: R16) Encoding { return e2(0xED, 0x4A | (@as(u8, @intFromEnum(src)) << 4)); }
pub fn sbc_hl_rr(src: R16) Encoding { return e2(0xED, 0x42 | (@as(u8, @intFromEnum(src)) << 4)); }
pub fn add_idx_rr(idx: Idx, src: R16) Encoding { return e2(idx_prefix(idx), 0x09 | (@as(u8, @intFromEnum(src)) << 4)); }

// ============================================================================
// Jumps
// ============================================================================

pub fn jp(nn: u16) Encoding { return e3(0xC3, lo(nn), hi(nn)); }
pub fn jp_cc(cc: Cc, nn: u16) Encoding { return e3(0xC2 | (@as(u8, @intFromEnum(cc)) << 3), lo(nn), hi(nn)); }
pub fn jp_hl() Encoding { return e1(0xE9); }
pub fn jp_idx(idx: Idx) Encoding { return e2(idx_prefix(idx), 0xE9); }
pub fn jr(offset: i8) Encoding { return e2(0x18, @bitCast(offset)); }
pub fn jr_cc(cc: Cc, offset: i8) Encoding {
    const op: u8 = switch (cc) {
        .nz => 0x20, .z => 0x28, .nc => 0x30, .cy => 0x38,
        else => @compileError("JR only supports NZ, Z, NC, C"),
    };
    return e2(op, @bitCast(offset));
}
pub fn djnz(offset: i8) Encoding { return e2(0x10, @bitCast(offset)); }

// ============================================================================
// Calls / Returns
// ============================================================================

pub fn call(nn: u16) Encoding { return e3(0xCD, lo(nn), hi(nn)); }
pub fn call_cc(cc: Cc, nn: u16) Encoding { return e3(0xC4 | (@as(u8, @intFromEnum(cc)) << 3), lo(nn), hi(nn)); }
pub fn ret_cc(cc: Cc) Encoding { return e1(0xC0 | (@as(u8, @intFromEnum(cc)) << 3)); }
pub fn rst(n: u8) Encoding { return e1(0xC7 | n); }

// ============================================================================
// I/O
// ============================================================================

pub fn in_a_n(n: u8) Encoding { return e2(0xDB, n); }
pub fn out_n_a(n: u8) Encoding { return e2(0xD3, n); }
pub fn in_r_c(dst: R8) Encoding { return e2(0xED, 0x40 | (@as(u8, @intFromEnum(dst)) << 3)); }
pub fn out_c_r(src: R8) Encoding { return e2(0xED, 0x41 | (@as(u8, @intFromEnum(src)) << 3)); }

// ============================================================================
// Bit operations (CB prefix)
// ============================================================================

pub fn bit_op(b: u3, r: R8) Encoding { return e2(0xCB, 0x40 | (@as(u8, b) << 3) | @intFromEnum(r)); }
pub fn set_op(b: u3, r: R8) Encoding { return e2(0xCB, 0xC0 | (@as(u8, b) << 3) | @intFromEnum(r)); }
pub fn res_op(b: u3, r: R8) Encoding { return e2(0xCB, 0x80 | (@as(u8, b) << 3) | @intFromEnum(r)); }

pub fn rlc_r(r: R8) Encoding { return e2(0xCB, 0x00 | @as(u8, @intFromEnum(r))); }
pub fn rrc_r(r: R8) Encoding { return e2(0xCB, 0x08 | @as(u8, @intFromEnum(r))); }
pub fn rl_r(r: R8) Encoding { return e2(0xCB, 0x10 | @as(u8, @intFromEnum(r))); }
pub fn rr_r(r: R8) Encoding { return e2(0xCB, 0x18 | @as(u8, @intFromEnum(r))); }
pub fn sla_r(r: R8) Encoding { return e2(0xCB, 0x20 | @as(u8, @intFromEnum(r))); }
pub fn sra_r(r: R8) Encoding { return e2(0xCB, 0x28 | @as(u8, @intFromEnum(r))); }
pub fn srl_r(r: R8) Encoding { return e2(0xCB, 0x38 | @as(u8, @intFromEnum(r))); }

// DD CB d xx / FD CB d xx: bit operations and rotates on (IX+d) / (IY+d)
fn idx_cb(idx: Idx, d: i8, op: u8) Encoding { return e4(idx_prefix(idx), 0xCB, @bitCast(d), op); }

pub fn bit_idx_d(b: u3, idx: Idx, d: i8) Encoding { return idx_cb(idx, d, 0x46 | (@as(u8, b) << 3)); }
pub fn set_idx_d(b: u3, idx: Idx, d: i8) Encoding { return idx_cb(idx, d, 0xC6 | (@as(u8, b) << 3)); }
pub fn res_idx_d(b: u3, idx: Idx, d: i8) Encoding { return idx_cb(idx, d, 0x86 | (@as(u8, b) << 3)); }

pub fn rlc_idx_d(idx: Idx, d: i8) Encoding { return idx_cb(idx, d, 0x06); }
pub fn rrc_idx_d(idx: Idx, d: i8) Encoding { return idx_cb(idx, d, 0x0E); }
pub fn rl_idx_d(idx: Idx, d: i8) Encoding { return idx_cb(idx, d, 0x16); }
pub fn rr_idx_d(idx: Idx, d: i8) Encoding { return idx_cb(idx, d, 0x1E); }
pub fn sla_idx_d(idx: Idx, d: i8) Encoding { return idx_cb(idx, d, 0x26); }
pub fn sra_idx_d(idx: Idx, d: i8) Encoding { return idx_cb(idx, d, 0x2E); }
pub fn srl_idx_d(idx: Idx, d: i8) Encoding { return idx_cb(idx, d, 0x3E); }

// ============================================================================
// EX (SP), IX/IY
// ============================================================================

pub fn ex_sp_idx(idx: Idx) Encoding { return e2(idx_prefix(idx), 0xE3); }

// ============================================================================
// Data embedding
// ============================================================================

pub fn db(val: u8) Encoding { return e1(val); }
pub fn dw(val: u16) Encoding { return e2(lo(val), hi(val)); }
