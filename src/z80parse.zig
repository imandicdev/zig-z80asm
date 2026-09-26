// z80parse.zig -- Comptime Z80 assembly text parser
//
// Parses standard Z80/Zilog assembly mnemonics (and SDCC-format assembly)
// at compile time and produces machine code bytes.
//
// Architecture:
//   z80isa.zig  -- low-level opcode encoder (Encoding structs)
//   z80asm.zig  -- programmatic assembler API (Program builder + two-pass linker)
//   z80parse.zig -- THIS FILE: text parser that drives z80asm.zig
//
// Usage:
//   const code = comptime z80parse.assemble(
//       \\  LD SP, #0xFEF0
//       \\  CALL _main
//       \\  HALT
//       \\_main:
//       \\  LD A, #0x42
//       \\  OUT (1), A
//       \\  RET
//   , 0x0000, 64);
//
// (c) 2026 Ilija Mandic

const isa = @import("z80isa.zig");
const za = @import("z80asm.zig");

// ============================================================================
// Token types
// ============================================================================

const TokenKind = enum {
    ident, // mnemonic, register name, label reference
    number, // decimal, hex, binary literal
    string_lit, // "..." or '...' for .ascii/.asciz
    lparen, // (
    rparen, // )
    comma, // ,
    colon, // :
    hash, // #
    plus, // +
    minus, // -
    newline, // statement separator
    dot, // . (for directives and local labels)
    double_colon, // :: (SDCC public label)
    dollar, // $ (current PC)
    eof,
};

const Token = struct {
    kind: TokenKind,
    text: []const u8,
    line: usize,
};

// ============================================================================
// Lexer
// ============================================================================

const Lexer = struct {
    src: []const u8,
    pos: usize,
    line: usize,

    fn init(src: []const u8) Lexer {
        return .{ .src = src, .pos = 0, .line = 1 };
    }

    fn peek(self: *const Lexer) u8 {
        if (self.pos >= self.src.len) return 0;
        return self.src[self.pos];
    }

    fn advance(self: *Lexer) void {
        if (self.pos < self.src.len) {
            if (self.src[self.pos] == '\n') self.line += 1;
            self.pos += 1;
        }
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\r') {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn skipComment(self: *Lexer) void {
        // ; comment to end of line
        while (self.pos < self.src.len and self.src[self.pos] != '\n') {
            self.pos += 1;
        }
    }

    fn next(self: *Lexer) Token {
        self.skipWhitespace();

        if (self.pos >= self.src.len) {
            return .{ .kind = .eof, .text = "", .line = self.line };
        }

        const c = self.src[self.pos];
        const line = self.line;

        // Comments
        if (c == ';') {
            self.skipComment();
            // Return newline token to terminate the statement
            return .{ .kind = .newline, .text = ";", .line = line };
        }

        // Newline
        if (c == '\n') {
            self.advance();
            return .{ .kind = .newline, .text = "\n", .line = line };
        }

        // Single-char tokens
        if (c == '(') { self.advance(); return .{ .kind = .lparen, .text = "(", .line = line }; }
        if (c == ')') { self.advance(); return .{ .kind = .rparen, .text = ")", .line = line }; }
        if (c == ',') { self.advance(); return .{ .kind = .comma, .text = ",", .line = line }; }
        if (c == '#') { self.advance(); return .{ .kind = .hash, .text = "#", .line = line }; }
        if (c == '+') { self.advance(); return .{ .kind = .plus, .text = "+", .line = line }; }
        if (c == '-') {
            // Check if this is a negative number (not preceded by register/ident)
            if (self.pos + 1 < self.src.len and isDigit(self.src[self.pos + 1])) {
                // Could be negative number, but we'll let the parser handle sign
                self.advance();
                return .{ .kind = .minus, .text = "-", .line = line };
            }
            self.advance();
            return .{ .kind = .minus, .text = "-", .line = line };
        }
        if (c == '$') { self.advance(); return .{ .kind = .dollar, .text = "$", .line = line }; }

        // Colon (: or ::)
        if (c == ':') {
            self.advance();
            if (self.pos < self.src.len and self.src[self.pos] == ':') {
                self.advance();
                return .{ .kind = .double_colon, .text = "::", .line = line };
            }
            return .{ .kind = .colon, .text = ":", .line = line };
        }

        // String literals
        if (c == '"' or c == '\'') {
            return self.lexString(c, line);
        }

        // Dot - could be directive or local label
        if (c == '.') {
            self.advance();
            if (self.pos < self.src.len and isIdentChar(self.src[self.pos])) {
                const start = self.pos - 1;
                while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) {
                    self.pos += 1;
                }
                return .{ .kind = .ident, .text = self.src[start..self.pos], .line = line };
            }
            return .{ .kind = .dot, .text = ".", .line = line };
        }

        // Numbers: 0x, 0b, decimal, or trailing 'h' for hex
        if (isDigit(c)) {
            return self.lexNumber(line);
        }

        // Identifiers: mnemonics, registers, labels
        if (isIdentStart(c)) {
            return self.lexIdent(line);
        }

        // Unknown character: never skip it, or "2*3" would silently become "2 3".
        @compileError(std.fmt.comptimePrint("line {d}: unexpected character '{c}'", .{ line, c }));
    }

    fn lexString(self: *Lexer, quote: u8, line: usize) Token {
        self.advance(); // skip opening quote
        const start = self.pos;
        while (self.pos < self.src.len and self.src[self.pos] != quote and self.src[self.pos] != '\n') {
            self.pos += 1;
        }
        const text = self.src[start..self.pos];
        if (self.pos >= self.src.len or self.src[self.pos] != quote) {
            @compileError(std.fmt.comptimePrint("line {d}: unterminated string literal", .{line}));
        }
        self.pos += 1; // skip closing quote
        return .{ .kind = .string_lit, .text = text, .line = line };
    }

    fn lexNumber(self: *Lexer, line: usize) Token {
        const start = self.pos;

        // SDCC local label such as 00101$: decimal digits followed by '$'.
        var end = self.pos;
        while (end < self.src.len and isDigit(self.src[end])) end += 1;
        if (end < self.src.len and self.src[end] == '$') {
            self.pos = end + 1;
            return .{ .kind = .ident, .text = self.src[start..self.pos], .line = line };
        }

        // Take the whole alphanumeric run (0x1F, 0FFh, 0B8H, 0b1010, 42) and let
        // parseNumber validate it, so malformed numbers are rejected, not truncated.
        while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) {
            self.pos += 1;
        }
        const text = self.src[start..self.pos];
        _ = parseNumberAt(text, line); // validate now for a precise error location
        return .{ .kind = .number, .text = text, .line = line };
    }

    fn lexIdent(self: *Lexer, line: usize) Token {
        const start = self.pos;
        while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) {
            self.pos += 1;
        }
        // SDCC local labels like 00101$ — check for trailing $
        if (self.pos < self.src.len and self.src[self.pos] == '$') {
            self.pos += 1;
        }
        // Check for AF' (alternate register)
        if (self.pos < self.src.len and self.src[self.pos] == '\'') {
            if (upperEql(self.src[start..self.pos], "AF")) {
                self.pos += 1; // consume the '
            }
        }
        return .{ .kind = .ident, .text = self.src[start..self.pos], .line = line };
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn isHexDigit(c: u8) bool {
        return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    }

    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }

    fn isIdentChar(c: u8) bool {
        return isIdentStart(c) or isDigit(c);
    }
};

// ============================================================================
// String utility functions (comptime-safe)
// ============================================================================

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn toUpper(s: []const u8) [64]u8 {
    var buf: [64]u8 = .{0} ** 64;
    const len = if (s.len > 64) 64 else s.len;
    for (0..len) |i| {
        buf[i] = if (s[i] >= 'a' and s[i] <= 'z') s[i] - 32 else s[i];
    }
    return buf;
}

fn toUpperSlice(s: []const u8) []const u8 {
    // Returns slice into static buffer; only valid transiently at comptime
    const buf = toUpper(s);
    const len = if (s.len > 64) 64 else s.len;
    return buf[0..len];
}

fn upperEql(s: []const u8, target: []const u8) bool {
    if (s.len != target.len) return false;
    for (0..s.len) |i| {
        const c = if (s[i] >= 'a' and s[i] <= 'z') s[i] - 32 else s[i];
        if (c != target[i]) return false;
    }
    return true;
}

// ============================================================================
// Number parser
// ============================================================================

fn parseNumber(text: []const u8) i32 {
    return parseNumberAt(text, 0);
}

/// Strictly parse a numeric literal: 0x1F, 1FH / 0FFh, 0b1010, or decimal.
/// Any character that is not a valid digit for the base is a compile error.
fn parseNumberAt(text: []const u8, line: usize) i32 {
    var s = text;
    if (s.len >= 1 and s[0] == '#') s = s[1..]; // SDCC immediate prefix

    if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X'))
        return parseDigits(s[2..], 16, text, line);
    if (s.len >= 2 and (s[s.len - 1] == 'h' or s[s.len - 1] == 'H'))
        return parseDigits(s[0 .. s.len - 1], 16, text, line);
    if (s.len >= 2 and s[0] == '0' and (s[1] == 'b' or s[1] == 'B'))
        return parseDigits(s[2..], 2, text, line);
    return parseDigits(s, 10, text, line);
}

fn parseDigits(digits: []const u8, base: u8, text: []const u8, line: usize) i32 {
    if (digits.len == 0) numberError(text, line);
    var val: i64 = 0;
    for (digits) |c| {
        const v: u8 = digitValue(c) orelse numberError(text, line);
        if (v >= base) numberError(text, line);
        val = val * base + v;
        if (val > 0x7FFF_FFFF) @compileError(std.fmt.comptimePrint("line {d}: number too large '{s}'", .{ line, text }));
    }
    return @intCast(val);
}

fn digitValue(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn numberError(text: []const u8, line: usize) noreturn {
    @compileError(std.fmt.comptimePrint("line {d}: invalid number '{s}'", .{ line, text }));
}

// ============================================================================
// Register recognition
// ============================================================================

const RegKind = enum {
    // 8-bit registers
    a, b, c, d, e, h, l,
    // 16-bit pairs
    af, bc, de, hl, sp, ix, iy,
    // Indirect
    hl_ind, // (HL)
    bc_ind, // (BC)
    de_ind, // (DE)
    // Alternate
    af_prime, // AF'
    // Index indirect parsed separately: (IX+d), (IY+d)
    // Special
    i_reg, r_reg,
    // Not a register
    none,
};

fn classifyRegister(text: []const u8) RegKind {
    if (text.len == 0) return .none;
    if (upperEql(text, "A")) return .a;
    if (upperEql(text, "B")) return .b;
    if (upperEql(text, "C")) return .c;
    if (upperEql(text, "D")) return .d;
    if (upperEql(text, "E")) return .e;
    if (upperEql(text, "H")) return .h;
    if (upperEql(text, "L")) return .l;
    if (upperEql(text, "AF")) return .af;
    if (strEql(text, "AF'") or strEql(text, "af'") or upperEql(text, "AF'")) return .af_prime;
    if (upperEql(text, "BC")) return .bc;
    if (upperEql(text, "DE")) return .de;
    if (upperEql(text, "HL")) return .hl;
    if (upperEql(text, "SP")) return .sp;
    if (upperEql(text, "IX")) return .ix;
    if (upperEql(text, "IY")) return .iy;
    if (upperEql(text, "I")) return .i_reg;
    if (upperEql(text, "R")) return .r_reg;
    return .none;
}

fn regToR8(reg: RegKind) ?isa.R8 {
    return switch (reg) {
        .a => .a,
        .b => .b,
        .c => .c,
        .d => .d,
        .e => .e,
        .h => .h,
        .l => .l,
        .hl_ind => .hl_ind,
        else => null,
    };
}

fn regToR16(reg: RegKind) ?isa.R16 {
    return switch (reg) {
        .bc => .bc,
        .de => .de,
        .hl => .hl,
        .sp => .sp,
        else => null,
    };
}

fn regToR16af(reg: RegKind) ?isa.R16af {
    return switch (reg) {
        .bc => .bc,
        .de => .de,
        .hl => .hl,
        .af => .af,
        else => null,
    };
}

fn regToIdx(reg: RegKind) ?isa.Idx {
    return switch (reg) {
        .ix => .ix,
        .iy => .iy,
        else => null,
    };
}

// ============================================================================
// Condition code recognition
// ============================================================================

fn classifyCc(text: []const u8) ?isa.Cc {
    if (upperEql(text, "NZ")) return .nz;
    if (upperEql(text, "Z")) return .z;
    if (upperEql(text, "NC")) return .nc;
    if (upperEql(text, "C")) return .cy;
    if (upperEql(text, "PO")) return .po;
    if (upperEql(text, "PE")) return .pe;
    if (upperEql(text, "P")) return .p;
    if (upperEql(text, "M")) return .m;
    return null;
}

// ============================================================================
// Operand types (parsed from token stream)
// ============================================================================

const Operand = struct {
    kind: OperandKind,
    reg: RegKind = .none,
    idx: ?isa.Idx = null,
    displacement: i8 = 0,
    imm: i32 = 0,
    label: []const u8 = "",
    cc: ?isa.Cc = null,
};

const OperandKind = enum {
    none,
    reg8, // A, B, C, D, E, H, L
    reg16, // BC, DE, HL, SP
    reg_af, // AF
    reg_af_prime, // AF'
    reg_idx, // IX, IY
    reg_i, // I
    reg_r, // R
    indirect_hl, // (HL)
    indirect_bc, // (BC)
    indirect_de, // (DE)
    indirect_idx, // (IX+d) or (IY+d)
    indirect_nn, // (nn) -- direct address
    indirect_c, // (C) -- for IN/OUT
    imm8, // 8-bit immediate
    imm16, // 16-bit immediate
    label_ref, // label reference (forward/backward)
    condition, // condition code NZ, Z, NC, C, PO, PE, P, M
    bit_num, // 0-7 for BIT/SET/RES
    port_n, // port number in parentheses for IN/OUT
};

// ============================================================================
// Parser state
// ============================================================================

const MAX_TOKENS_PER_LINE = 32;

const Parser = struct {
    lexer: Lexer,
    program: *za.Program,
    current_scope: []const u8, // for local label scoping
    line_tokens: [MAX_TOKENS_PER_LINE]Token = undefined,
    line_token_count: usize = 0,
    token_pos: usize = 0,
    has_errors: bool = false,

    fn init(src: []const u8, program: *za.Program) Parser {
        return .{
            .lexer = Lexer.init(src),
            .program = program,
            .current_scope = "",
        };
    }

    // Read tokens until newline/eof, storing them for the current line
    fn readLine(self: *Parser) void {
        self.line_token_count = 0;
        self.token_pos = 0;
        while (true) {
            const tok = self.lexer.next();
            if (tok.kind == .newline or tok.kind == .eof) {
                // Store the terminator
                if (self.line_token_count < MAX_TOKENS_PER_LINE) {
                    self.line_tokens[self.line_token_count] = tok;
                    self.line_token_count += 1;
                }
                break;
            }
            if (self.line_token_count + 1 >= MAX_TOKENS_PER_LINE) {
                @compileError(std.fmt.comptimePrint("line {d}: too many tokens on one line (max {d})", .{ tok.line, MAX_TOKENS_PER_LINE - 1 }));
            }
            self.line_tokens[self.line_token_count] = tok;
            self.line_token_count += 1;
        }
    }

    fn peekToken(self: *const Parser) Token {
        if (self.token_pos >= self.line_token_count)
            return .{ .kind = .eof, .text = "", .line = 0 };
        return self.line_tokens[self.token_pos];
    }

    fn nextToken(self: *Parser) Token {
        if (self.token_pos >= self.line_token_count)
            return .{ .kind = .eof, .text = "", .line = 0 };
        const tok = self.line_tokens[self.token_pos];
        self.token_pos += 1;
        return tok;
    }

    fn atEnd(self: *const Parser) bool {
        const tok = self.peekToken();
        return tok.kind == .eof or tok.kind == .newline;
    }

    fn expectComma(self: *Parser) void {
        const tok = self.nextToken();
        if (tok.kind != .comma) {
            self.fail("expected comma");
        }
    }

    fn expectRparen(self: *Parser) void {
        const tok = self.nextToken();
        if (tok.kind != .rparen) {
            self.fail("expected ')'");
        }
    }

    fn currentLine(self: *const Parser) usize {
        return if (self.line_token_count > 0) self.line_tokens[0].line else self.lexer.line;
    }

    fn fail(self: *const Parser, comptime msg: []const u8) noreturn {
        @compileError(std.fmt.comptimePrint("line {d}: {s}", .{ self.currentLine(), msg }));
    }

    /// Skip the remaining tokens of the current line (for directives that are
    /// intentionally ignored, such as SDCC's .area / .globl / .module).
    fn skipRestOfLine(self: *Parser) void {
        while (!self.atEnd()) _ = self.nextToken();
    }

    /// Value as an 8-bit operand; values outside -128..255 are an error, never truncated.
    fn imm8(self: *const Parser, v: i32) u8 {
        if (v < -128 or v > 255) {
            @compileError(std.fmt.comptimePrint("line {d}: value {d} does not fit in 8 bits", .{ self.currentLine(), v }));
        }
        return @truncate(@as(u32, @bitCast(v)));
    }

    /// Value as a 16-bit operand; values outside -32768..65535 are an error, never truncated.
    fn imm16(self: *const Parser, v: i32) u16 {
        if (v < -32768 or v > 65535) {
            @compileError(std.fmt.comptimePrint("line {d}: value {d} does not fit in 16 bits", .{ self.currentLine(), v }));
        }
        return @truncate(@as(u32, @bitCast(v)));
    }

    // Parse a complete operand from current token position
    fn parseOperand(self: *Parser) Operand {
        var tok = self.peekToken();

        // ( ... ) -- indirect addressing
        if (tok.kind == .lparen) {
            return self.parseIndirect();
        }

        // # immediate prefix (SDCC style)
        if (tok.kind == .hash) {
            _ = self.nextToken(); // consume #
            return self.parseImmediate();
        }

        // $ -- current PC (needs the expression evaluator; reject rather than emit 0)
        if (tok.kind == .dollar) {
            self.fail("'$' (current address) is not supported yet");
        }

        // Number
        if (tok.kind == .number) {
            return self.parseImmediate();
        }

        // Minus sign before number
        if (tok.kind == .minus) {
            _ = self.nextToken(); // consume -
            tok = self.peekToken();
            if (tok.kind == .number) {
                _ = self.nextToken();
                const val = -parseNumber(tok.text);
                if (val >= -128 and val <= 255)
                    return .{ .kind = .imm8, .imm = val }
                else
                    return .{ .kind = .imm16, .imm = val };
            }
            @compileError("expected number after minus sign");
        }

        // Identifier: register or label or condition
        if (tok.kind == .ident) {
            _ = self.nextToken();
            const text = tok.text;

            // Check condition code first (but C is ambiguous -- register or carry)
            // We handle this in instruction-specific code

            // Check register
            const reg = classifyRegister(text);
            if (reg != .none) {
                return switch (reg) {
                    .a, .b, .c, .d, .e, .h, .l => .{ .kind = .reg8, .reg = reg },
                    .bc => .{ .kind = .reg16, .reg = .bc },
                    .de => .{ .kind = .reg16, .reg = .de },
                    .hl => .{ .kind = .reg16, .reg = .hl },
                    .sp => .{ .kind = .reg16, .reg = .sp },
                    .af => .{ .kind = .reg_af, .reg = .af },
                    .af_prime => .{ .kind = .reg_af_prime, .reg = .af_prime },
                    .ix, .iy => .{ .kind = .reg_idx, .reg = reg, .idx = regToIdx(reg) },
                    .i_reg => .{ .kind = .reg_i },
                    .r_reg => .{ .kind = .reg_r },
                    else => .{ .kind = .none },
                };
            }

            // It's a label reference
            return .{ .kind = .label_ref, .label = text };
        }

        return .{ .kind = .none };
    }

    fn parseIndirect(self: *Parser) Operand {
        _ = self.nextToken(); // consume (

        const tok = self.peekToken();

        if (tok.kind == .ident) {
            _ = self.nextToken();
            const reg = classifyRegister(tok.text);

            if (reg == .hl) {
                // (HL)
                self.expectRparen();
                return .{ .kind = .indirect_hl, .reg = .hl_ind };
            }

            if (reg == .bc) {
                self.expectRparen();
                return .{ .kind = .indirect_bc, .reg = .bc };
            }

            if (reg == .de) {
                self.expectRparen();
                return .{ .kind = .indirect_de, .reg = .de };
            }

            if (reg == .c) {
                // (C) -- for IN/OUT
                self.expectRparen();
                return .{ .kind = .indirect_c };
            }

            if (reg == .ix or reg == .iy) {
                const idx = regToIdx(reg).?;
                // Check for +d or -d
                const next_tok = self.peekToken();
                if (next_tok.kind == .plus or next_tok.kind == .minus) {
                    const negative = next_tok.kind == .minus;
                    _ = self.nextToken(); // consume + or -
                    const num_tok = self.nextToken();
                    if (num_tok.kind != .number) self.fail("index displacement must be a number (expressions are not supported yet)");
                    const magnitude = parseNumber(num_tok.text);
                    const d: i32 = if (negative) -magnitude else magnitude;
                    if (d < -128 or d > 127) self.fail("index displacement out of range -128..127");
                    self.expectRparen();
                    return .{ .kind = .indirect_idx, .idx = idx, .displacement = @intCast(d) };
                }
                // (IX) with no displacement means (IX+0)
                self.expectRparen();
                return .{ .kind = .indirect_idx, .idx = idx, .displacement = 0 };
            }

            // (SP) -- used by EX (SP), HL; or any other register not
            // having a dedicated indirect form.
            // Also handles identifiers that aren't registers at all.
            self.expectRparen();
            return .{ .kind = .indirect_nn, .label = tok.text };
        }

        if (tok.kind == .number) {
            _ = self.nextToken();
            const val = parseNumber(tok.text);
            self.expectRparen();
            return .{ .kind = .indirect_nn, .imm = val };
        }

        // # inside parens (SDCC: IN A, (#0x01)) -- unusual but handle it
        if (tok.kind == .hash) {
            _ = self.nextToken(); // consume #
            const num_tok = self.nextToken();
            if (num_tok.kind != .number) self.fail("expected a number after '#'");
            const val = parseNumber(num_tok.text);
            self.expectRparen();
            return .{ .kind = .indirect_nn, .imm = val };
        }

        @compileError("invalid indirect operand");
    }

    fn parseImmediate(self: *Parser) Operand {
        const tok = self.nextToken();
        if (tok.kind == .number) {
            const val = parseNumber(tok.text);
            if (val >= 0 and val <= 255)
                return .{ .kind = .imm8, .imm = val }
            else
                return .{ .kind = .imm16, .imm = val };
        }
        // Could be a label used as immediate
        if (tok.kind == .ident) {
            return .{ .kind = .label_ref, .label = tok.text };
        }
        @compileError("expected number or label for immediate value");
    }

    // ========================================================================
    // Instruction parsing -- main dispatch
    // ========================================================================

    fn parseLine(self: *Parser) void {
        self.readLine();

        // Skip empty lines
        if (self.line_token_count == 0) return;
        var first = self.peekToken();
        if (first.kind == .newline or first.kind == .eof) return;

        // Label definition: identifier followed by : or ::
        if (first.kind == .ident) {
            if (self.line_token_count > 1) {
                const second = self.line_tokens[self.token_pos + 1];
                if (second.kind == .colon or second.kind == .double_colon) {
                    _ = self.nextToken(); // consume label name
                    _ = self.nextToken(); // consume : or ::

                    // Qualify local labels
                    const label_name = self.qualifyLabel(first.text);
                    self.program.label(label_name);

                    // Update scope for non-local labels
                    if (first.text[0] != '.' and !(first.text[0] >= '0' and first.text[0] <= '9')) {
                        self.current_scope = first.text;
                    }

                    // Continue parsing if there's more on this line
                    first = self.peekToken();
                    if (first.kind == .newline or first.kind == .eof) return;
                    // Fall through to instruction parsing
                }
            }
        }

        // SDCC-style label without colon: identifier at column 0 that ends with :
        // Already handled above. Also handle label with :: at end of ident text

        if (first.kind != .ident) {
            @compileError(std.fmt.comptimePrint("line {d}: expected a label or mnemonic, found '{s}'", .{ first.line, first.text }));
        }

        self.parseInstruction();

        // Everything on the line must have been consumed; leftovers mean the
        // parser did not understand part of the statement (e.g. "LD A,2+3").
        if (!self.atEnd()) {
            const extra = self.peekToken();
            @compileError(std.fmt.comptimePrint("line {d}: unexpected '{s}' (expressions are not supported yet)", .{ extra.line, extra.text }));
        }
    }

    fn qualifyLabel(_: *const Parser, name: []const u8) []const u8 {
        // Labels are returned as-is. SDCC local labels (00101$) and
        // dot-prefixed local labels (.loop) use their raw text as the
        // label name. Scoping by prefix could be added later.
        return name;
    }

    fn parseInstruction(self: *Parser) void {
        const mnemonic_tok = self.nextToken();
        if (mnemonic_tok.kind != .ident) self.fail("expected a mnemonic");

        const mnem = mnemonic_tok.text;

        // Directives (starting with .)
        if (mnem[0] == '.') {
            self.parseDirective(mnem);
            return;
        }

        // Main dispatch on mnemonic (case-insensitive)
        if (upperEql(mnem, "NOP")) { self.program.raw(isa.nop()); return; }
        if (upperEql(mnem, "HALT")) { self.program.raw(isa.halt()); return; }
        if (upperEql(mnem, "RET")) { self.parseRet(); return; }
        if (upperEql(mnem, "EI")) { self.program.raw(isa.ei()); return; }
        if (upperEql(mnem, "DI")) { self.program.raw(isa.di()); return; }
        if (upperEql(mnem, "EXX")) { self.program.raw(isa.exx()); return; }
        if (upperEql(mnem, "RLCA")) { self.program.raw(isa.rlca()); return; }
        if (upperEql(mnem, "RRCA")) { self.program.raw(isa.rrca()); return; }
        if (upperEql(mnem, "RLA")) { self.program.raw(isa.rla()); return; }
        if (upperEql(mnem, "RRA")) { self.program.raw(isa.rra()); return; }
        if (upperEql(mnem, "CPL")) { self.program.raw(isa.cpl()); return; }
        if (upperEql(mnem, "SCF")) { self.program.raw(isa.scf()); return; }
        if (upperEql(mnem, "CCF")) { self.program.raw(isa.ccf()); return; }
        if (upperEql(mnem, "DAA")) { self.program.raw(isa.daa()); return; }
        if (upperEql(mnem, "NEG")) { self.program.raw(isa.neg()); return; }
        if (upperEql(mnem, "RETI")) { self.program.raw(isa.reti()); return; }
        if (upperEql(mnem, "RETN")) { self.program.raw(isa.retn()); return; }
        if (upperEql(mnem, "LDIR")) { self.program.raw(isa.ldir()); return; }
        if (upperEql(mnem, "LDDR")) { self.program.raw(isa.lddr()); return; }
        if (upperEql(mnem, "CPIR")) { self.program.raw(isa.cpir()); return; }
        if (upperEql(mnem, "CPDR")) { self.program.raw(isa.cpdr()); return; }
        if (upperEql(mnem, "INIR")) { self.program.raw(isa.inir()); return; }
        if (upperEql(mnem, "OTIR")) { self.program.raw(isa.otir()); return; }

        if (upperEql(mnem, "LD")) { self.parseLd(); return; }
        if (upperEql(mnem, "ADD")) { self.parseAdd(); return; }
        if (upperEql(mnem, "ADC")) { self.parseAdc(); return; }
        if (upperEql(mnem, "SUB")) { self.parseSub(); return; }
        if (upperEql(mnem, "SBC")) { self.parseSbc(); return; }
        if (upperEql(mnem, "AND")) { self.parseAlu(4); return; }
        if (upperEql(mnem, "OR")) { self.parseAlu(6); return; }
        if (upperEql(mnem, "XOR")) { self.parseAlu(5); return; }
        if (upperEql(mnem, "CP")) { self.parseCp(); return; }
        if (upperEql(mnem, "INC")) { self.parseIncDec(true); return; }
        if (upperEql(mnem, "DEC")) { self.parseIncDec(false); return; }
        if (upperEql(mnem, "PUSH")) { self.parsePushPop(true); return; }
        if (upperEql(mnem, "POP")) { self.parsePushPop(false); return; }
        if (upperEql(mnem, "JP")) { self.parseJp(); return; }
        if (upperEql(mnem, "JR")) { self.parseJr(); return; }
        if (upperEql(mnem, "CALL")) { self.parseCall(); return; }
        if (upperEql(mnem, "DJNZ")) { self.parseDjnz(); return; }
        if (upperEql(mnem, "RST")) { self.parseRst(); return; }
        if (upperEql(mnem, "EX")) { self.parseEx(); return; }
        if (upperEql(mnem, "IN")) { self.parseIn(); return; }
        if (upperEql(mnem, "OUT")) { self.parseOut(); return; }
        if (upperEql(mnem, "IM")) { self.parseIm(); return; }
        if (upperEql(mnem, "BIT")) { self.parseBitOp(0); return; }
        if (upperEql(mnem, "SET")) { self.parseBitOp(2); return; }
        if (upperEql(mnem, "RES")) { self.parseBitOp(1); return; }
        if (upperEql(mnem, "RL")) { self.parseShiftRot(0x10); return; }
        if (upperEql(mnem, "RR")) { self.parseShiftRot(0x18); return; }
        if (upperEql(mnem, "RLC")) { self.parseShiftRot(0x00); return; }
        if (upperEql(mnem, "RRC")) { self.parseShiftRot(0x08); return; }
        if (upperEql(mnem, "SLA")) { self.parseShiftRot(0x20); return; }
        if (upperEql(mnem, "SRA")) { self.parseShiftRot(0x28); return; }
        if (upperEql(mnem, "SRL")) { self.parseShiftRot(0x38); return; }

        // SDCC directives without dot
        if (upperEql(mnem, "ORG")) { self.parseDotOrg(); return; }
        if (upperEql(mnem, "DB") or upperEql(mnem, "DEFB")) { self.parseDotDb(); return; }
        if (upperEql(mnem, "DW") or upperEql(mnem, "DEFW")) { self.parseDotDw(); return; }
        if (upperEql(mnem, "EQU")) self.fail("EQU is not supported yet");
        if (upperEql(mnem, "DS") or upperEql(mnem, "DEFS")) { self.parseDotFill(); return; }

        // SDCC-specific directives we can skip
        if (upperEql(mnem, "MODULE") or upperEql(mnem, "OPTSDCC") or
            upperEql(mnem, "GLOBL") or upperEql(mnem, "AREA"))
        {
            self.skipRestOfLine();
            return;
        }

        @compileError("unknown mnemonic: " ++ mnem);
    }

    // ========================================================================
    // Directive parsing
    // ========================================================================

    fn parseDirective(self: *Parser, mnem: []const u8) void {
        if (upperEql(mnem, ".ORG")) { self.parseDotOrg(); return; }
        if (upperEql(mnem, ".DB") or upperEql(mnem, ".BYTE")) { self.parseDotDb(); return; }
        if (upperEql(mnem, ".DW") or upperEql(mnem, ".WORD")) { self.parseDotDw(); return; }
        if (upperEql(mnem, ".ASCII")) { self.parseDotAscii(false); return; }
        if (upperEql(mnem, ".ASCIZ")) { self.parseDotAscii(true); return; }
        if (upperEql(mnem, ".FILL") or upperEql(mnem, ".DS")) { self.parseDotFill(); return; }
        if (upperEql(mnem, ".EQU")) self.fail(".equ is not supported yet");

        // SDCC directives we can ignore
        if (upperEql(mnem, ".MODULE") or upperEql(mnem, ".OPTSDCC") or
            upperEql(mnem, ".GLOBL") or upperEql(mnem, ".AREA"))
        {
            self.skipRestOfLine();
            return;
        }

        @compileError("unknown directive: " ++ mnem);
    }

    fn parseDotOrg(self: *Parser) void {
        const op = self.parseOperand();
        if (op.kind == .imm8 or op.kind == .imm16) {
            self.program.org(self.imm16(op.imm));
        } else {
            @compileError(".org requires a numeric address");
        }
    }

    fn parseDotDb(self: *Parser) void {
        while (!self.atEnd()) {
            const tok = self.peekToken();
            if (tok.kind == .number) {
                _ = self.nextToken();
                self.program.raw(isa.db(self.imm8(parseNumber(tok.text))));
            } else if (tok.kind == .hash) {
                _ = self.nextToken();
                const num_tok = self.nextToken();
                if (num_tok.kind != .number) self.fail("expected a number after '#'");
                self.program.raw(isa.db(self.imm8(parseNumber(num_tok.text))));
            } else if (tok.kind == .string_lit) {
                _ = self.nextToken();
                self.program.data(tok.text);
            } else {
                break;
            }
            if (self.peekToken().kind == .comma) {
                _ = self.nextToken();
            } else {
                break;
            }
        }
    }

    fn parseDotDw(self: *Parser) void {
        while (!self.atEnd()) {
            const tok = self.peekToken();
            if (tok.kind == .number) {
                _ = self.nextToken();
                self.program.raw(isa.dw(self.imm16(parseNumber(tok.text))));
            } else if (tok.kind == .hash) {
                _ = self.nextToken();
                const num_tok = self.nextToken();
                if (num_tok.kind != .number) self.fail("expected a number after '#'");
                self.program.raw(isa.dw(self.imm16(parseNumber(num_tok.text))));
            } else if (tok.kind == .ident) {
                // Used to emit a placeholder 0 -- silently wrong. Reject until labels in DW are supported.
                self.fail("DW with a label is not supported yet");
            } else {
                break;
            }
            if (self.peekToken().kind == .comma) {
                _ = self.nextToken();
            } else {
                break;
            }
        }
    }

    fn parseDotAscii(self: *Parser, null_terminate: bool) void {
        const tok = self.nextToken();
        if (tok.kind == .string_lit) {
            self.program.data(tok.text);
            if (null_terminate) {
                self.program.raw(isa.db(0));
            }
        } else {
            @compileError(".ascii/.asciz expects a string literal");
        }
    }

    fn parseDotFill(self: *Parser) void {
        const count_tok = self.nextToken();
        if (count_tok.kind != .number) self.fail("DS/.fill count must be a number");
        const count: usize = self.imm16(parseNumber(count_tok.text));
        var fill_val: u8 = 0;
        if (self.peekToken().kind == .comma) {
            _ = self.nextToken();
            const val_tok = self.nextToken();
            if (val_tok.kind != .number) self.fail("DS/.fill value must be a number");
            fill_val = self.imm8(parseNumber(val_tok.text));
        }
        // Emit 'count' bytes of fill_val
        for (0..count) |_| {
            self.program.raw(isa.db(fill_val));
        }
    }

    // ========================================================================
    // LD instruction parsing (the big one)
    // ========================================================================

    fn parseLd(self: *Parser) void {
        const dst = self.parseOperand();
        self.expectComma();
        const src = self.parseOperand();

        // LD r8, r8 | LD r8, (HL)
        if (dst.kind == .reg8 and (src.kind == .reg8 or src.kind == .indirect_hl)) {
            const d = regToR8(dst.reg).?;
            const s = regToR8(src.reg).?;
            self.program.raw(isa.ld_r_r(d, s));
            return;
        }

        // LD (HL), r8
        if (dst.kind == .indirect_hl and src.kind == .reg8) {
            const s = regToR8(src.reg).?;
            self.program.raw(isa.ld_r_r(.hl_ind, s));
            return;
        }

        // LD r8, n
        if (dst.kind == .reg8 and (src.kind == .imm8 or src.kind == .imm16)) {
            const d = regToR8(dst.reg).?;
            self.program.raw(isa.ld_r_n(d, self.imm8(src.imm)));
            return;
        }

        // LD (HL), n
        if (dst.kind == .indirect_hl and (src.kind == .imm8 or src.kind == .imm16)) {
            self.program.raw(isa.ld_hl_ind_n(self.imm8(src.imm)));
            return;
        }

        // LD r16, nn
        if (dst.kind == .reg16 and (src.kind == .imm8 or src.kind == .imm16)) {
            const d = regToR16(dst.reg).?;
            self.program.raw(isa.ld_rr_nn(d, self.imm16(src.imm)));
            return;
        }

        // LD r16, label
        if (dst.kind == .reg16 and src.kind == .label_ref) {
            const d = regToR16(dst.reg).?;
            self.program.ld_rr_label(d, src.label);
            return;
        }

        // LD IX/IY, nn
        if (dst.kind == .reg_idx and (src.kind == .imm8 or src.kind == .imm16)) {
            self.program.raw(isa.ld_idx_nn(dst.idx.?, self.imm16(src.imm)));
            return;
        }

        // LD SP, HL
        if (dst.kind == .reg16 and dst.reg == .sp and src.kind == .reg16 and src.reg == .hl) {
            self.program.raw(isa.ld_sp_hl());
            return;
        }

        // LD SP, IX/IY
        if (dst.kind == .reg16 and dst.reg == .sp and src.kind == .reg_idx) {
            self.program.raw(isa.ld_sp_idx(src.idx.?));
            return;
        }

        // LD A, (BC)
        if (dst.kind == .reg8 and dst.reg == .a and src.kind == .indirect_bc) {
            self.program.raw(isa.ld_a_bc_ind());
            return;
        }

        // LD A, (DE)
        if (dst.kind == .reg8 and dst.reg == .a and src.kind == .indirect_de) {
            self.program.raw(isa.ld_a_de_ind());
            return;
        }

        // LD (BC), A
        if (dst.kind == .indirect_bc and src.kind == .reg8 and src.reg == .a) {
            self.program.raw(isa.ld_bc_ind_a());
            return;
        }

        // LD (DE), A
        if (dst.kind == .indirect_de and src.kind == .reg8 and src.reg == .a) {
            self.program.raw(isa.ld_de_ind_a());
            return;
        }

        // LD A, (nn)
        if (dst.kind == .reg8 and dst.reg == .a and src.kind == .indirect_nn and src.label.len == 0) {
            self.program.raw(isa.ld_a_nn_ind(self.imm16(src.imm)));
            return;
        }

        // LD A, (label)
        if (dst.kind == .reg8 and dst.reg == .a and src.kind == .indirect_nn and src.label.len > 0) {
            // LD A, (nn) = opcode 0x3A
            self.program.emit(.{ .label_abs16 = .{ .opcode = 0x3A, .label = src.label } });
            return;
        }

        // LD (nn), A
        if (dst.kind == .indirect_nn and dst.label.len == 0 and src.kind == .reg8 and src.reg == .a) {
            self.program.raw(isa.ld_nn_ind_a(self.imm16(dst.imm)));
            return;
        }

        // LD (label), A
        if (dst.kind == .indirect_nn and dst.label.len > 0 and src.kind == .reg8 and src.reg == .a) {
            self.program.emit(.{ .label_abs16 = .{ .opcode = 0x32, .label = dst.label } });
            return;
        }

        // LD HL, (nn)
        if (dst.kind == .reg16 and dst.reg == .hl and src.kind == .indirect_nn and src.label.len == 0) {
            self.program.raw(isa.ld_hl_nn_ind(self.imm16(src.imm)));
            return;
        }

        // LD HL, (label)
        if (dst.kind == .reg16 and dst.reg == .hl and src.kind == .indirect_nn and src.label.len > 0) {
            self.program.emit(.{ .label_abs16 = .{ .opcode = 0x2A, .label = src.label } });
            return;
        }

        // LD (nn), HL
        if (dst.kind == .indirect_nn and dst.label.len == 0 and src.kind == .reg16 and src.reg == .hl) {
            self.program.raw(isa.ld_nn_ind_hl(self.imm16(dst.imm)));
            return;
        }

        // LD (label), HL
        if (dst.kind == .indirect_nn and dst.label.len > 0 and src.kind == .reg16 and src.reg == .hl) {
            self.program.emit(.{ .label_abs16 = .{ .opcode = 0x22, .label = dst.label } });
            return;
        }

        // LD rr, (nn) -- ED prefix for BC, DE, SP
        if (dst.kind == .reg16 and src.kind == .indirect_nn and src.label.len == 0) {
            const d = regToR16(dst.reg).?;
            self.program.raw(isa.ld_rr_nn_ind(d, self.imm16(src.imm)));
            return;
        }

        // LD (nn), rr
        if (dst.kind == .indirect_nn and dst.label.len == 0 and src.kind == .reg16) {
            const s = regToR16(src.reg).?;
            self.program.raw(isa.ld_nn_ind_rr(self.imm16(dst.imm), s));
            return;
        }

        // LD r, (IX+d) / (IY+d)
        if (dst.kind == .reg8 and src.kind == .indirect_idx) {
            const d = regToR8(dst.reg).?;
            self.program.raw(isa.ld_r_idx_d(d, src.idx.?, src.displacement));
            return;
        }

        // LD (IX+d), r / (IY+d), r
        if (dst.kind == .indirect_idx and src.kind == .reg8) {
            const s = regToR8(src.reg).?;
            self.program.raw(isa.ld_idx_d_r(dst.idx.?, dst.displacement, s));
            return;
        }

        // LD (IX+d), n / (IY+d), n
        if (dst.kind == .indirect_idx and (src.kind == .imm8 or src.kind == .imm16)) {
            self.program.raw(isa.ld_idx_d_n(dst.idx.?, dst.displacement, self.imm8(src.imm)));
            return;
        }

        // LD I, A
        if (dst.kind == .reg_i and src.kind == .reg8 and src.reg == .a) {
            self.program.raw(isa.ld_i_a());
            return;
        }

        // LD A, I
        if (dst.kind == .reg8 and dst.reg == .a and src.kind == .reg_i) {
            self.program.raw(isa.ld_a_i());
            return;
        }

        @compileError("invalid LD operand combination");
    }

    // ========================================================================
    // ALU: ADD, ADC, SUB, SBC, AND, OR, XOR, CP
    // ========================================================================

    fn parseAdd(self: *Parser) void {
        const first = self.parseOperand();

        // ADD A, ... or just ADD r (implicit A)
        if (first.kind == .reg8 and first.reg == .a) {
            if (self.peekToken().kind == .comma) {
                self.expectComma();
                const src = self.parseOperand();
                self.emitAlu8(0, src);
                return;
            }
            // ADD A alone? That's weird but treat as ADD A, A
            self.program.raw(isa.add_a_r(.a));
            return;
        }

        // ADD HL, rr
        if (first.kind == .reg16 and first.reg == .hl) {
            self.expectComma();
            const src = self.parseOperand();
            if (src.kind == .reg16) {
                self.program.raw(isa.add_hl_rr(regToR16(src.reg).?));
                return;
            }
            @compileError("ADD HL requires 16-bit register source");
        }

        // ADD IX/IY, rr
        if (first.kind == .reg_idx) {
            self.expectComma();
            const src = self.parseOperand();
            if (src.kind == .reg16) {
                self.program.raw(isa.add_idx_rr(first.idx.?, regToR16(src.reg).?));
                return;
            }
            @compileError("ADD IX/IY requires 16-bit register source");
        }

        // ADD r (implicit A as destination, SDCC style)
        self.emitAlu8(0, first);
    }

    fn parseAdc(self: *Parser) void {
        const first = self.parseOperand();

        // ADC A, ...
        if (first.kind == .reg8 and first.reg == .a) {
            if (self.peekToken().kind == .comma) {
                self.expectComma();
                const src = self.parseOperand();
                self.emitAlu8(1, src);
                return;
            }
            self.program.raw(isa.adc_a_r(.a));
            return;
        }

        // ADC HL, rr
        if (first.kind == .reg16 and first.reg == .hl) {
            self.expectComma();
            const src = self.parseOperand();
            if (src.kind == .reg16) {
                self.program.raw(isa.adc_hl_rr(regToR16(src.reg).?));
                return;
            }
            @compileError("ADC HL requires 16-bit register source");
        }

        // ADC r (implicit A)
        self.emitAlu8(1, first);
    }

    fn parseSub(self: *Parser) void {
        const first = self.parseOperand();

        // SUB A, ... (some assemblers use explicit A)
        if (first.kind == .reg8 and first.reg == .a and self.peekToken().kind == .comma) {
            self.expectComma();
            const src = self.parseOperand();
            self.emitAlu8(2, src);
            return;
        }

        // SUB r / SUB n / SUB (HL) etc
        self.emitAlu8(2, first);
    }

    fn parseSbc(self: *Parser) void {
        const first = self.parseOperand();

        // SBC A, ...
        if (first.kind == .reg8 and first.reg == .a) {
            if (self.peekToken().kind == .comma) {
                self.expectComma();
                const src = self.parseOperand();
                self.emitAlu8(3, src);
                return;
            }
            self.program.raw(isa.sbc_a_r(.a));
            return;
        }

        // SBC HL, rr
        if (first.kind == .reg16 and first.reg == .hl) {
            self.expectComma();
            const src = self.parseOperand();
            if (src.kind == .reg16) {
                self.program.raw(isa.sbc_hl_rr(regToR16(src.reg).?));
                return;
            }
            @compileError("SBC HL requires 16-bit register source");
        }

        // SBC r (implicit A)
        self.emitAlu8(3, first);
    }

    fn parseCp(self: *Parser) void {
        const first = self.parseOperand();

        // CP A, ... (explicit A as in some assemblers)
        if (first.kind == .reg8 and first.reg == .a and self.peekToken().kind == .comma) {
            self.expectComma();
            const src = self.parseOperand();
            self.emitAlu8(7, src);
            return;
        }

        // CP r / CP n / CP (HL)
        self.emitAlu8(7, first);
    }

    fn parseAlu(self: *Parser, op: u3) void {
        const first = self.parseOperand();

        // AND A, ... / OR A, ... / XOR A, ... (explicit A -- SDCC style)
        if (first.kind == .reg8 and first.reg == .a and self.peekToken().kind == .comma) {
            self.expectComma();
            const src = self.parseOperand();
            self.emitAlu8(op, src);
            return;
        }

        // AND/OR/XOR r (implicit A)
        self.emitAlu8(op, first);
    }

    fn emitAlu8(self: *Parser, op: u3, src: Operand) void {
        if (src.kind == .reg8 or src.kind == .indirect_hl) {
            const s = regToR8(src.reg).?;
            switch (op) {
                0 => self.program.raw(isa.add_a_r(s)),
                1 => self.program.raw(isa.adc_a_r(s)),
                2 => self.program.raw(isa.sub_r(s)),
                3 => self.program.raw(isa.sbc_a_r(s)),
                4 => self.program.raw(isa.and_r(s)),
                5 => self.program.raw(isa.xor_r(s)),
                6 => self.program.raw(isa.or_r(s)),
                7 => self.program.raw(isa.cp_r(s)),
            }
            return;
        }

        if (src.kind == .imm8 or src.kind == .imm16) {
            const n: u8 = self.imm8(src.imm);
            switch (op) {
                0 => self.program.raw(isa.add_a_n(n)),
                1 => self.program.raw(isa.adc_a_n(n)),
                2 => self.program.raw(isa.sub_n(n)),
                3 => self.program.raw(isa.sbc_a_n(n)),
                4 => self.program.raw(isa.and_n(n)),
                5 => self.program.raw(isa.xor_n(n)),
                6 => self.program.raw(isa.or_n(n)),
                7 => self.program.raw(isa.cp_n(n)),
            }
            return;
        }

        if (src.kind == .indirect_idx) {
            // ALU A, (IX+d) / (IY+d) -- encoded as DD/FD CB dd op
            // These use a different encoding in z80isa. Since z80isa doesn't
            // have alu_idx_d yet, we emit the bytes directly.
            const prefix: u8 = if (src.idx.? == .ix) 0xDD else 0xFD;
            const base: u8 = 0x86 + (@as(u8, op) << 3); // 86, 8E, 96, 9E, A6, AE, B6, BE
            self.program.raw(.{ .bytes = .{ prefix, base, @bitCast(src.displacement), 0 }, .len = 3 });
            return;
        }

        @compileError("invalid ALU operand");
    }

    // ========================================================================
    // INC / DEC
    // ========================================================================

    fn parseIncDec(self: *Parser, is_inc: bool) void {
        const op = self.parseOperand();

        // INC/DEC r8
        if (op.kind == .reg8 or op.kind == .indirect_hl) {
            const r = regToR8(op.reg).?;
            if (is_inc) self.program.raw(isa.inc_r(r)) else self.program.raw(isa.dec_r(r));
            return;
        }

        // INC/DEC r16
        if (op.kind == .reg16) {
            const rr = regToR16(op.reg).?;
            if (is_inc) self.program.raw(isa.inc_rr(rr)) else self.program.raw(isa.dec_rr(rr));
            return;
        }

        // INC/DEC IX/IY -- not in z80isa yet, but the encoding is DD/FD 23/2B
        if (op.kind == .reg_idx) {
            const prefix = if (op.idx.? == .ix) @as(u8, 0xDD) else @as(u8, 0xFD);
            const opc: u8 = if (is_inc) 0x23 else 0x2B;
            self.program.raw(.{ .bytes = .{ prefix, opc, 0, 0 }, .len = 2 });
            return;
        }

        // INC/DEC (IX+d) / (IY+d)
        if (op.kind == .indirect_idx) {
            const prefix = if (op.idx.? == .ix) @as(u8, 0xDD) else @as(u8, 0xFD);
            const opc: u8 = if (is_inc) 0x34 else 0x35;
            self.program.raw(.{ .bytes = .{ prefix, opc, @bitCast(op.displacement), 0 }, .len = 3 });
            return;
        }

        @compileError("invalid INC/DEC operand");
    }

    // ========================================================================
    // PUSH / POP
    // ========================================================================

    fn parsePushPop(self: *Parser, is_push: bool) void {
        const op = self.parseOperand();

        if (op.kind == .reg16 or op.kind == .reg_af) {
            if (regToR16af(op.reg)) |rr| {
                if (is_push) self.program.raw(isa.push(rr)) else self.program.raw(isa.pop(rr));
                return;
            }
        }

        if (op.kind == .reg_idx) {
            if (is_push) self.program.raw(isa.push_idx(op.idx.?)) else self.program.raw(isa.pop_idx(op.idx.?));
            return;
        }

        @compileError("invalid PUSH/POP operand");
    }

    // ========================================================================
    // JP, JR, CALL, DJNZ, RST
    // ========================================================================

    fn parseJp(self: *Parser) void {
        const first = self.parseOperand();

        // JP (HL)
        if (first.kind == .indirect_hl) {
            self.program.raw(isa.jp_hl());
            return;
        }

        // JP (IX) / JP (IY)
        if (first.kind == .indirect_idx) {
            self.program.raw(isa.jp_idx(first.idx.?));
            return;
        }

        // JP nn
        if (first.kind == .imm8 or first.kind == .imm16) {
            self.program.raw(isa.jp(self.imm16(first.imm)));
            return;
        }

        // Check for condition code BEFORE treating as label.
        // JP cc, target -- condition codes: NZ, Z, NC, C, PO, PE, P, M
        // "C" is parsed as reg8 .c, others as label_ref
        if (self.peekToken().kind == .comma) {
            const cc = self.extractCc(first);
            if (cc) |cond| {
                self.expectComma();
                const target = self.parseOperand();
                if (target.kind == .label_ref) {
                    self.program.jp_cc_label(cond, target.label);
                    return;
                }
                if (target.kind == .imm8 or target.kind == .imm16) {
                    self.program.raw(isa.jp_cc(cond, self.imm16(target.imm)));
                    return;
                }
                @compileError("JP cc requires address or label");
            }
        }

        // JP label
        if (first.kind == .label_ref) {
            self.program.jp_label(first.label);
            return;
        }

        @compileError("invalid JP operand");
    }

    fn parseJr(self: *Parser) void {
        const first = self.parseOperand();

        // A numeric JR operand is a target address in Zilog and SDCC syntax, not a raw
        // offset. It used to be emitted as an offset (wrong bytes); reject until the
        // address-to-offset conversion exists.
        if (first.kind == .imm8 or first.kind == .imm16) {
            self.fail("JR with a numeric target is not supported yet; use a label");
        }

        // Check for condition code BEFORE treating as label.
        if (self.peekToken().kind == .comma) {
            const cc = self.extractCc(first);
            if (cc) |cond| {
                self.expectComma();
                const target = self.parseOperand();
                if (target.kind == .label_ref) {
                    self.program.jr_cc_label(cond, target.label);
                    return;
                }
                if (target.kind == .imm8 or target.kind == .imm16) {
                    self.fail("JR cc with a numeric target is not supported yet; use a label");
                }
                @compileError("JR cc requires a label");
            }
        }

        // JR label
        if (first.kind == .label_ref) {
            self.program.jr_label(first.label);
            return;
        }

        @compileError("invalid JR operand");
    }

    fn parseCall(self: *Parser) void {
        const first = self.parseOperand();

        // CALL nn
        if (first.kind == .imm8 or first.kind == .imm16) {
            self.program.raw(isa.call(self.imm16(first.imm)));
            return;
        }

        // Check for condition code BEFORE treating as label.
        if (self.peekToken().kind == .comma) {
            const cc = self.extractCc(first);
            if (cc) |cond| {
                self.expectComma();
                const target = self.parseOperand();
                if (target.kind == .label_ref) {
                    self.program.call_cc_label(cond, target.label);
                    return;
                }
                if (target.kind == .imm8 or target.kind == .imm16) {
                    self.program.raw(isa.call_cc(cond, self.imm16(target.imm)));
                    return;
                }
                @compileError("CALL cc requires address or label");
            }
        }

        // CALL label
        if (first.kind == .label_ref) {
            self.program.call_label(first.label);
            return;
        }

        @compileError("invalid CALL operand");
    }

    fn parseRet(self: *Parser) void {
        if (self.atEnd()) {
            self.program.raw(isa.ret());
            return;
        }

        // RET cc
        const cond = self.parseOperand();
        const cc = self.extractCc(cond);
        if (cc) |c| {
            self.program.raw(isa.ret_cc(c));
            return;
        }
        @compileError("invalid RET condition");
    }

    // Helper: extract condition code from an operand that may have been
    // parsed as a label_ref (NZ, Z, NC, PO, PE, P, M) or reg8 (C).
    fn extractCc(self: *const Parser, op: Operand) ?isa.Cc {
        _ = self;
        if (op.kind == .label_ref) {
            return classifyCc(op.label);
        }
        if (op.kind == .reg8 and op.reg == .c) {
            return .cy; // "C" register doubles as carry condition
        }
        return null;
    }

    fn parseDjnz(self: *Parser) void {
        const target = self.parseOperand();
        if (target.kind == .label_ref) {
            self.program.djnz_label(target.label);
            return;
        }
        if (target.kind == .imm8 or target.kind == .imm16) {
            self.fail("DJNZ with a numeric target is not supported yet; use a label");
        }
        @compileError("DJNZ requires a label");
    }

    fn parseRst(self: *Parser) void {
        const op = self.parseOperand();
        if (op.kind == .imm8 or op.kind == .imm16) {
            const n: u8 = self.imm8(op.imm);
            // RST n encodes as C7 | n, where n is 0x00, 0x08, 0x10, ..., 0x38
            if (n & 0xC7 != 0) self.fail("RST target must be one of 0x00, 0x08, ..., 0x38");
            self.program.raw(isa.rst(n));
            return;
        }
        @compileError("RST requires numeric argument");
    }

    // ========================================================================
    // EX
    // ========================================================================

    fn parseEx(self: *Parser) void {
        const first = self.parseOperand();

        // EX DE, HL
        if (first.kind == .reg16 and first.reg == .de) {
            self.expectComma();
            const second = self.parseOperand();
            if (second.kind == .reg16 and second.reg == .hl) {
                self.program.raw(isa.ex_de_hl());
                return;
            }
            @compileError("EX DE requires HL as second operand");
        }

        // EX AF, AF'
        if (first.kind == .reg_af) {
            self.expectComma();
            const second = self.parseOperand();
            if (second.kind == .reg_af_prime) {
                self.program.raw(isa.ex_af());
                return;
            }
            @compileError("EX AF requires AF' as second operand");
        }

        // EX (SP), HL
        if (first.kind == .indirect_nn and first.label.len > 0) {
            // Could be (SP) parsed as indirect with label "SP"
            if (upperEql(first.label, "SP")) {
                self.expectComma();
                const second = self.parseOperand();
                if (second.kind == .reg16 and second.reg == .hl) {
                    self.program.raw(isa.ex_sp_hl());
                    return;
                }
                if (second.kind == .reg_idx) {
                    self.program.raw(isa.ex_sp_idx(second.idx.?));
                    return;
                }
                @compileError("EX (SP) requires HL, IX, or IY");
            }
        }

        @compileError("invalid EX operand combination");
    }

    // ========================================================================
    // IN / OUT
    // ========================================================================

    fn parseIn(self: *Parser) void {
        const first = self.parseOperand();

        // IN A, (n)
        if (first.kind == .reg8 and first.reg == .a) {
            self.expectComma();
            const src = self.parseOperand();
            if (src.kind == .indirect_nn and src.label.len == 0) {
                self.program.raw(isa.in_a_n(self.imm8(src.imm)));
                return;
            }
            if (src.kind == .indirect_c) {
                self.program.raw(isa.in_r_c(.a));
                return;
            }
            @compileError("IN A requires (n) or (C)");
        }

        // IN r, (C)
        if (first.kind == .reg8) {
            self.expectComma();
            const src = self.parseOperand();
            if (src.kind == .indirect_c) {
                self.program.raw(isa.in_r_c(regToR8(first.reg).?));
                return;
            }
            @compileError("IN r requires (C)");
        }

        @compileError("invalid IN operand");
    }

    fn parseOut(self: *Parser) void {
        const first = self.parseOperand();

        // OUT (n), A
        if (first.kind == .indirect_nn and first.label.len == 0) {
            self.expectComma();
            const src = self.parseOperand();
            if (src.kind == .reg8 and src.reg == .a) {
                self.program.raw(isa.out_n_a(self.imm8(first.imm)));
                return;
            }
            @compileError("OUT (n) requires A as source");
        }

        // OUT (C), r
        if (first.kind == .indirect_c) {
            self.expectComma();
            const src = self.parseOperand();
            if (src.kind == .reg8) {
                self.program.raw(isa.out_c_r(regToR8(src.reg).?));
                return;
            }
            @compileError("OUT (C) requires register source");
        }

        @compileError("invalid OUT operand");
    }

    // ========================================================================
    // IM
    // ========================================================================

    fn parseIm(self: *Parser) void {
        const op = self.parseOperand();
        if (op.kind == .imm8 or op.kind == .imm16) {
            switch (op.imm) {
                0 => self.program.raw(isa.im0()),
                1 => self.program.raw(isa.im1()),
                2 => self.program.raw(isa.im2()),
                else => @compileError("IM requires 0, 1, or 2"),
            }
            return;
        }
        @compileError("IM requires numeric argument");
    }

    // ========================================================================
    // BIT, SET, RES
    // ========================================================================

    fn parseBitOp(self: *Parser, kind: u2) void {
        // BIT/SET/RES b, r
        const bit_op = self.parseOperand();
        self.expectComma();
        const reg_op = self.parseOperand();

        if ((bit_op.kind != .imm8 and bit_op.kind != .imm16) or bit_op.imm < 0 or bit_op.imm > 7) {
            @compileError("BIT/SET/RES requires bit number 0-7");
        }

        const b: u3 = @intCast(bit_op.imm);

        if (reg_op.kind == .reg8 or reg_op.kind == .indirect_hl) {
            const r = regToR8(reg_op.reg).?;
            switch (kind) {
                0 => self.program.raw(isa.bit_op(b, r)),
                1 => self.program.raw(isa.res_op(b, r)),
                2 => self.program.raw(isa.set_op(b, r)),
                3 => unreachable,
            }
            return;
        }

        // BIT/SET/RES b, (IX+d) / (IY+d) -- DDCB/FDCB prefix
        if (reg_op.kind == .indirect_idx) {
            const prefix: u8 = if (reg_op.idx.? == .ix) 0xDD else 0xFD;
            const base: u8 = switch (kind) {
                0 => 0x46, // BIT
                1 => 0x86, // RES
                2 => 0xC6, // SET
                3 => unreachable,
            };
            const opcode: u8 = base | (@as(u8, b) << 3);
            self.program.raw(.{ .bytes = .{ prefix, 0xCB, @bitCast(reg_op.displacement), opcode }, .len = 4 });
            return;
        }

        @compileError("invalid BIT/SET/RES operand");
    }

    // ========================================================================
    // Shift/Rotate: RL, RR, RLC, RRC, SLA, SRA, SRL
    // ========================================================================

    fn parseShiftRot(self: *Parser, base_op: u8) void {
        const op = self.parseOperand();

        if (op.kind == .reg8 or op.kind == .indirect_hl) {
            const r = regToR8(op.reg).?;
            self.program.raw(.{ .bytes = .{ 0xCB, base_op | @as(u8, @intFromEnum(r)), 0, 0 }, .len = 2 });
            return;
        }

        // (IX+d) / (IY+d)
        if (op.kind == .indirect_idx) {
            const prefix: u8 = if (op.idx.? == .ix) 0xDD else 0xFD;
            // DDCB dd op (where op = base_op | 6 for (IX+d))
            self.program.raw(.{ .bytes = .{ prefix, 0xCB, @bitCast(op.displacement), base_op | 0x06 }, .len = 4 });
            return;
        }

        @compileError("invalid shift/rotate operand");
    }
};

// ============================================================================
// Public API
// ============================================================================

/// Assemble Z80 assembly text at compile time, producing a fixed-size byte array.
///
/// Parameters:
///   source    - Z80 assembly source text (multiline string)
///   base_addr - base address for code generation
///   max_size  - size of the output byte array
///
/// Returns: [max_size]u8 containing the assembled machine code.
///
/// Example:
///   const code = comptime z80parse.assemble(
///       \\  LD SP, #0xFEF0
///       \\  CALL main
///       \\  HALT
///       \\main:
///       \\  RET
///   , 0x0000, 16);
pub fn assemble(comptime source: []const u8, comptime base_addr: u16, comptime max_size: usize) [max_size]u8 {
    @setEvalBranchQuota(10000000);
    comptime {
        var program = za.Program{};
        var parser = Parser.init(source, &program);

        // Parse all lines
        while (parser.lexer.pos < parser.lexer.src.len) {
            parser.parseLine();
        }

        // Assemble using two-pass label resolution
        return program.assemble(base_addr, max_size);
    }
}

// ============================================================================
// Tests
// ============================================================================

const std = @import("std");
const expect = std.testing.expect;

test "basic instructions" {
    const code = comptime assemble(
        \\  NOP
        \\  HALT
        \\  RET
    , 0, 3);
    try expect(code[0] == 0x00); // NOP
    try expect(code[1] == 0x76); // HALT
    try expect(code[2] == 0xC9); // RET
}

test "LD and CALL with labels" {
    const code = comptime assemble(
        \\  LD SP, #0xFEF0
        \\  CALL main
        \\  HALT
        \\main:
        \\  LD A, #0x42
        \\  RET
    , 0x0000, 16);
    try expect(code[0] == 0x31); // LD SP, nn
    try expect(code[1] == 0xF0); // lo
    try expect(code[2] == 0xFE); // hi
    try expect(code[3] == 0xCD); // CALL
    try expect(code[4] == 0x07); // target lo (main is at offset 7)
    try expect(code[5] == 0x00); // target hi
    try expect(code[6] == 0x76); // HALT
    try expect(code[7] == 0x3E); // LD A, n
    try expect(code[8] == 0x42); // immediate
    try expect(code[9] == 0xC9); // RET
}

test "conditional jumps" {
    const code = comptime assemble(
        \\loop:
        \\  DEC B
        \\  JR NZ, loop
    , 0x0100, 4);
    try expect(code[0] == 0x05); // DEC B
    try expect(code[1] == 0x20); // JR NZ
    try expect(code[2] == 0xFD); // offset -3
}

test "LD register variants" {
    const code = comptime assemble(
        \\  LD A, B
        \\  LD C, D
        \\  LD H, L
        \\  LD A, (HL)
        \\  LD (HL), E
    , 0, 5);
    try expect(code[0] == 0x78); // LD A, B
    try expect(code[1] == 0x4A); // LD C, D
    try expect(code[2] == 0x65); // LD H, L
    try expect(code[3] == 0x7E); // LD A, (HL)
    try expect(code[4] == 0x73); // LD (HL), E
}

test "16-bit LD" {
    const code = comptime assemble(
        \\  LD BC, #0x1234
        \\  LD DE, #0x5678
        \\  LD HL, #0x9ABC
    , 0, 9);
    try expect(code[0] == 0x01); // LD BC, nn
    try expect(code[1] == 0x34);
    try expect(code[2] == 0x12);
    try expect(code[3] == 0x11); // LD DE, nn
    try expect(code[4] == 0x78);
    try expect(code[5] == 0x56);
    try expect(code[6] == 0x21); // LD HL, nn
    try expect(code[7] == 0xBC);
    try expect(code[8] == 0x9A);
}

test "PUSH POP" {
    const code = comptime assemble(
        \\  PUSH BC
        \\  PUSH DE
        \\  PUSH HL
        \\  PUSH AF
        \\  POP AF
        \\  POP HL
        \\  POP DE
        \\  POP BC
    , 0, 8);
    try expect(code[0] == 0xC5); // PUSH BC
    try expect(code[1] == 0xD5); // PUSH DE
    try expect(code[2] == 0xE5); // PUSH HL
    try expect(code[3] == 0xF5); // PUSH AF
    try expect(code[4] == 0xF1); // POP AF
    try expect(code[5] == 0xE1); // POP HL
    try expect(code[6] == 0xD1); // POP DE
    try expect(code[7] == 0xC1); // POP BC
}

test "ALU operations" {
    const code = comptime assemble(
        \\  ADD A, B
        \\  SUB C
        \\  AND D
        \\  OR E
        \\  XOR H
        \\  CP L
        \\  ADD A, #0x42
        \\  CP #0xFF
    , 0, 10);
    try expect(code[0] == 0x80); // ADD A, B
    try expect(code[1] == 0x91); // SUB C
    try expect(code[2] == 0xA2); // AND D
    try expect(code[3] == 0xB3); // OR E
    try expect(code[4] == 0xAC); // XOR H
    try expect(code[5] == 0xBD); // CP L
    try expect(code[6] == 0xC6); // ADD A, n
    try expect(code[7] == 0x42);
    try expect(code[8] == 0xFE); // CP n
    try expect(code[9] == 0xFF);
}

test "INC DEC" {
    const code = comptime assemble(
        \\  INC A
        \\  DEC B
        \\  INC HL
        \\  DEC BC
    , 0, 4);
    try expect(code[0] == 0x3C); // INC A
    try expect(code[1] == 0x05); // DEC B
    try expect(code[2] == 0x23); // INC HL
    try expect(code[3] == 0x0B); // DEC BC
}

test "I/O instructions" {
    const code = comptime assemble(
        \\  IN A, (0x42)
        \\  OUT (0x01), A
        \\  IN A, (C)
        \\  OUT (C), A
    , 0, 8);
    try expect(code[0] == 0xDB); // IN A, (n)
    try expect(code[1] == 0x42);
    try expect(code[2] == 0xD3); // OUT (n), A
    try expect(code[3] == 0x01);
    try expect(code[4] == 0xED); // IN A, (C)
    try expect(code[5] == 0x78);
    try expect(code[6] == 0xED); // OUT (C), A
    try expect(code[7] == 0x79);
}

test "IX/IY instructions" {
    const code = comptime assemble(
        \\  LD IX, #0x1234
        \\  PUSH IX
        \\  POP IY
    , 0, 8);
    try expect(code[0] == 0xDD); // IX prefix
    try expect(code[1] == 0x21); // LD IX, nn
    try expect(code[2] == 0x34);
    try expect(code[3] == 0x12);
    try expect(code[4] == 0xDD); // PUSH IX
    try expect(code[5] == 0xE5);
    try expect(code[6] == 0xFD); // POP IY
    try expect(code[7] == 0xE1);
}

test "EX instructions" {
    const code = comptime assemble(
        \\  EX DE, HL
        \\  EX AF, AF'
        \\  EXX
    , 0, 3);
    try expect(code[0] == 0xEB); // EX DE, HL
    try expect(code[1] == 0x08); // EX AF, AF'
    try expect(code[2] == 0xD9); // EXX
}

test "block instructions" {
    const code = comptime assemble(
        \\  LDIR
        \\  LDDR
        \\  CPIR
        \\  CPDR
    , 0, 8);
    try expect(code[0] == 0xED);
    try expect(code[1] == 0xB0); // LDIR
    try expect(code[2] == 0xED);
    try expect(code[3] == 0xB8); // LDDR
    try expect(code[4] == 0xED);
    try expect(code[5] == 0xB1); // CPIR
    try expect(code[6] == 0xED);
    try expect(code[7] == 0xB9); // CPDR
}

test "bit operations" {
    const code = comptime assemble(
        \\  BIT 3, A
        \\  SET 7, B
        \\  RES 0, C
    , 0, 6);
    try expect(code[0] == 0xCB);
    try expect(code[1] == 0x5F); // BIT 3, A
    try expect(code[2] == 0xCB);
    try expect(code[3] == 0xF8); // SET 7, B
    try expect(code[4] == 0xCB);
    try expect(code[5] == 0x81); // RES 0, C
}

test "shift rotate" {
    const code = comptime assemble(
        \\  RL A
        \\  RR B
        \\  SLA C
        \\  SRA D
        \\  SRL E
    , 0, 10);
    try expect(code[0] == 0xCB);
    try expect(code[1] == 0x17); // RL A
    try expect(code[2] == 0xCB);
    try expect(code[3] == 0x18); // RR B
    try expect(code[4] == 0xCB);
    try expect(code[5] == 0x21); // SLA C
    try expect(code[6] == 0xCB);
    try expect(code[7] == 0x2A); // SRA D
    try expect(code[8] == 0xCB);
    try expect(code[9] == 0x3B); // SRL E
}

test "IM instructions" {
    const code = comptime assemble(
        \\  IM 0
        \\  IM 1
        \\  IM 2
    , 0, 6);
    try expect(code[0] == 0xED);
    try expect(code[1] == 0x46); // IM 0
    try expect(code[2] == 0xED);
    try expect(code[3] == 0x56); // IM 1
    try expect(code[4] == 0xED);
    try expect(code[5] == 0x5E); // IM 2
}

test "forward label reference" {
    const code = comptime assemble(
        \\  JP end
        \\  NOP
        \\  NOP
        \\end:
        \\  HALT
    , 0x0000, 6);
    try expect(code[0] == 0xC3); // JP
    try expect(code[1] == 0x05); // target lo (end at offset 5)
    try expect(code[2] == 0x00); // target hi
    try expect(code[3] == 0x00); // NOP
    try expect(code[4] == 0x00); // NOP
    try expect(code[5] == 0x76); // HALT
}

test "SDCC-style syntax" {
    // SDCC uses tabs, # prefix for immediates, registers lowercase,
    // double-colon labels, and OR A, A style (explicit first operand)
    const code = comptime assemble(
        \\_myproc::
        \\  ld  l, a
        \\  ld  a, #0x01
        \\  jp  _myproc
    , 0x0000, 8);
    try expect(code[0] == 0x6F); // LD L, A
    try expect(code[1] == 0x3E); // LD A, n
    try expect(code[2] == 0x01); // immediate
    try expect(code[3] == 0xC3); // JP
    try expect(code[4] == 0x00); // target lo
    try expect(code[5] == 0x00); // target hi
}

test "SDCC OR A,A and RET Z" {
    const code = comptime assemble(
        \\  or  a, a
        \\  ret Z
    , 0, 2);
    try expect(code[0] == 0xB7); // OR A
    try expect(code[1] == 0xC8); // RET Z
}

test "JP with condition codes" {
    const code = comptime assemble(
        \\  JP NZ, 0x1234
        \\  JP Z, 0x5678
    , 0, 6);
    try expect(code[0] == 0xC2); // JP NZ
    try expect(code[1] == 0x34);
    try expect(code[2] == 0x12);
    try expect(code[3] == 0xCA); // JP Z
    try expect(code[4] == 0x78);
    try expect(code[5] == 0x56);
}

test "DJNZ with label" {
    // LD B, #10  = 06 0A (2 bytes, offset 0-1)
    // loop: (at offset 2)
    // DEC A      = 3D    (1 byte, offset 2)
    // DJNZ loop  = 10 xx (2 bytes, offset 3-4)
    // Total: 5 bytes
    // DJNZ offset: from PC after DJNZ (0x0005) to loop (0x0002) = -3 = 0xFD
    const code = comptime assemble(
        \\  LD B, #10
        \\loop:
        \\  DEC A
        \\  DJNZ loop
    , 0x0000, 5);
    try expect(code[0] == 0x06); // LD B, n
    try expect(code[1] == 0x0A); // 10
    try expect(code[2] == 0x3D); // DEC A
    try expect(code[3] == 0x10); // DJNZ
    try expect(code[4] == 0xFD); // offset -3
}

test "CALL cc label" {
    const code = comptime assemble(
        \\  CALL NZ, target
        \\  RET
        \\target:
        \\  HALT
    , 0x0000, 5);
    try expect(code[0] == 0xC4); // CALL NZ
    try expect(code[1] == 0x04); // target lo
    try expect(code[2] == 0x00); // target hi
    try expect(code[3] == 0xC9); // RET
    try expect(code[4] == 0x76); // HALT
}

test "LD A, (nn) and LD (nn), A" {
    const code = comptime assemble(
        \\  LD A, (0x8000)
        \\  LD (0x9000), A
    , 0, 6);
    try expect(code[0] == 0x3A); // LD A, (nn)
    try expect(code[1] == 0x00);
    try expect(code[2] == 0x80);
    try expect(code[3] == 0x32); // LD (nn), A
    try expect(code[4] == 0x00);
    try expect(code[5] == 0x90);
}

test "LD with IX displacement" {
    const code = comptime assemble(
        \\  LD A, (IX+5)
        \\  LD (IY-3), B
    , 0, 6);
    try expect(code[0] == 0xDD); // IX prefix
    try expect(code[1] == 0x7E); // LD A, (IX+d)
    try expect(code[2] == 0x05); // d=5
    try expect(code[3] == 0xFD); // IY prefix
    try expect(code[4] == 0x70); // LD (IY+d), B
    try expect(code[5] == 0xFD); // d=-3 as unsigned
}

test "DI EI RETI" {
    const code = comptime assemble(
        \\  DI
        \\  EI
        \\  RETI
    , 0, 4);
    try expect(code[0] == 0xF3); // DI
    try expect(code[1] == 0xFB); // EI
    try expect(code[2] == 0xED); // RETI
    try expect(code[3] == 0x4D);
}

test "ADD HL, rr" {
    const code = comptime assemble(
        \\  ADD HL, BC
        \\  ADD HL, SP
    , 0, 2);
    try expect(code[0] == 0x09); // ADD HL, BC
    try expect(code[1] == 0x39); // ADD HL, SP
}

test "SBC HL, rr" {
    const code = comptime assemble(
        \\  SBC HL, DE
    , 0, 2);
    try expect(code[0] == 0xED);
    try expect(code[1] == 0x52); // SBC HL, DE
}

test "LD I,A and LD A,I" {
    const code = comptime assemble(
        \\  LD I, A
        \\  LD A, I
    , 0, 4);
    try expect(code[0] == 0xED);
    try expect(code[1] == 0x47); // LD I, A
    try expect(code[2] == 0xED);
    try expect(code[3] == 0x57); // LD A, I
}

test "NEG DAA CPL SCF CCF" {
    const code = comptime assemble(
        \\  NEG
        \\  DAA
        \\  CPL
        \\  SCF
        \\  CCF
    , 0, 6);
    try expect(code[0] == 0xED);
    try expect(code[1] == 0x44); // NEG
    try expect(code[2] == 0x27); // DAA
    try expect(code[3] == 0x2F); // CPL
    try expect(code[4] == 0x37); // SCF
    try expect(code[5] == 0x3F); // CCF
}

test "RST" {
    const code = comptime assemble(
        \\  RST 0x00
        \\  RST 0x08
        \\  RST 0x30
    , 0, 3);
    try expect(code[0] == 0xC7); // RST 00
    try expect(code[1] == 0xCF); // RST 08
    try expect(code[2] == 0xF7); // RST 30
}

test "XOR A,A SDCC style" {
    const code = comptime assemble(
        \\  xor a, a
    , 0, 1);
    try expect(code[0] == 0xAF); // XOR A
}

test "complex program with multiple labels" {
    const code = comptime assemble(
        \\  LD SP, #0xFEF0
        \\  JR boot_start
        \\.org 0x0038
        \\boot_start:
        \\  LD A, #0
        \\  OUT (10), A
        \\  LD HL, #0x0080
        \\  LD BC, #400
        \\load:
        \\  LD A, H
        \\  OUT (16), A
        \\  DEC BC
        \\  LD A, B
        \\  OR C
        \\  JR Z, done
        \\  JR load
        \\done:
        \\  HALT
    , 0x0000, 80);
    // LD SP, 0xFEF0
    try expect(code[0] == 0x31);
    try expect(code[1] == 0xF0);
    try expect(code[2] == 0xFE);
    // JR to 0x0038 (boot_start)
    try expect(code[3] == 0x18);
    // At 0x0038: LD A, 0
    try expect(code[0x38] == 0x3E);
    try expect(code[0x39] == 0x00);
}

test "db directive" {
    const code = comptime assemble(
        \\  .db 0x41, 0x42, 0x43
    , 0, 3);
    try expect(code[0] == 0x41); // 'A'
    try expect(code[1] == 0x42); // 'B'
    try expect(code[2] == 0x43); // 'C'
}

test "comments and blank lines" {
    const code = comptime assemble(
        \\  ; This is a comment
        \\  NOP          ; inline comment
        \\
        \\  HALT
    , 0, 2);
    try expect(code[0] == 0x00); // NOP
    try expect(code[1] == 0x76); // HALT
}

test "JP HL" {
    const code = comptime assemble(
        \\  JP (HL)
    , 0, 1);
    try expect(code[0] == 0xE9);
}

test "case insensitive" {
    const code = comptime assemble(
        \\  ld sp, #0xFEF0
        \\  Halt
        \\  Nop
    , 0, 5);
    try expect(code[0] == 0x31);
    try expect(code[3] == 0x76);
    try expect(code[4] == 0x00);
}

test "LD (HL), n" {
    const code = comptime assemble(
        \\  LD (HL), #0
    , 0, 2);
    try expect(code[0] == 0x36); // LD (HL), n
    try expect(code[1] == 0x00);
}

test "RLCA RRCA RLA RRA" {
    const code = comptime assemble(
        \\  RLCA
        \\  RRCA
        \\  RLA
        \\  RRA
    , 0, 4);
    try expect(code[0] == 0x07);
    try expect(code[1] == 0x0F);
    try expect(code[2] == 0x17);
    try expect(code[3] == 0x1F);
}

test "LD SP, HL" {
    const code = comptime assemble(
        \\  LD SP, HL
    , 0, 1);
    try expect(code[0] == 0xF9);
}

test "INIR OTIR" {
    const code = comptime assemble(
        \\  INIR
        \\  OTIR
    , 0, 4);
    try expect(code[0] == 0xED);
    try expect(code[1] == 0xB2);
    try expect(code[2] == 0xED);
    try expect(code[3] == 0xB3);
}

test "hex with trailing h" {
    const code = comptime assemble(
        \\  LD A, #42h
    , 0, 2);
    try expect(code[0] == 0x3E);
    try expect(code[1] == 0x42);
}

test "EX (SP), HL" {
    const code = comptime assemble(
        \\  EX (SP), HL
    , 0, 1);
    try expect(code[0] == 0xE3);
}

test "RETN" {
    const code = comptime assemble(
        \\  RETN
    , 0, 2);
    try expect(code[0] == 0xED);
    try expect(code[1] == 0x45);
}

test "LD BC indirect" {
    const code = comptime assemble(
        \\  LD A, (BC)
        \\  LD A, (DE)
        \\  LD (BC), A
        \\  LD (DE), A
    , 0, 4);
    try expect(code[0] == 0x0A); // LD A, (BC)
    try expect(code[1] == 0x1A); // LD A, (DE)
    try expect(code[2] == 0x02); // LD (BC), A
    try expect(code[3] == 0x12); // LD (DE), A
}

test "SDCC tty.asm core instructions" {
    // This test verifies parsing of SDCC-generated assembly patterns
    // from zz80os/build/tty.asm (tty_putc, tty_puts, tty_getc, tty_ready).
    // Uses spaces instead of tabs since Zig multiline strings don't support tabs.
    // _outport and _inport are stubbed as local labels.
    const code = comptime assemble(
        \\_tty_putc::
        \\  ld l, a
        \\  ld a, #0x01
        \\  jp _outport
        \\_tty_puts::
        \\00101$:
        \\  ld a, (hl)
        \\  or a, a
        \\  ret Z
        \\  push hl
        \\  call _tty_putc
        \\  pop hl
        \\  inc hl
        \\  jr 00101$
        \\_tty_getc::
        \\00102$:
        \\  xor a, a
        \\  call _inport
        \\  or a, a
        \\  jr Z, 00102$
        \\  ld a, #0x01
        \\  jp _inport
        \\_tty_ready::
        \\  xor a, a
        \\  jp _inport
        \\_outport:
        \\  ret
        \\_inport:
        \\  ret
    , 0x0000, 64);

    // _tty_putc: LD L, A = 0x6F
    try expect(code[0] == 0x6F);
    // LD A, #0x01 = 3E 01
    try expect(code[1] == 0x3E);
    try expect(code[2] == 0x01);
    // JP _outport = C3 lo hi
    try expect(code[3] == 0xC3);

    // _tty_puts / 00101$: LD A, (HL) = 7E
    try expect(code[6] == 0x7E);
    // OR A, A = B7
    try expect(code[7] == 0xB7);
    // RET Z = C8
    try expect(code[8] == 0xC8);
    // PUSH HL = E5
    try expect(code[9] == 0xE5);
    // CALL _tty_putc = CD 00 00
    try expect(code[10] == 0xCD);
    try expect(code[11] == 0x00);
    try expect(code[12] == 0x00);
    // POP HL = E1
    try expect(code[13] == 0xE1);
    // INC HL = 23
    try expect(code[14] == 0x23);
    // JR 00101$ -- relative jump back from 0x0011 to 0x0006 = -11
    try expect(code[15] == 0x18);
    try expect(code[16] == 0xF5);

    // _tty_getc / 00102$: XOR A, A = AF
    try expect(code[17] == 0xAF);
    // JR Z, 00102$ -- from 0x0018 back to 0x0011 = -7
    try expect(code[22] == 0x28);
    try expect(code[23] == 0xF9);
}

test "ascii and asciz directives" {
    const code = comptime assemble(
        \\  .ascii "Hi"
        \\  .asciz "Ok"
    , 0, 5);
    try expect(code[0] == 'H');
    try expect(code[1] == 'i');
    try expect(code[2] == 'O');
    try expect(code[3] == 'k');
    try expect(code[4] == 0x00); // null terminator from .asciz
}

test "fill directive" {
    const code = comptime assemble(
        \\  LD A, #0xFF
        \\  .fill 3, 0xAA
        \\  HALT
    , 0, 6);
    try expect(code[0] == 0x3E);
    try expect(code[1] == 0xFF);
    try expect(code[2] == 0xAA);
    try expect(code[3] == 0xAA);
    try expect(code[4] == 0xAA);
    try expect(code[5] == 0x76);
}

test "ADC HL" {
    const code = comptime assemble(
        \\  ADC HL, BC
    , 0, 2);
    try expect(code[0] == 0xED);
    try expect(code[1] == 0x4A);
}

test "JP (IX)" {
    const code = comptime assemble(
        \\  JP (IX)
    , 0, 2);
    try expect(code[0] == 0xDD);
    try expect(code[1] == 0xE9);
}

test "RET cc variants" {
    const code = comptime assemble(
        \\  RET NZ
        \\  RET Z
        \\  RET NC
        \\  RET M
    , 0, 4);
    try expect(code[0] == 0xC0); // RET NZ
    try expect(code[1] == 0xC8); // RET Z
    try expect(code[2] == 0xD0); // RET NC
    try expect(code[3] == 0xF8); // RET M
}

test "LD HL, (nn) and LD (nn), HL" {
    const code = comptime assemble(
        \\  LD HL, (0xC000)
        \\  LD (0xC000), HL
    , 0, 6);
    try expect(code[0] == 0x2A);
    try expect(code[1] == 0x00);
    try expect(code[2] == 0xC0);
    try expect(code[3] == 0x22);
    try expect(code[4] == 0x00);
    try expect(code[5] == 0xC0);
}
