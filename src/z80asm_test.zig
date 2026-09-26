const std = @import("std");
const z = @import("z80asm.zig");
const isa = @import("z80isa.zig");

test "simple program assembles correctly" {
    comptime {
        var p = z.Program{};

        // LD SP, 0xFEF0
        p.raw(isa.ld_rr_nn(.sp, 0xFEF0));
        // CALL main
        p.call_label("main");
        // HALT
        p.raw(isa.halt());

        // main:
        p.label("main");
        // LD A, 0x42
        p.raw(isa.ld_r_n(.a, 0x42));
        // OUT (1), A
        p.raw(isa.out_n_a(1));
        // RET
        p.raw(isa.ret());

        const bin = p.assemble(0x0000, 16);

        // LD SP, 0xFEF0 → 31 F0 FE
        if (bin[0] != 0x31) @compileError("bad LD SP lo");
        if (bin[1] != 0xF0) @compileError("bad LD SP imm lo");
        if (bin[2] != 0xFE) @compileError("bad LD SP imm hi");

        // CALL main → CD 07 00 (main is at offset 7)
        if (bin[3] != 0xCD) @compileError("bad CALL opcode");
        if (bin[4] != 0x07) @compileError("bad CALL target lo");
        if (bin[5] != 0x00) @compileError("bad CALL target hi");

        // HALT → 76
        if (bin[6] != 0x76) @compileError("bad HALT");

        // main: LD A, 0x42 → 3E 42
        if (bin[7] != 0x3E) @compileError("bad LD A,n");
        if (bin[8] != 0x42) @compileError("bad LD A,n imm");

        // OUT (1), A → D3 01
        if (bin[9] != 0xD3) @compileError("bad OUT");
        if (bin[10] != 0x01) @compileError("bad OUT port");

        // RET → C9
        if (bin[11] != 0xC9) @compileError("bad RET");
    }
}

test "JR label resolution" {
    comptime {
        var p = z.Program{};

        // loop:
        p.label("loop");
        // DEC B
        p.raw(isa.dec_r(.b));
        // JR NZ, loop
        p.jr_cc_label(.nz, "loop");

        const bin = p.assemble(0x0100, 4);

        // DEC B → 05
        if (bin[0] != 0x05) @compileError("bad DEC B");
        // JR NZ, -3 (back 3 bytes: from 0x0103 to 0x0100)
        if (bin[1] != 0x20) @compileError("bad JR NZ opcode");
        if (bin[2] != 0xFD) @compileError("bad JR offset"); // -3 = 0xFD
    }
}

test "org directive" {
    comptime {
        var p = z.Program{};

        p.org(0x0030);
        p.jp_label("entry");

        p.org(0x0100);
        p.label("entry");
        p.raw(isa.halt());

        const bin = p.assemble(0x0000, 0x0101);

        // JP at 0x0030 → C3 00 01
        if (bin[0x30] != 0xC3) @compileError("bad JP at org 0x30");
        if (bin[0x31] != 0x00) @compileError("bad JP target lo");
        if (bin[0x32] != 0x01) @compileError("bad JP target hi");

        // HALT at 0x0100
        if (bin[0x100] != 0x76) @compileError("bad HALT at 0x100");
    }
}
