//! Inputs the assembler must reject. build.zig compiles each one at comptime
//! and expects a compile error ending in `expect`; test/reject_test.zig runs
//! the same input at runtime and expects the same text as the first diagnostic.

pub const Case = struct {
    name: []const u8,
    source: []const u8,
    expect: []const u8,
};

pub const cases = [_]Case{
    .{ .name = "value_too_big_for_8_bits", .source = "  LD A,300\n", .expect = "line 1: value 300 does not fit in 8 bits" },
    .{ .name = "value_too_big_for_16_bits", .source = "  LD HL,70000\n", .expect = "line 1: value 70000 does not fit in 16 bits" },
    .{ .name = "forward_value_too_big", .source = "  LD A,big\nbig EQU 300\n", .expect = "line 1: value 300 does not fit in 8 bits" },
    .{ .name = "relative_jump_range", .source = "  JR far\n  DS 200\nfar: NOP\n", .expect = "line 1: relative jump out of range (200 bytes)" },
    .{ .name = "jr_condition", .source = "x: JR PO,x\n", .expect = "line 1: JR supports only NZ, Z, NC and C" },
    .{ .name = "displacement_range", .source = "  LD A,(IX+200)\n", .expect = "line 1: index displacement 200 out of range -128..127" },
    .{ .name = "rst_target", .source = "  RST 5\n", .expect = "line 1: RST target must be one of 0x00, 0x08, ..., 0x38" },
    .{ .name = "interrupt_mode", .source = "  IM 3\n", .expect = "line 1: interrupt mode must be 0, 1 or 2" },
    .{ .name = "bit_number", .source = "  BIT 8,A\n", .expect = "line 1: bit number 8 out of range 0..7" },
    .{ .name = "division_by_zero", .source = "  DB 1/0\n", .expect = "line 1: division by zero" },
    .{ .name = "undefined_symbol", .source = "  JP nowhere\n", .expect = "line 1: undefined symbol 'nowhere'" },
    .{ .name = "duplicate_symbol", .source = "L1: NOP\nL1: NOP\n", .expect = "line 2: duplicate symbol 'L1'" },
    .{ .name = "equ_without_label", .source = "  EQU 5\n", .expect = "line 1: EQU needs a label" },
    .{ .name = "phase_error", .source = "p1: DS 1-(p2-p1)\np2: NOP\n", .expect = "phase error: label 'p2' did not settle" },
    .{ .name = "overlap", .source = "  ORG 0\n  NOP\n  ORG 0\n  NOP\n", .expect = "line 4: overlap at 0x0000: address written twice" },
    .{ .name = "invalid_operands", .source = "  LD (HL),(HL)\n", .expect = "line 1: invalid operands" },
    .{ .name = "unknown_instruction", .source = "  FOO A\n", .expect = "line 1: unknown instruction 'FOO'" },
    .{ .name = "register_in_expression", .source = "  DW A\n", .expect = "line 1: register 'A' used in an expression" },
    .{ .name = "missing_rparen", .source = "  LD A,(HL\n", .expect = "line 1: expected ')' before end of line" },
    .{ .name = "missing_operand", .source = "  LD A,\n", .expect = "line 1: expected an expression before end of line" },
    .{ .name = "invalid_hex_digit", .source = "  LD A,0x1G\n", .expect = "line 1: invalid number '0x1G'" },
    .{ .name = "empty_hex", .source = "  LD A,0x\n", .expect = "line 1: invalid number '0x'" },
    .{ .name = "stray_character", .source = "  LD A,@\n", .expect = "line 1: unexpected character '@'" },
    .{ .name = "unterminated_string", .source = "  DB \"abc\n", .expect = "line 1: unterminated string" },
    .{ .name = "line_starts_with_number", .source = "  5\n", .expect = "line 1: expected an instruction or directive, found '5'" },
    .{ .name = "trailing_operand", .source = "  NOP A\n", .expect = "line 1: unexpected 'A'" },
};
