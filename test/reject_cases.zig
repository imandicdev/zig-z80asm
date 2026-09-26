//! Inputs the parser must reject with a compile error instead of emitting
//! wrong bytes. Each case is compiled on its own by build.zig (`zig build test`)
//! and the build checks that the error message ends with `expect`.
//!
//! The first eight are the silent-wrong-output cases found by the feature
//! probe: they used to compile and produce incorrect machine code.

pub const Case = struct {
    name: []const u8,
    source: []const u8,
    expect: []const u8,
};

pub const cases = [_]Case{
    // --- Regression: used to assemble silently to wrong bytes ---
    .{ .name = "hex_dollar_prefix", .source = "  LD A,$FF\n", .expect = "'$' (current address) is not supported yet" },
    .{ .name = "binary_percent_prefix", .source = "  LD A,%1010\n", .expect = "unexpected character '%'" },
    .{ .name = "binary_b_suffix", .source = "  LD A,1010B\n", .expect = "invalid number '1010B'" },
    .{ .name = "expr_add", .source = "  LD A,2+3\n", .expect = "unexpected '+' (expressions are not supported yet)" },
    .{ .name = "expr_mul", .source = "  LD A,2*3\n", .expect = "unexpected character '*'" },
    .{ .name = "label_plus_offset", .source = "L1: LD HL,L1+1\n", .expect = "unexpected '+' (expressions are not supported yet)" },
    .{ .name = "jr_dollar", .source = "  JR $\n", .expect = "'$' (current address) is not supported yet" },
    .{ .name = "dw_label", .source = "L1: DW L1\n", .expect = "DW with a label is not supported yet" },

    // --- Other paths that used to be silent ---
    .{ .name = "value_too_big_for_8_bits", .source = "  LD A,300\n", .expect = "value 300 does not fit in 8 bits" },
    .{ .name = "value_too_big_for_16_bits", .source = "  LD HL,70000\n", .expect = "value 70000 does not fit in 16 bits" },
    .{ .name = "jr_numeric_target", .source = "  JR 0x0105\n", .expect = "JR with a numeric target is not supported yet; use a label" },
    .{ .name = "djnz_numeric_target", .source = "  DJNZ 5\n", .expect = "DJNZ with a numeric target is not supported yet; use a label" },
    .{ .name = "rst_invalid_target", .source = "  RST 5\n", .expect = "RST target must be one of 0x00, 0x08, ..., 0x38" },
    .{ .name = "equ_ignored", .source = "  EQU 5\n", .expect = "EQU is not supported yet" },
    .{ .name = "index_displacement_label", .source = "  LD A,(IX+OFS)\n", .expect = "index displacement must be a number (expressions are not supported yet)" },
    .{ .name = "index_displacement_range", .source = "  LD A,(IX+200)\n", .expect = "index displacement out of range -128..127" },
    .{ .name = "missing_rparen", .source = "  LD A,(HL\n", .expect = "expected ')'" },
    .{ .name = "invalid_hex_digit", .source = "  LD A,0x1G\n", .expect = "invalid number '0x1G'" },
    .{ .name = "empty_hex", .source = "  LD A,0x\n", .expect = "invalid number '0x'" },
    .{ .name = "unterminated_string", .source = "  DB \"abc\n", .expect = "unterminated string literal" },
    .{ .name = "line_starts_with_number", .source = "  5\n", .expect = "expected a label or mnemonic, found '5'" },
    .{ .name = "duplicate_label", .source = "L1: NOP\nL1: NOP\n", .expect = "duplicate label: L1" },
    .{ .name = "trailing_operand", .source = "  NOP A\n", .expect = "unexpected 'A' (expressions are not supported yet)" },
};
