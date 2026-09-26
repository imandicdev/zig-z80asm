//! Inputs the assembler must reject. build.zig compiles each one at comptime
//! and expects a compile error ending in `expect`; test/reject_test.zig runs
//! the same input at runtime and expects the same text as the first diagnostic.

pub const Case = struct {
    name: []const u8,
    source: []const u8,
    expect: []const u8,
    /// The options of comptimeAssemble, as Zig source.
    options: []const u8 = ".{}",
};

/// Limits set through the comptime options. The runtime takes its capacity
/// from the buffers instead, so these are checked at comptime only.
pub const comptime_only = [_]Case{
    .{ .name = "symbol_capacity", .options = ".{ .max_symbols = 2 }", .source = "a: NOP\nb: NOP\nc: NOP\n", .expect = "line 3: too many symbols (capacity 2)" },
    .{ .name = "diagnostic_capacity", .options = ".{ .max_diagnostics = 1 }", .source = "  DB 300\n  DB 301\n  DB 302\n", .expect = "(2 more)" },
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
    .{ .name = "division_overflow", .source = "  DW (-2147483647-1)/-1\n", .expect = "line 1: value -2147483648 does not fit in 16 bits" },
    .{ .name = "relative_jump_huge_target", .source = "  JR -2147483647\n", .expect = "line 1: relative jump out of range (-2147483649 bytes)" },
    .{ .name = "division_by_zero", .source = "  DB 1/0\n", .expect = "line 1: division by zero" },
    .{ .name = "undefined_symbol", .source = "  JP nowhere\n", .expect = "line 1: undefined symbol 'nowhere'" },
    .{ .name = "circular_equ", .source = "x EQU y\ny EQU x\n  LD A,x\n", .expect = "line 1: symbol 'y' has no value" },
    .{ .name = "self_referencing_ds", .source = "  DS n\nn EQU n\n", .expect = "line 1: symbol 'n' has no value" },
    .{ .name = "sdcc_data_area", .source = "  .area _DATA\n_x::\n  .ds 2\n", .expect = "line 2: only the _CODE area is supported, not '_DATA'" },
    .{ .name = "local_label_other_scope", .source = "f:\n1$: NOP\ng: JR 1$\n", .expect = "line 3: undefined symbol '1$'" },
    .{ .name = "duplicate_symbol", .source = "L1: NOP\nL1: NOP\n", .expect = "line 2: duplicate symbol 'L1'" },
    .{ .name = "end_undefined_entry", .source = "  NOP\n  END start\n", .expect = "line 2: undefined symbol 'start'" },
    .{ .name = "equ_without_label", .source = "  EQU 5\n", .expect = "line 1: EQU needs a label" },
    .{ .name = "phase_error", .source = "p1: DS 1-(p2-p1)\np2: NOP\n", .expect = "phase error: label 'p2' did not settle" },
    .{ .name = "overlap", .source = "  ORG 0\n  NOP\n  ORG 0\n  NOP\n", .expect = "line 4: overlap at 0x0000: address written twice" },
    .{ .name = "invalid_operands", .source = "  LD (HL),(HL)\n", .expect = "line 1: invalid operands" },
    .{ .name = "unknown_instruction", .source = "  FOO A\n", .expect = "line 1: unknown instruction 'FOO'" },
    .{ .name = "register_in_expression", .source = "  DW A\n", .expect = "line 1: register 'A' used in an expression" },
    .{ .name = "missing_rparen", .source = "  LD A,(HL\n", .expect = "line 1: expected ')' before end of line" },
    .{ .name = "missing_operand", .source = "  LD A,\n", .expect = "line 1: expected an expression before end of line" },
    .{ .name = "ambiguous_hash_number", .source = "  LD HL,#4000\n", .expect = "line 1: '#4000' is hex in sjasmplus and decimal in SDCC; write 0x4000 or the decimal value" },
    .{ .name = "hash_number_too_large", .source = "  DW #FFFFFFFFF\n", .expect = "line 1: invalid number '#FFFFFFFFF'" },
    .{ .name = "invalid_hex_digit", .source = "  LD A,0x1G\n", .expect = "line 1: invalid number '0x1G'" },
    .{ .name = "empty_hex", .source = "  LD A,0x\n", .expect = "line 1: invalid number '0x'" },
    .{ .name = "stray_character", .source = "  LD A,@\n", .expect = "line 1: unexpected character '@'" },
    .{ .name = "unknown_escape", .source = "  DB \"a\\qb\"\n", .expect = "line 1: unknown escape '\\q' in string" },
    .{ .name = "escaped_closing_quote", .source = "  DB \"a\\\"\n", .expect = "line 1: unterminated string" },
    .{ .name = "unterminated_string", .source = "  DB \"abc\n", .expect = "line 1: unterminated string" },
    .{ .name = "line_starts_with_number", .source = "  5\n", .expect = "line 1: expected an instruction or directive, found '5'" },
    .{ .name = "trailing_operand", .source = "  NOP A\n", .expect = "line 1: unexpected 'A'" },
    .{ .name = "instruction_too_long", .source = "  LD A," ++ "1+" ** 40 ++ "1\n", .expect = "line 1: line has more than 64 tokens" },
    .{ .name = "equ_too_long", .source = "x EQU " ++ "1+" ** 40 ++ "1\n", .expect = "line 1: line has more than 64 tokens" },
    .{ .name = "data_value_too_long", .source = "  DB 1," ++ "1+" ** 40 ++ "1,2\n", .expect = "line 1: value has more than 62 tokens" },
    .{ .name = "stray_character_after_many_values", .source = "  DB " ++ "1," ** 100 ++ "@\n", .expect = "line 1: unexpected character '@'" },
    .{ .name = "garbage_after_many_values", .source = "  DW " ++ "1," ** 100 ++ "2 3\n", .expect = "line 1: unexpected '3'" },
};
