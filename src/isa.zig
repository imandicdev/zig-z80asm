//! Z80 instruction encoders.
//!
//! One function per instruction form. Operand suffixes in the names:
//! R = 8-bit register, Rr = register pair, N = 8-bit immediate,
//! Nn = 16-bit immediate, Mem = (nn), Idx = IX/IY, IdxD = (IX+d)/(IY+d).
//! Functions do no range checking; callers validate operands first.

pub const Encoding = struct {
    bytes: [4]u8,
    len: u3,

    pub fn slice(e: *const Encoding) []const u8 {
        return e.bytes[0..e.len];
    }
};

pub const R8 = enum(u3) { b, c, d, e, h, l, hl_mem, a };
pub const R16 = enum(u2) { bc, de, hl, sp };
pub const R16af = enum(u2) { bc, de, hl, af };
pub const Idx = enum { ix, iy };
pub const Cc = enum(u3) { nz, z, nc, c, po, pe, p, m };
pub const Alu = enum(u3) { add, adc, sub, sbc, @"and", xor, @"or", cp };
pub const Rot = enum(u3) { rlc = 0, rrc = 1, rl = 2, rr = 3, sla = 4, sra = 5, srl = 7 };

fn enc1(b0: u8) Encoding {
    return .{ .bytes = .{ b0, 0, 0, 0 }, .len = 1 };
}
fn enc2(b0: u8, b1: u8) Encoding {
    return .{ .bytes = .{ b0, b1, 0, 0 }, .len = 2 };
}
fn enc3(b0: u8, b1: u8, b2: u8) Encoding {
    return .{ .bytes = .{ b0, b1, b2, 0 }, .len = 3 };
}
fn enc4(b0: u8, b1: u8, b2: u8, b3: u8) Encoding {
    return .{ .bytes = .{ b0, b1, b2, b3 }, .len = 4 };
}

fn lo(v: u16) u8 {
    return @truncate(v);
}
fn hi(v: u16) u8 {
    return @truncate(v >> 8);
}
fn prefix(idx: Idx) u8 {
    return if (idx == .ix) 0xDD else 0xFD;
}
fn reg(r: R8) u8 {
    return @intFromEnum(r);
}
fn pair(rr: anytype) u8 {
    return @as(u8, @intFromEnum(rr)) << 4;
}
fn disp(d: i8) u8 {
    return @bitCast(d);
}

pub fn nop() Encoding {
    return enc1(0x00);
}
pub fn halt() Encoding {
    return enc1(0x76);
}
pub fn ei() Encoding {
    return enc1(0xFB);
}
pub fn di() Encoding {
    return enc1(0xF3);
}
pub fn exx() Encoding {
    return enc1(0xD9);
}
pub fn exAf() Encoding {
    return enc1(0x08);
}
pub fn exDeHl() Encoding {
    return enc1(0xEB);
}
pub fn exSpHl() Encoding {
    return enc1(0xE3);
}
pub fn exSpIdx(idx: Idx) Encoding {
    return enc2(prefix(idx), 0xE3);
}
pub fn rlca() Encoding {
    return enc1(0x07);
}
pub fn rrca() Encoding {
    return enc1(0x0F);
}
pub fn rla() Encoding {
    return enc1(0x17);
}
pub fn rra() Encoding {
    return enc1(0x1F);
}
pub fn daa() Encoding {
    return enc1(0x27);
}
pub fn cpl() Encoding {
    return enc1(0x2F);
}
pub fn scf() Encoding {
    return enc1(0x37);
}
pub fn ccf() Encoding {
    return enc1(0x3F);
}
pub fn neg() Encoding {
    return enc2(0xED, 0x44);
}
pub fn retn() Encoding {
    return enc2(0xED, 0x45);
}
pub fn reti() Encoding {
    return enc2(0xED, 0x4D);
}
pub fn rrd() Encoding {
    return enc2(0xED, 0x67);
}
pub fn rld() Encoding {
    return enc2(0xED, 0x6F);
}

/// Interrupt mode 0, 1 or 2.
pub fn im(mode: u2) Encoding {
    return enc2(0xED, switch (mode) {
        0 => 0x46,
        1 => 0x56,
        2 => 0x5E,
        3 => unreachable,
    });
}

pub fn ldIA() Encoding {
    return enc2(0xED, 0x47);
}
pub fn ldRA() Encoding {
    return enc2(0xED, 0x4F);
}
pub fn ldAI() Encoding {
    return enc2(0xED, 0x57);
}
pub fn ldAR() Encoding {
    return enc2(0xED, 0x5F);
}

pub fn ldi() Encoding {
    return enc2(0xED, 0xA0);
}
pub fn cpi() Encoding {
    return enc2(0xED, 0xA1);
}
pub fn ini() Encoding {
    return enc2(0xED, 0xA2);
}
pub fn outi() Encoding {
    return enc2(0xED, 0xA3);
}
pub fn ldd() Encoding {
    return enc2(0xED, 0xA8);
}
pub fn cpd() Encoding {
    return enc2(0xED, 0xA9);
}
pub fn ind() Encoding {
    return enc2(0xED, 0xAA);
}
pub fn outd() Encoding {
    return enc2(0xED, 0xAB);
}
pub fn ldir() Encoding {
    return enc2(0xED, 0xB0);
}
pub fn cpir() Encoding {
    return enc2(0xED, 0xB1);
}
pub fn inir() Encoding {
    return enc2(0xED, 0xB2);
}
pub fn otir() Encoding {
    return enc2(0xED, 0xB3);
}
pub fn lddr() Encoding {
    return enc2(0xED, 0xB8);
}
pub fn cpdr() Encoding {
    return enc2(0xED, 0xB9);
}
pub fn indr() Encoding {
    return enc2(0xED, 0xBA);
}
pub fn otdr() Encoding {
    return enc2(0xED, 0xBB);
}

pub fn ldRR(dst: R8, src: R8) Encoding {
    return enc1(0x40 | reg(dst) << 3 | reg(src));
}
pub fn ldRN(dst: R8, n: u8) Encoding {
    return enc2(0x06 | reg(dst) << 3, n);
}
pub fn ldRrNn(dst: R16, nn: u16) Encoding {
    return enc3(0x01 | pair(dst), lo(nn), hi(nn));
}
pub fn ldABc() Encoding {
    return enc1(0x0A);
}
pub fn ldADe() Encoding {
    return enc1(0x1A);
}
pub fn ldBcA() Encoding {
    return enc1(0x02);
}
pub fn ldDeA() Encoding {
    return enc1(0x12);
}
pub fn ldAMem(nn: u16) Encoding {
    return enc3(0x3A, lo(nn), hi(nn));
}
pub fn ldMemA(nn: u16) Encoding {
    return enc3(0x32, lo(nn), hi(nn));
}
pub fn ldSpHl() Encoding {
    return enc1(0xF9);
}

/// LD rr,(nn). HL uses the short 2A form; the others need the ED prefix.
pub fn ldRrMem(dst: R16, nn: u16) Encoding {
    if (dst == .hl) return enc3(0x2A, lo(nn), hi(nn));
    return enc4(0xED, 0x4B | pair(dst), lo(nn), hi(nn));
}

/// LD (nn),rr. HL uses the short 22 form; the others need the ED prefix.
pub fn ldMemRr(nn: u16, src: R16) Encoding {
    if (src == .hl) return enc3(0x22, lo(nn), hi(nn));
    return enc4(0xED, 0x43 | pair(src), lo(nn), hi(nn));
}

pub fn ldIdxNn(idx: Idx, nn: u16) Encoding {
    return enc4(prefix(idx), 0x21, lo(nn), hi(nn));
}
pub fn ldIdxMem(idx: Idx, nn: u16) Encoding {
    return enc4(prefix(idx), 0x2A, lo(nn), hi(nn));
}
pub fn ldMemIdx(nn: u16, idx: Idx) Encoding {
    return enc4(prefix(idx), 0x22, lo(nn), hi(nn));
}
pub fn ldSpIdx(idx: Idx) Encoding {
    return enc2(prefix(idx), 0xF9);
}
pub fn ldRIdxD(dst: R8, idx: Idx, d: i8) Encoding {
    return enc3(prefix(idx), 0x46 | reg(dst) << 3, disp(d));
}
pub fn ldIdxDR(idx: Idx, d: i8, src: R8) Encoding {
    return enc3(prefix(idx), 0x70 | reg(src), disp(d));
}
pub fn ldIdxDN(idx: Idx, d: i8, n: u8) Encoding {
    return enc4(prefix(idx), 0x36, disp(d), n);
}

pub fn push(rr: R16af) Encoding {
    return enc1(0xC5 | pair(rr));
}
pub fn pop(rr: R16af) Encoding {
    return enc1(0xC1 | pair(rr));
}
pub fn pushIdx(idx: Idx) Encoding {
    return enc2(prefix(idx), 0xE5);
}
pub fn popIdx(idx: Idx) Encoding {
    return enc2(prefix(idx), 0xE1);
}

pub fn incR(r: R8) Encoding {
    return enc1(0x04 | reg(r) << 3);
}
pub fn decR(r: R8) Encoding {
    return enc1(0x05 | reg(r) << 3);
}
pub fn incRr(rr: R16) Encoding {
    return enc1(0x03 | pair(rr));
}
pub fn decRr(rr: R16) Encoding {
    return enc1(0x0B | pair(rr));
}
pub fn incIdx(idx: Idx) Encoding {
    return enc2(prefix(idx), 0x23);
}
pub fn decIdx(idx: Idx) Encoding {
    return enc2(prefix(idx), 0x2B);
}
pub fn incIdxD(idx: Idx, d: i8) Encoding {
    return enc3(prefix(idx), 0x34, disp(d));
}
pub fn decIdxD(idx: Idx, d: i8) Encoding {
    return enc3(prefix(idx), 0x35, disp(d));
}

pub fn aluR(op: Alu, r: R8) Encoding {
    return enc1(0x80 | @as(u8, @intFromEnum(op)) << 3 | reg(r));
}
pub fn aluN(op: Alu, n: u8) Encoding {
    return enc2(0xC6 | @as(u8, @intFromEnum(op)) << 3, n);
}
pub fn aluIdxD(op: Alu, idx: Idx, d: i8) Encoding {
    return enc3(prefix(idx), 0x86 | @as(u8, @intFromEnum(op)) << 3, disp(d));
}

pub fn addHlRr(src: R16) Encoding {
    return enc1(0x09 | pair(src));
}
pub fn adcHlRr(src: R16) Encoding {
    return enc2(0xED, 0x4A | pair(src));
}
pub fn sbcHlRr(src: R16) Encoding {
    return enc2(0xED, 0x42 | pair(src));
}

/// ADD IX,rr. Pass .hl for ADD IX,IX (same encoding slot).
pub fn addIdxRr(idx: Idx, src: R16) Encoding {
    return enc2(prefix(idx), 0x09 | pair(src));
}

pub fn jp(nn: u16) Encoding {
    return enc3(0xC3, lo(nn), hi(nn));
}
pub fn jpCc(cc: Cc, nn: u16) Encoding {
    return enc3(0xC2 | @as(u8, @intFromEnum(cc)) << 3, lo(nn), hi(nn));
}
pub fn jpHl() Encoding {
    return enc1(0xE9);
}
pub fn jpIdx(idx: Idx) Encoding {
    return enc2(prefix(idx), 0xE9);
}
pub fn call(nn: u16) Encoding {
    return enc3(0xCD, lo(nn), hi(nn));
}
pub fn callCc(cc: Cc, nn: u16) Encoding {
    return enc3(0xC4 | @as(u8, @intFromEnum(cc)) << 3, lo(nn), hi(nn));
}
pub fn ret() Encoding {
    return enc1(0xC9);
}
pub fn retCc(cc: Cc) Encoding {
    return enc1(0xC0 | @as(u8, @intFromEnum(cc)) << 3);
}

/// RST to one of 0x00, 0x08, ..., 0x38.
pub fn rst(addr: u8) Encoding {
    return enc1(0xC7 | addr);
}

pub fn jr(e: i8) Encoding {
    return enc2(0x18, disp(e));
}
pub fn djnz(e: i8) Encoding {
    return enc2(0x10, disp(e));
}

/// JR only exists for NZ, Z, NC and C.
pub fn jrCc(cc: Cc, e: i8) Encoding {
    return enc2(0x20 | @as(u8, @intFromEnum(cc)) << 3, disp(e));
}

pub fn inAN(n: u8) Encoding {
    return enc2(0xDB, n);
}
pub fn outNA(n: u8) Encoding {
    return enc2(0xD3, n);
}
pub fn inRC(dst: R8) Encoding {
    return enc2(0xED, 0x40 | reg(dst) << 3);
}
pub fn outCR(src: R8) Encoding {
    return enc2(0xED, 0x41 | reg(src) << 3);
}

pub fn rot(op: Rot, r: R8) Encoding {
    return enc2(0xCB, @as(u8, @intFromEnum(op)) << 3 | reg(r));
}
pub fn bit(b: u3, r: R8) Encoding {
    return enc2(0xCB, 0x40 | @as(u8, b) << 3 | reg(r));
}
pub fn res(b: u3, r: R8) Encoding {
    return enc2(0xCB, 0x80 | @as(u8, b) << 3 | reg(r));
}
pub fn set(b: u3, r: R8) Encoding {
    return enc2(0xCB, 0xC0 | @as(u8, b) << 3 | reg(r));
}

pub fn rotIdxD(op: Rot, idx: Idx, d: i8) Encoding {
    return enc4(prefix(idx), 0xCB, disp(d), @as(u8, @intFromEnum(op)) << 3 | 0x06);
}
pub fn bitIdxD(b: u3, idx: Idx, d: i8) Encoding {
    return enc4(prefix(idx), 0xCB, disp(d), 0x46 | @as(u8, b) << 3);
}
pub fn resIdxD(b: u3, idx: Idx, d: i8) Encoding {
    return enc4(prefix(idx), 0xCB, disp(d), 0x86 | @as(u8, b) << 3);
}
pub fn setIdxD(b: u3, idx: Idx, d: i8) Encoding {
    return enc4(prefix(idx), 0xCB, disp(d), 0xC6 | @as(u8, b) << 3);
}
