//! Z80 assembler core. Works the same at comptime and at runtime: no allocator,
//! no I/O. The caller provides the output, symbol and diagnostic buffers.
//!
//! Input is a "body" that is executed once per pass. It can assemble source
//! text line by line (`line`), call the instruction API directly (`emit`,
//! `label`, `word`, ...), or mix both. Labels defined later in the body get
//! their value in the next pass, so forward references work in both styles.

const std = @import("std");
const isa = @import("isa.zig");
const Lexer = @import("Lexer.zig");
const Token = Lexer.Token;

const Assembler = @This();

pub const max_passes = 8;
pub const max_line_tokens = 64;
pub const message_capacity = 120;

pub const Error = error{AssemblyFailed};

pub const Options = struct {
    /// Address of the first byte when the source does not start with ORG.
    origin: u16 = 0,
};

pub const Symbol = struct {
    name: []const u8,
    /// For sdas local labels such as 00101$: the label they belong to.
    scope: []const u8,
    value: i32,
    known: bool,
    /// Pass in which the symbol was last defined; detects duplicates.
    pass: u8,
};

pub const Diagnostic = struct {
    /// Source line, or 0 for statements that did not come from text.
    line: u32,
    len: u8,
    buf: [message_capacity]u8,

    pub fn message(d: *const Diagnostic) []const u8 {
        return d.buf[0..d.len];
    }

    /// "line 12: message", or just the message when there is no line. Both
    /// the comptime and the runtime interface print diagnostics this way.
    pub fn format(d: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (d.line != 0) try w.print("line {d}: ", .{d.line});
        try w.writeAll(d.buf[0..d.len]);
    }
};

pub const Buffers = struct {
    output: []u8,
    symbols: []Symbol,
    diagnostics: []Diagnostic,
};

/// Fixed-capacity storage for one assembly, usable as a comptime or stack variable.
pub fn Workspace(comptime output_size: usize, comptime symbol_count: usize, comptime diagnostic_count: usize) type {
    return struct {
        output: [output_size]u8,
        symbols: [symbol_count]Symbol,
        diagnostics: [diagnostic_count]Diagnostic,

        pub fn buffers(w: *@This()) Buffers {
            return .{ .output = &w.output, .symbols = &w.symbols, .diagnostics = &w.diagnostics };
        }
    };
}

pub const Result = struct {
    /// Lowest address written.
    origin: u16,
    /// Memory image from `origin` to the highest address written; gaps are zero.
    bytes: []const u8,
    diagnostics: []const Diagnostic,
    /// Diagnostics that did not fit in the buffer.
    diagnostics_dropped: usize,
    passes: u8,

    pub fn ok(r: Result) bool {
        return r.diagnostics.len == 0 and r.diagnostics_dropped == 0;
    }
};

/// A value from an expression. `known` is false while a forward reference has
/// no value yet; such values are placeholders and are never range-checked.
pub const Value = struct {
    value: i32,
    known: bool = true,
};

options: Options,
out: []u8,
symbols: []Symbol,
symbol_count: usize = 0,
diagnostics: []Diagnostic,
diagnostic_count: usize = 0,
diagnostics_dropped: usize = 0,
pass: u8 = 0,
pc: u32 = 0,
/// Address of the current statement, the value of `$`.
statement_pc: u32 = 0,
line_number: u32 = 0,
ended: bool = false,
/// Uses of symbols without a value in this pass.
unresolved: u32 = 0,
/// Last symbol whose value differs from the previous pass.
changed: ?[]const u8 = null,
/// Last ordinary label; scope of the following sdas local labels.
scope: []const u8 = "",
/// Current sdas area when it is not _CODE. Areas are placed by the SDCC
/// linker, which z80asm does not replace, so only _CODE may hold anything.
other_area: ?[]const u8 = null,
written: std.StaticBitSet(0x10000) = .initEmpty(),
empty: bool = true,
low: u32 = 0,
high: u32 = 0,
overlap_reported: bool = false,

/// Runs `body(ctx, assembler)` once per pass until every symbol has a stable
/// value. The body is executed several times, so it must not have side effects
/// outside the assembler: it has to do the same thing on every call.
pub fn run(options: Options, buffers: Buffers, ctx: anytype, comptime body: fn (@TypeOf(ctx), *Assembler) Error!void) Result {
    var a: Assembler = .{
        .options = options,
        .out = buffers.output,
        .symbols = buffers.symbols,
        .diagnostics = buffers.diagnostics,
    };
    while (true) {
        a.beginPass();
        body(ctx, &a) catch {};
        // A second pass is needed only for forward references, and later
        // passes only while some symbol still moves.
        if (a.pass == 1 and a.unresolved == 0) break;
        if (a.pass > 1 and a.changed == null) break;
        if (a.pass == max_passes) {
            a.report("phase error: label '{s}' did not settle", .{a.changed.?});
            break;
        }
    }
    return .{
        .origin = if (a.empty) options.origin else @intCast(a.low),
        .bytes = a.out[0 .. a.high - a.low],
        .diagnostics = a.diagnostics[0..a.diagnostic_count],
        .diagnostics_dropped = a.diagnostics_dropped,
        .passes = a.pass,
    };
}

/// Assembles source text.
pub fn assemble(source: []const u8, options: Options, buffers: Buffers) Result {
    return run(options, buffers, source, assembleLines);
}

fn assembleLines(source: []const u8, a: *Assembler) Error!void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var number: u32 = 0;
    while (lines.next()) |text| {
        if (a.ended) break;
        number += 1;
        a.line_number = number;
        a.line(text) catch {};
    }
    a.line_number = 0;
}

fn beginPass(a: *Assembler) void {
    a.pass += 1;
    a.pc = a.options.origin;
    a.statement_pc = a.pc;
    a.ended = false;
    a.unresolved = 0;
    a.changed = null;
    a.scope = "";
    a.other_area = null;
    a.diagnostic_count = 0;
    a.diagnostics_dropped = 0;
    a.written = .initEmpty();
    a.empty = true;
    a.low = 0;
    a.high = 0;
    a.overlap_reported = false;
}

/// Records a diagnostic and continues. Used for value errors, so that a wrong
/// value never changes the size of the output.
fn report(a: *Assembler, comptime fmt: []const u8, args: anytype) void {
    if (a.diagnostic_count == a.diagnostics.len) {
        a.diagnostics_dropped += 1;
        return;
    }
    const d = &a.diagnostics[a.diagnostic_count];
    a.diagnostic_count += 1;
    d.line = a.line_number;
    const text = std.fmt.bufPrint(&d.buf, fmt, args) catch &d.buf;
    d.len = @intCast(text.len);
}

/// Records a diagnostic and abandons the current statement.
fn fail(a: *Assembler, comptime fmt: []const u8, args: anytype) Error {
    a.report(fmt, args);
    return error.AssemblyFailed;
}

/// Current address.
pub fn here(a: *const Assembler) u16 {
    return @truncate(a.pc);
}

pub fn org(a: *Assembler, address: u16) void {
    a.pc = address;
}

pub fn label(a: *Assembler, name: []const u8) Error!void {
    try a.checkArea();
    try a.define(name, .{ .value = @intCast(a.pc) });
    if (!isLocal(name)) a.scope = name;
}

pub fn equ(a: *Assembler, name: []const u8, v: Value) Error!void {
    return a.define(name, v);
}

pub fn emit(a: *Assembler, e: isa.Encoding) Error!void {
    return a.bytes(e.slice());
}

pub fn bytes(a: *Assembler, data: []const u8) Error!void {
    for (data) |b| try a.store(b);
}

/// Evaluates an expression such as "msg+1" or "$-start".
pub fn eval(a: *Assembler, text: []const u8) Error!Value {
    a.statement_pc = a.pc;
    var l = try a.tokenize(text);
    const v = try a.expression(&l);
    try a.expectEnd(&l);
    return v;
}

/// An expression as an 8-bit operand.
pub fn byte(a: *Assembler, text: []const u8) Error!u8 {
    return a.byteOf(try a.eval(text));
}

/// An expression as a 16-bit operand.
pub fn word(a: *Assembler, text: []const u8) Error!u16 {
    return a.wordOf(try a.eval(text));
}

/// A JR/DJNZ target as the offset from the instruction at the current address.
pub fn relative(a: *Assembler, text: []const u8) Error!i8 {
    return a.relativeOf(try a.eval(text));
}

/// An (IX+d)/(IY+d) displacement.
pub fn displacement(a: *Assembler, text: []const u8) Error!i8 {
    return a.displacementOf(try a.eval(text));
}

fn checkArea(a: *Assembler) Error!void {
    if (a.other_area) |area| return a.fail("only the _CODE area is supported, not '{s}'", .{area});
}

fn store(a: *Assembler, b: u8) Error!void {
    try a.checkArea();
    if (a.pc > 0xFFFF) return a.fail("address beyond 0xFFFF", .{});
    const addr = a.pc;
    if (a.written.isSet(addr)) {
        if (!a.overlap_reported) a.report("overlap at 0x{X:0>4}: address written twice", .{addr});
        a.overlap_reported = true;
    }
    a.written.set(addr);

    if (a.empty) {
        a.empty = false;
        a.low = addr;
        a.high = addr;
    }
    if (addr < a.low) {
        // An ORG went below everything written so far: move the image up.
        const shift = a.low - addr;
        const used = a.high - a.low;
        if (used + shift > a.out.len) return a.fail("output buffer too small ({d} bytes)", .{a.out.len});
        std.mem.copyBackwards(u8, a.out[shift..][0..used], a.out[0..used]);
        @memset(a.out[0..shift], 0);
        a.low = addr;
    }
    if (addr >= a.high) {
        if (addr + 1 - a.low > a.out.len) return a.fail("output buffer too small ({d} bytes)", .{a.out.len});
        @memset(a.out[a.high - a.low .. addr - a.low], 0);
        a.high = addr + 1;
    }
    a.out[addr - a.low] = b;
    a.pc += 1;
}

/// sdas reusable labels: digits followed by '$', local to the region between
/// two ordinary labels. SDCC restarts them in every function.
fn isLocal(name: []const u8) bool {
    return name.len > 1 and name[name.len - 1] == '$' and std.ascii.isDigit(name[0]);
}

fn find(a: *Assembler, name: []const u8) ?*Symbol {
    const scope = if (isLocal(name)) a.scope else "";
    for (a.symbols[0..a.symbol_count]) |*s| {
        if (std.mem.eql(u8, s.name, name) and std.mem.eql(u8, s.scope, scope)) return s;
    }
    return null;
}

fn define(a: *Assembler, name: []const u8, v: Value) Error!void {
    if (a.find(name)) |s| {
        if (s.pass == a.pass) return a.fail("duplicate symbol '{s}'", .{name});
        if (s.known != v.known or s.value != v.value) a.changed = s.name;
        s.value = v.value;
        s.known = v.known;
        s.pass = a.pass;
        return;
    }
    if (a.symbol_count == a.symbols.len) return a.fail("too many symbols (capacity {d})", .{a.symbols.len});
    a.symbols[a.symbol_count] = .{
        .name = name,
        .scope = if (isLocal(name)) a.scope else "",
        .value = v.value,
        .known = v.known,
        .pass = a.pass,
    };
    a.symbol_count += 1;
    if (a.pass > 1) a.changed = name;
}

fn symbolValue(a: *Assembler, name: []const u8) Value {
    if (a.find(name)) |s| {
        if (!s.known) {
            a.unresolved += 1;
            // Defined, but only in terms of itself or of undefined symbols.
            if (a.pass > 1) a.report("symbol '{s}' has no value", .{name});
        }
        return .{ .value = s.value, .known = s.known };
    }
    a.unresolved += 1;
    // In pass 1 this may be a label further down; only later passes know.
    if (a.pass > 1) a.report("undefined symbol '{s}'", .{name});
    return .{ .value = 0, .known = false };
}

// Value checks are skipped for unknown values and only record a diagnostic,
// so they are reported in the pass where everything is known.

fn byteOf(a: *Assembler, v: Value) u8 {
    if (v.known and (v.value < -128 or v.value > 255)) a.report("value {d} does not fit in 8 bits", .{v.value});
    return @truncate(@as(u32, @bitCast(v.value)));
}

fn wordOf(a: *Assembler, v: Value) u16 {
    if (v.known and (v.value < -32768 or v.value > 65535)) a.report("value {d} does not fit in 16 bits", .{v.value});
    return @truncate(@as(u32, @bitCast(v.value)));
}

fn displacementOf(a: *Assembler, v: Value) i8 {
    if (v.known and (v.value < -128 or v.value > 127)) {
        a.report("index displacement {d} out of range -128..127", .{v.value});
        return 0;
    }
    return @truncate(v.value);
}

/// Offset of a JR/DJNZ target from the end of the 2-byte instruction.
fn relativeOf(a: *Assembler, target: Value) i8 {
    if (!target.known) return 0;
    const offset = @as(i64, target.value) - (a.statement_pc + 2);
    if (offset < -128 or offset > 127) {
        a.report("relative jump out of range ({d} bytes)", .{offset});
        return 0;
    }
    return @intCast(offset);
}

fn bitOf(a: *Assembler, v: Value) u3 {
    if (v.known and (v.value < 0 or v.value > 7)) a.report("bit number {d} out of range 0..7", .{v.value});
    return @truncate(@as(u32, @bitCast(v.value)));
}

const Line = struct {
    tokens: [max_line_tokens]Token,
    len: usize,
    pos: usize = 0,

    fn peek(l: *const Line) Token {
        return l.tokens[l.pos];
    }

    fn peekAt(l: *const Line, n: usize) Token {
        return l.tokens[@min(l.pos + n, l.len - 1)];
    }

    fn take(l: *Line) Token {
        const t = l.tokens[l.pos];
        if (l.pos + 1 < l.len) l.pos += 1;
        return t;
    }

    fn atEnd(l: *const Line) bool {
        return l.peek().tag == .end;
    }

    fn eat(l: *Line, tag: Token.Tag) bool {
        if (l.peek().tag != tag) return false;
        _ = l.take();
        return true;
    }
};

fn tokenize(a: *Assembler, text: []const u8) Error!Line {
    var l: Line = .{ .tokens = undefined, .len = 0 };
    var lexer: Lexer = .init(text);
    while (true) {
        const t = lexer.next();
        switch (t.tag) {
            .invalid => return a.fail("unexpected character '{s}'", .{t.text}),
            .unterminated_string => return a.fail("unterminated string", .{}),
            else => {},
        }
        if (l.len == max_line_tokens) return a.fail("line has more than {d} tokens", .{max_line_tokens});
        l.tokens[l.len] = t;
        l.len += 1;
        if (t.tag == .end) return l;
    }
}

fn expectEnd(a: *Assembler, l: *Line) Error!void {
    if (!l.atEnd()) return a.fail("unexpected '{s}'", .{l.peek().text});
}

fn expect(a: *Assembler, l: *Line, tag: Token.Tag, what: []const u8) Error!void {
    if (l.eat(tag)) return;
    if (l.atEnd()) return a.fail("expected {s} before end of line", .{what});
    return a.fail("expected {s}, found '{s}'", .{ what, l.peek().text });
}

const Operator = enum { @"or", xor, @"and", shl, shr, add, sub, mul, div, mod };

fn binaryOperator(tag: Token.Tag) ?struct { op: Operator, precedence: u8 } {
    return switch (tag) {
        .pipe => .{ .op = .@"or", .precedence = 1 },
        .caret => .{ .op = .xor, .precedence = 2 },
        .ampersand => .{ .op = .@"and", .precedence = 3 },
        .shift_left => .{ .op = .shl, .precedence = 4 },
        .shift_right => .{ .op = .shr, .precedence = 4 },
        .plus => .{ .op = .add, .precedence = 5 },
        .minus => .{ .op = .sub, .precedence = 5 },
        .asterisk => .{ .op = .mul, .precedence = 6 },
        .slash => .{ .op = .div, .precedence = 6 },
        .percent => .{ .op = .mod, .precedence = 6 },
        else => null,
    };
}

fn expression(a: *Assembler, l: *Line) Error!Value {
    return a.binary(l, 1);
}

fn binary(a: *Assembler, l: *Line, min_precedence: u8) Error!Value {
    var lhs = try a.unary(l);
    while (binaryOperator(l.peek().tag)) |bin| {
        if (bin.precedence < min_precedence) break;
        _ = l.take();
        const rhs = try a.binary(l, bin.precedence + 1);
        lhs = a.apply(bin.op, lhs, rhs);
    }
    return lhs;
}

fn apply(a: *Assembler, op: Operator, lhs: Value, rhs: Value) Value {
    const x = lhs.value;
    const y = rhs.value;
    const known = lhs.known and rhs.known;
    const v: i32 = switch (op) {
        .@"or" => x | y,
        .xor => x ^ y,
        .@"and" => x & y,
        .shl => if (y < 0 or y > 31) 0 else x << @intCast(y),
        .shr => if (y < 0 or y > 31) 0 else x >> @intCast(y),
        .add => x +% y,
        .sub => x -% y,
        .mul => x *% y,
        .div, .mod => blk: {
            if (y == 0) {
                if (known) a.report("division by zero", .{});
                break :blk 0;
            }
            // minInt(i32) / -1 does not fit; wrap it like the other operators.
            if (y == -1) break :blk if (op == .div) 0 -% x else 0;
            break :blk if (op == .div) @divTrunc(x, y) else @rem(x, y);
        },
    };
    return .{ .value = v, .known = known };
}

fn unary(a: *Assembler, l: *Line) Error!Value {
    if (l.eat(.minus)) {
        const v = try a.unary(l);
        return .{ .value = -%v.value, .known = v.known };
    }
    if (l.eat(.plus)) return a.unary(l);
    if (l.peek().tag == .hash) {
        const hash = l.take();
        if (try a.hashHex(hash, l.peek())) |v| {
            _ = l.take();
            return v;
        }
        return a.unary(l);
    }
    if (l.eat(.tilde)) {
        const v = try a.unary(l);
        return .{ .value = ~v.value, .known = v.known };
    }
    // sdas: #<x and #>x are the low and high byte of x.
    if (l.eat(.less)) {
        const v = try a.unary(l);
        return .{ .value = v.value & 0xFF, .known = v.known };
    }
    if (l.eat(.greater)) {
        const v = try a.unary(l);
        return .{ .value = (v.value >> 8) & 0xFF, .known = v.known };
    }
    return a.primary(l);
}

fn primary(a: *Assembler, l: *Line) Error!Value {
    const t = l.take();
    switch (t.tag) {
        .number => return .{ .value = parseNumber(t.text) orelse return a.fail("invalid number '{s}'", .{t.text}) },
        .string => {
            var it: StringBytes = .init(t.text);
            const c = try a.stringByte(&it) orelse return a.fail("string {s} used as a number", .{t.text});
            if (try a.stringByte(&it) != null) return a.fail("string {s} used as a number", .{t.text});
            return .{ .value = c };
        },
        .dollar => return .{ .value = @intCast(a.statement_pc) },
        // Where an operand is expected, '%' starts a binary number ("DB %0101").
        .percent => {
            const digits = l.peek();
            if (digits.tag == .number and digits.col == t.col + 1) {
                _ = l.take();
                return .{ .value = parseDigits(digits.text, 2) orelse return a.fail("invalid number '%{s}'", .{digits.text}) };
            }
            return a.fail("expected an expression, found '%'", .{});
        },
        .identifier => {
            if (register(t.text) != null) return a.fail("register '{s}' used in an expression", .{t.text});
            return a.symbolValue(t.text);
        },
        .l_paren => {
            const v = try a.expression(l);
            try a.expect(l, .r_paren, "')'");
            return v;
        },
        .end => return a.fail("expected an expression before end of line", .{}),
        else => return a.fail("expected an expression, found '{s}'", .{t.text}),
    }
}

/// '#' is a hex prefix in sjasmplus ("#4000") and only marks an immediate in
/// SDCC output ("#0x0a", "#_table", "#<(x)"). Returns the value when the digits
/// after '#' can only be hex, null when '#' is the SDCC marker, and fails when
/// the two readings give different values.
fn hashHex(a: *Assembler, hash: Token, t: Token) Error!?Value {
    if (t.col != hash.col + 1) return null;
    if (t.tag != .number and t.tag != .identifier) return null;
    var letter = false;
    for (t.text) |c| {
        if (!std.ascii.isHex(c)) return null;
        if (!std.ascii.isDigit(c)) letter = true;
    }
    if (letter) return .{ .value = parseDigits(t.text, 16) orelse return a.fail("invalid number '#{s}'", .{t.text}) };
    if (t.text.len == 1) return null;
    return a.fail("'#{s}' is hex in sjasmplus and decimal in SDCC; write 0x{s} or the decimal value", .{ t.text, t.text });
}

/// 0x1F, $1F, 1Fh, 0b1010, 1010b or decimal. %1010 is handled in `primary`.
fn parseNumber(text: []const u8) ?i32 {
    if (text.len > 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) return parseDigits(text[2..], 16);
    if (text.len > 1 and text[0] == '$') return parseDigits(text[1..], 16);
    const last = text[text.len - 1];
    if (text.len > 1 and (last == 'h' or last == 'H')) return parseDigits(text[0 .. text.len - 1], 16);
    if (text.len > 2 and text[0] == '0' and (text[1] == 'b' or text[1] == 'B')) return parseDigits(text[2..], 2);
    if (text.len > 1 and (last == 'b' or last == 'B')) return parseDigits(text[0 .. text.len - 1], 2);
    return parseDigits(text, 10);
}

fn parseDigits(digits: []const u8, base: u8) ?i32 {
    const v = std.fmt.parseUnsigned(u32, digits, base) catch return null;
    return if (v > std.math.maxInt(i32)) null else @intCast(v);
}

const Reg = enum { a, b, c, d, e, h, l, i, r, ixh, ixl, iyh, iyl, af, af_alt, bc, de, hl, sp, ix, iy };

fn register(name: []const u8) ?Reg {
    if (std.ascii.eqlIgnoreCase(name, "af'")) return .af_alt;
    var buf: [3]u8 = undefined;
    if (name.len > buf.len) return null;
    return std.meta.stringToEnum(Reg, std.ascii.lowerString(&buf, name));
}

/// B, C, D, E, H, L and A as an isa register.
fn plain(r: Reg) ?isa.R8 {
    return switch (r) {
        .a => .a,
        .b => .b,
        .c => .c,
        .d => .d,
        .e => .e,
        .h => .h,
        .l => .l,
        else => null,
    };
}

/// IXH/IXL/IYH/IYL as the index register and the H/L slot they replace.
fn half(r: Reg) ?struct { idx: isa.Idx, reg: isa.R8 } {
    return switch (r) {
        .ixh => .{ .idx = .ix, .reg = .h },
        .ixl => .{ .idx = .ix, .reg = .l },
        .iyh => .{ .idx = .iy, .reg = .h },
        .iyl => .{ .idx = .iy, .reg = .l },
        else => null,
    };
}

fn pair(r: Reg) ?isa.R16 {
    return switch (r) {
        .bc => .bc,
        .de => .de,
        .hl => .hl,
        .sp => .sp,
        else => null,
    };
}

fn index(r: Reg) ?isa.Idx {
    return switch (r) {
        .ix => .ix,
        .iy => .iy,
        else => null,
    };
}

const Operand = union(enum) {
    reg: Reg,
    /// (HL), (BC), (DE), (SP), (C), (IX), (IY)
    mem_reg: Reg,
    mem_index: struct { idx: isa.Idx, d: i8 },
    /// (nn)
    mem: Value,
    imm: Value,

    /// (HL) as isa.R8.hl_mem, or a plain register.
    fn r8(op: Operand) ?isa.R8 {
        return switch (op) {
            .reg => |r| plain(r),
            .mem_reg => |r| if (r == .hl) .hl_mem else null,
            else => null,
        };
    }

    /// (IX+d)/(IY+d), with (IX) meaning (IX+0).
    fn indexed(op: Operand) ?struct { idx: isa.Idx, d: i8 } {
        return switch (op) {
            .mem_index => |m| .{ .idx = m.idx, .d = m.d },
            .mem_reg => |r| if (index(r)) |idx| .{ .idx = idx, .d = 0 } else null,
            else => null,
        };
    }
};

fn operand(a: *Assembler, l: *Line) Error!Operand {
    const t = l.peek();
    if (t.tag == .identifier) {
        if (register(t.text)) |r| {
            _ = l.take();
            return .{ .reg = r };
        }
    }
    if (t.tag == .l_paren and l.peekAt(1).tag == .identifier) {
        if (register(l.peekAt(1).text)) |r| {
            _ = l.take();
            _ = l.take();
            if (index(r)) |idx| {
                if (l.peek().tag == .plus or l.peek().tag == .minus) {
                    const d = a.displacementOf(try a.expression(l));
                    try a.expect(l, .r_paren, "')'");
                    return .{ .mem_index = .{ .idx = idx, .d = d } };
                }
            }
            try a.expect(l, .r_paren, "')'");
            return .{ .mem_reg = r };
        }
    }

    // "(expr)" is a memory operand only when the parentheses enclose the whole
    // operand; "(2+3)*2" is an immediate.
    const start = l.pos;
    const v = try a.expression(l);
    // sdas writes (IX+d) as "d (ix)".
    if (l.peek().tag == .l_paren and l.peekAt(2).tag == .r_paren) {
        if (register(l.peekAt(1).text)) |r| if (index(r)) |idx| {
            _ = l.take();
            _ = l.take();
            _ = l.take();
            return .{ .mem_index = .{ .idx = idx, .d = a.displacementOf(v) } };
        };
    }
    if (l.tokens[start].tag == .l_paren and l.tokens[l.pos - 1].tag == .r_paren and closes(l, start, l.pos - 1)) {
        return .{ .mem = v };
    }
    return .{ .imm = v };
}

/// Whether the parenthesis at `close` matches the one at `open`.
fn closes(l: *const Line, open: usize, close: usize) bool {
    var depth: usize = 0;
    for (l.tokens[open .. close + 1], open..) |t, i| {
        switch (t.tag) {
            .l_paren => depth += 1,
            .r_paren => {
                depth -= 1;
                if (depth == 0) return i == close;
            },
            else => {},
        }
    }
    return false;
}

fn operandPair(a: *Assembler, l: *Line) Error![2]Operand {
    const first = try a.operand(l);
    try a.expect(l, .comma, "','");
    return .{ first, try a.operand(l) };
}

/// Condition code at the start of a JP/JR/CALL/RET operand list.
fn condition(l: *Line, followed_by_comma: bool) ?isa.Cc {
    const t = l.peek();
    if (t.tag != .identifier) return null;
    if (followed_by_comma and l.peekAt(1).tag != .comma) return null;
    var buf: [2]u8 = undefined;
    if (t.text.len > buf.len) return null;
    const cc = std.meta.stringToEnum(isa.Cc, std.ascii.lowerString(&buf, t.text)) orelse return null;
    _ = l.take();
    if (followed_by_comma) _ = l.take();
    return cc;
}

const Keyword = enum {
    adc,
    add,
    @"and",
    bit,
    call,
    ccf,
    cp,
    cpd,
    cpdr,
    cpi,
    cpir,
    cpl,
    daa,
    dec,
    di,
    djnz,
    ei,
    ex,
    exx,
    halt,
    im,
    in,
    inc,
    ind,
    indr,
    ini,
    inir,
    jp,
    jr,
    ld,
    ldd,
    lddr,
    ldi,
    ldir,
    neg,
    nop,
    @"or",
    otdr,
    otir,
    out,
    outd,
    outi,
    pop,
    push,
    res,
    ret,
    reti,
    retn,
    rl,
    rla,
    rlc,
    rlca,
    rld,
    rr,
    rra,
    rrc,
    rrca,
    rrd,
    rst,
    sbc,
    scf,
    set,
    sla,
    sli,
    sll,
    sra,
    srl,
    sub,
    xor,
    org,
    db,
    defb,
    defm,
    dm,
    dw,
    defw,
    ds,
    defs,
    end,
    equ,
    @".org",
    @".db",
    @".byte",
    @".dw",
    @".word",
    @".ds",
    @".ascii",
    @".asciz",
    @".area",
    @".globl",
    @".module",
    @".optsdcc",
};

fn keyword(name: []const u8) ?Keyword {
    var buf: [8]u8 = undefined;
    if (name.len > buf.len) return null;
    return std.meta.stringToEnum(Keyword, std.ascii.lowerString(&buf, name));
}

/// Assembles one line of source text.
pub fn line(a: *Assembler, text: []const u8) Error!void {
    a.statement_pc = a.pc;
    var l = try a.tokenize(text);

    // A label is "name:" / "name::" anywhere, or a name in column 0 that is
    // not an instruction or directive.
    var name: ?[]const u8 = null;
    const first = l.peek();
    if (first.tag == .identifier) {
        const next = l.peekAt(1).tag;
        if (next == .colon or next == .double_colon) {
            name = first.text;
            _ = l.take();
            _ = l.take();
        } else if (first.col == 0 and keyword(first.text) == null) {
            name = first.text;
            _ = l.take();
        }
    }

    if (name) |n| {
        const t = l.peek();
        if (t.tag == .equal or (t.tag == .identifier and keyword(t.text) == .equ)) {
            _ = l.take();
            const v = try a.expression(&l);
            try a.expectEnd(&l);
            return a.equ(n, v);
        }
        try a.label(n);
    }
    if (l.atEnd()) return;

    const t = l.take();
    if (t.tag != .identifier) return a.fail("expected an instruction or directive, found '{s}'", .{t.text});
    const kw = keyword(t.text) orelse return a.fail("unknown instruction '{s}'", .{t.text});
    try a.statement(&l, kw);
    try a.expectEnd(&l);
}

fn statement(a: *Assembler, l: *Line, kw: Keyword) Error!void {
    const fixed: ?isa.Encoding = switch (kw) {
        .nop => isa.nop(),
        .halt => isa.halt(),
        .ei => isa.ei(),
        .di => isa.di(),
        .exx => isa.exx(),
        .rlca => isa.rlca(),
        .rrca => isa.rrca(),
        .rla => isa.rla(),
        .rra => isa.rra(),
        .daa => isa.daa(),
        .cpl => isa.cpl(),
        .scf => isa.scf(),
        .ccf => isa.ccf(),
        .neg => isa.neg(),
        .retn => isa.retn(),
        .reti => isa.reti(),
        .rrd => isa.rrd(),
        .rld => isa.rld(),
        .ldi => isa.ldi(),
        .ldd => isa.ldd(),
        .ldir => isa.ldir(),
        .lddr => isa.lddr(),
        .cpi => isa.cpi(),
        .cpd => isa.cpd(),
        .cpir => isa.cpir(),
        .cpdr => isa.cpdr(),
        .ini => isa.ini(),
        .ind => isa.ind(),
        .inir => isa.inir(),
        .indr => isa.indr(),
        .outi => isa.outi(),
        .outd => isa.outd(),
        .otir => isa.otir(),
        .otdr => isa.otdr(),
        else => null,
    };
    if (fixed) |e| return a.emit(e);

    return switch (kw) {
        .ld => a.emit(try a.encodeLd(try a.operandPair(l))),
        .add => a.alu(l, .add),
        .adc => a.alu(l, .adc),
        .sub => a.alu(l, .sub),
        .sbc => a.alu(l, .sbc),
        .@"and" => a.alu(l, .@"and"),
        .xor => a.alu(l, .xor),
        .@"or" => a.alu(l, .@"or"),
        .cp => a.alu(l, .cp),
        .inc => a.incDec(l, true),
        .dec => a.incDec(l, false),
        .push => a.pushPop(l, true),
        .pop => a.pushPop(l, false),
        .jp => a.jump(l),
        .call => a.callStatement(l),
        .jr => a.relativeJump(l, false),
        .djnz => a.relativeJump(l, true),
        .ret => if (condition(l, false)) |cc| a.emit(isa.retCc(cc)) else a.emit(isa.ret()),
        .rst => a.restart(l),
        .ex => a.exchange(l),
        .in => a.input(l),
        .out => a.output(l),
        .im => a.interruptMode(l),
        .bit => a.bitStatement(l, .bit),
        .set => a.bitStatement(l, .set),
        .res => a.bitStatement(l, .res),
        .rlc => a.rotate(l, .rlc),
        .rrc => a.rotate(l, .rrc),
        .rl => a.rotate(l, .rl),
        .rr => a.rotate(l, .rr),
        .sla => a.rotate(l, .sla),
        .sra => a.rotate(l, .sra),
        .sll, .sli => a.rotate(l, .sll),
        .srl => a.rotate(l, .srl),
        .org, .@".org" => a.org(a.wordOf(try a.expression(l))),
        .db, .defb, .defm, .dm, .@".db", .@".byte" => a.dataBytes(l),
        .@".ascii" => a.asciiString(l, false),
        .@".asciz" => a.asciiString(l, true),
        .dw, .defw, .@".dw", .@".word" => a.dataWords(l),
        .ds, .defs, .@".ds" => a.reserve(l),
        .end => {
            // "END start" names the entry point, which a flat image does not need.
            if (!l.atEnd()) _ = try a.expression(l);
            a.ended = true;
        },
        .equ => a.fail("EQU needs a label", .{}),
        .@".area" => {
            const name = l.take();
            if (name.tag != .identifier) return a.fail("expected an area name, found '{s}'", .{name.text});
            a.other_area = if (std.mem.eql(u8, name.text, "_CODE")) null else name.text;
            l.pos = l.len - 1; // "(ABS)" and other attributes
        },
        .@".globl", .@".module", .@".optsdcc" => l.pos = l.len - 1,
        else => unreachable,
    };
}

fn invalid(a: *Assembler) Error {
    return a.fail("invalid operands", .{});
}

fn encodeLd(a: *Assembler, ops: [2]Operand) Error!isa.Encoding {
    const dst, const src = ops;
    switch (dst) {
        .reg => |d| {
            if (plain(d)) |r| {
                if (src.r8()) |s| return isa.ldRR(r, s);
                if (src.indexed()) |m| return isa.ldRIdxD(r, m.idx, m.d);
                switch (src) {
                    .imm => |v| return isa.ldRN(r, a.byteOf(v)),
                    .reg => |s| {
                        if (half(s)) |h| {
                            if (d == .h or d == .l) return a.invalid();
                            return isa.indexHalf(h.idx, isa.ldRR(r, h.reg));
                        }
                        if (d == .a and s == .i) return isa.ldAI();
                        if (d == .a and s == .r) return isa.ldAR();
                    },
                    .mem_reg => |s| if (d == .a) {
                        if (s == .bc) return isa.ldABc();
                        if (s == .de) return isa.ldADe();
                    },
                    .mem => |v| if (d == .a) return isa.ldAMem(a.wordOf(v)),
                    else => {},
                }
                return a.invalid();
            }
            if (half(d)) |h| {
                switch (src) {
                    .imm => |v| return isa.indexHalf(h.idx, isa.ldRN(h.reg, a.byteOf(v))),
                    .reg => |s| {
                        if (plain(s)) |r| if (s != .h and s != .l) return isa.indexHalf(h.idx, isa.ldRR(h.reg, r));
                        if (half(s)) |sh| if (sh.idx == h.idx) return isa.indexHalf(h.idx, isa.ldRR(h.reg, sh.reg));
                    },
                    else => {},
                }
                return a.invalid();
            }
            if (d == .i and src == .reg and src.reg == .a) return isa.ldIA();
            if (d == .r and src == .reg and src.reg == .a) return isa.ldRA();
            if (pair(d)) |rr| switch (src) {
                .imm => |v| return isa.ldRrNn(rr, a.wordOf(v)),
                .mem => |v| return isa.ldRrMem(rr, a.wordOf(v)),
                .reg => |s| if (rr == .sp) {
                    if (s == .hl) return isa.ldSpHl();
                    if (index(s)) |idx| return isa.ldSpIdx(idx);
                },
                else => {},
            };
            if (index(d)) |idx| switch (src) {
                .imm => |v| return isa.ldIdxNn(idx, a.wordOf(v)),
                .mem => |v| return isa.ldIdxMem(idx, a.wordOf(v)),
                else => {},
            };
        },
        .mem_reg => |d| {
            if (d == .hl) {
                if (src.r8()) |s| if (s != .hl_mem) return isa.ldRR(.hl_mem, s);
                if (src == .imm) return isa.ldRN(.hl_mem, a.byteOf(src.imm));
            }
            if (src == .reg and src.reg == .a) {
                if (d == .bc) return isa.ldBcA();
                if (d == .de) return isa.ldDeA();
            }
            if (dst.indexed()) |m| return a.encodeLdIndexed(m.idx, m.d, src);
        },
        .mem_index => |m| return a.encodeLdIndexed(m.idx, m.d, src),
        .mem => |v| if (src == .reg) {
            if (src.reg == .a) return isa.ldMemA(a.wordOf(v));
            if (pair(src.reg)) |rr| return isa.ldMemRr(a.wordOf(v), rr);
            if (index(src.reg)) |idx| return isa.ldMemIdx(a.wordOf(v), idx);
        },
        .imm => {},
    }
    return a.invalid();
}

fn encodeLdIndexed(a: *Assembler, idx: isa.Idx, d: i8, src: Operand) Error!isa.Encoding {
    switch (src) {
        .reg => |s| if (plain(s)) |r| return isa.ldIdxDR(idx, d, r),
        .imm => |v| return isa.ldIdxDN(idx, d, a.byteOf(v)),
        else => {},
    }
    return a.invalid();
}

fn alu(a: *Assembler, l: *Line, op: isa.Alu) Error!void {
    var src = try a.operand(l);
    if (l.eat(.comma)) {
        const rhs = try a.operand(l);
        if (src != .reg) return a.invalid();
        switch (src.reg) {
            .a => src = rhs,
            .hl => {
                const rr = if (rhs == .reg) pair(rhs.reg) else null;
                if (rr == null) return a.invalid();
                return a.emit(switch (op) {
                    .add => isa.addHlRr(rr.?),
                    .adc => isa.adcHlRr(rr.?),
                    .sbc => isa.sbcHlRr(rr.?),
                    else => return a.invalid(),
                });
            },
            .ix, .iy => {
                const idx = index(src.reg).?;
                if (op != .add or rhs != .reg) return a.invalid();
                const rr: isa.R16 = switch (rhs.reg) {
                    .bc => .bc,
                    .de => .de,
                    .sp => .sp,
                    else => if (index(rhs.reg) == idx) .hl else return a.invalid(),
                };
                return a.emit(isa.addIdxRr(idx, rr));
            },
            else => return a.invalid(),
        }
    }
    if (src.r8()) |r| return a.emit(isa.aluR(op, r));
    if (src.indexed()) |m| return a.emit(isa.aluIdxD(op, m.idx, m.d));
    switch (src) {
        .imm => |v| return a.emit(isa.aluN(op, a.byteOf(v))),
        .reg => |r| if (half(r)) |h| return a.emit(isa.indexHalf(h.idx, isa.aluR(op, h.reg))),
        else => {},
    }
    return a.invalid();
}

fn incDec(a: *Assembler, l: *Line, inc: bool) Error!void {
    const op = try a.operand(l);
    if (op.r8()) |r| return a.emit(if (inc) isa.incR(r) else isa.decR(r));
    if (op.indexed()) |m| return a.emit(if (inc) isa.incIdxD(m.idx, m.d) else isa.decIdxD(m.idx, m.d));
    if (op == .reg) {
        if (pair(op.reg)) |rr| return a.emit(if (inc) isa.incRr(rr) else isa.decRr(rr));
        if (index(op.reg)) |idx| return a.emit(if (inc) isa.incIdx(idx) else isa.decIdx(idx));
        if (half(op.reg)) |h| return a.emit(isa.indexHalf(h.idx, if (inc) isa.incR(h.reg) else isa.decR(h.reg)));
    }
    return a.invalid();
}

fn pushPop(a: *Assembler, l: *Line, push: bool) Error!void {
    const op = try a.operand(l);
    if (op != .reg) return a.invalid();
    if (index(op.reg)) |idx| return a.emit(if (push) isa.pushIdx(idx) else isa.popIdx(idx));
    const rr: isa.R16af = switch (op.reg) {
        .bc => .bc,
        .de => .de,
        .hl => .hl,
        .af => .af,
        else => return a.invalid(),
    };
    return a.emit(if (push) isa.push(rr) else isa.pop(rr));
}

fn jump(a: *Assembler, l: *Line) Error!void {
    if (condition(l, true)) |cc| {
        const target = try a.operand(l);
        if (target != .imm) return a.invalid();
        return a.emit(isa.jpCc(cc, a.wordOf(target.imm)));
    }
    const target = try a.operand(l);
    switch (target) {
        .imm => |v| return a.emit(isa.jp(a.wordOf(v))),
        .mem_reg => |r| {
            if (r == .hl) return a.emit(isa.jpHl());
            if (index(r)) |idx| return a.emit(isa.jpIdx(idx));
        },
        else => {},
    }
    return a.invalid();
}

fn callStatement(a: *Assembler, l: *Line) Error!void {
    const cc = condition(l, true);
    const target = try a.operand(l);
    if (target != .imm) return a.invalid();
    const nn = a.wordOf(target.imm);
    return a.emit(if (cc) |c| isa.callCc(c, nn) else isa.call(nn));
}

fn relativeJump(a: *Assembler, l: *Line, djnz: bool) Error!void {
    const cc = if (djnz) null else condition(l, true);
    if (cc) |c| switch (c) {
        .nz, .z, .nc, .c => {},
        else => return a.fail("JR supports only NZ, Z, NC and C", .{}),
    };
    const target = try a.operand(l);
    if (target != .imm) return a.invalid();
    const e = a.relativeOf(target.imm);
    if (djnz) return a.emit(isa.djnz(e));
    return a.emit(if (cc) |c| isa.jrCc(c, e) else isa.jr(e));
}

fn restart(a: *Assembler, l: *Line) Error!void {
    const v = try a.expression(l);
    if (v.known and (v.value < 0 or v.value > 0x38 or @rem(v.value, 8) != 0)) {
        a.report("RST target must be one of 0x00, 0x08, ..., 0x38", .{});
        return a.emit(isa.rst(0));
    }
    return a.emit(isa.rst(if (v.known) @intCast(v.value) else 0));
}

fn exchange(a: *Assembler, l: *Line) Error!void {
    const dst, const src = try a.operandPair(l);
    if (dst == .reg and src == .reg) {
        if (dst.reg == .af and src.reg == .af_alt) return a.emit(isa.exAf());
        if (dst.reg == .de and src.reg == .hl) return a.emit(isa.exDeHl());
    }
    if (dst == .mem_reg and dst.mem_reg == .sp and src == .reg) {
        if (src.reg == .hl) return a.emit(isa.exSpHl());
        if (index(src.reg)) |idx| return a.emit(isa.exSpIdx(idx));
    }
    return a.invalid();
}

fn input(a: *Assembler, l: *Line) Error!void {
    // IN F,(C) and IN (C) only set the flags.
    const t = l.peek();
    if (t.tag == .identifier and std.ascii.eqlIgnoreCase(t.text, "f") and l.peekAt(1).tag == .comma) {
        _ = l.take();
        _ = l.take();
    }
    const first = try a.operand(l);
    if (!l.eat(.comma)) {
        if (first == .mem_reg and first.mem_reg == .c) return a.emit(isa.inFC());
        return a.invalid();
    }
    const src = try a.operand(l);
    if (first != .reg) return a.invalid();
    const r = plain(first.reg) orelse return a.invalid();
    if (src == .mem_reg and src.mem_reg == .c) return a.emit(isa.inRC(r));
    if (src == .mem and r == .a) return a.emit(isa.inAN(a.byteOf(src.mem)));
    return a.invalid();
}

fn output(a: *Assembler, l: *Line) Error!void {
    const dst, const src = try a.operandPair(l);
    if (dst == .mem and src == .reg and src.reg == .a) return a.emit(isa.outNA(a.byteOf(dst.mem)));
    if (dst == .mem_reg and dst.mem_reg == .c) {
        if (src == .reg) if (plain(src.reg)) |r| return a.emit(isa.outCR(r));
        if (src == .imm and src.imm.value == 0) return a.emit(isa.outC0());
    }
    return a.invalid();
}

fn interruptMode(a: *Assembler, l: *Line) Error!void {
    const v = try a.expression(l);
    if (v.known and (v.value < 0 or v.value > 2)) {
        a.report("interrupt mode must be 0, 1 or 2", .{});
        return a.emit(isa.im(0));
    }
    return a.emit(isa.im(if (v.known) @intCast(v.value) else 0));
}

const BitOp = enum { bit, set, res };

fn bitStatement(a: *Assembler, l: *Line, op: BitOp) Error!void {
    const b = a.bitOf(try a.expression(l));
    try a.expect(l, .comma, "','");
    const target = try a.operand(l);
    if (target.r8()) |r| return a.emit(switch (op) {
        .bit => isa.bit(b, r),
        .set => isa.set(b, r),
        .res => isa.res(b, r),
    });
    if (target.indexed()) |m| return a.emit(switch (op) {
        .bit => isa.bitIdxD(b, m.idx, m.d),
        .set => isa.setIdxD(b, m.idx, m.d),
        .res => isa.resIdxD(b, m.idx, m.d),
    });
    return a.invalid();
}

fn rotate(a: *Assembler, l: *Line, op: isa.Rot) Error!void {
    const target = try a.operand(l);
    if (target.r8()) |r| return a.emit(isa.rot(op, r));
    if (target.indexed()) |m| return a.emit(isa.rotIdxD(op, m.idx, m.d));
    return a.invalid();
}

fn dataBytes(a: *Assembler, l: *Line) Error!void {
    while (true) {
        const t = l.peek();
        const next = l.peekAt(1).tag;
        if (t.tag == .string and (next == .comma or next == .end)) {
            _ = l.take();
            try a.stringBytes(t);
        } else {
            try a.store(a.byteOf(try a.expression(l)));
        }
        if (!l.eat(.comma)) return;
    }
}

fn asciiString(a: *Assembler, l: *Line, zero: bool) Error!void {
    const t = l.take();
    if (t.tag != .string) return a.fail("expected a string, found '{s}'", .{t.text});
    try a.stringBytes(t);
    if (zero) try a.store(0);
}

/// The bytes of a string token: sjasmplus escapes in "...", and '' for a
/// quote in '...'.
const StringBytes = struct {
    text: []const u8,
    quote: u8,
    pos: usize = 1,

    fn init(token_text: []const u8) StringBytes {
        return .{ .text = token_text[0 .. token_text.len - 1], .quote = token_text[0] };
    }
};

fn stringByte(a: *Assembler, it: *StringBytes) Error!?u8 {
    if (it.pos >= it.text.len) return null;
    const c = it.text[it.pos];
    it.pos += 1;
    if (c == '\'' and it.quote == '\'') {
        it.pos += 1; // the second quote of ''
        return c;
    }
    if (c != '\\' or it.quote != '"') return c;
    const e = it.text[it.pos];
    it.pos += 1;
    return switch (std.ascii.toLower(e)) {
        '\\', '\'', '"', '?' => e,
        '0' => 0,
        'a' => 7,
        'b' => 8,
        'd' => 0x7F,
        'e' => 0x1B,
        'f' => 0x0C,
        'n' => 0x0A,
        'r' => 0x0D,
        't' => 0x09,
        'v' => 0x0B,
        else => a.fail("unknown escape '\\{c}' in string", .{e}),
    };
}

fn stringBytes(a: *Assembler, t: Token) Error!void {
    var it: StringBytes = .init(t.text);
    while (try a.stringByte(&it)) |c| try a.store(c);
}

fn dataWords(a: *Assembler, l: *Line) Error!void {
    while (true) {
        const w = a.wordOf(try a.expression(l));
        try a.bytes(&.{ @truncate(w), @truncate(w >> 8) });
        if (!l.eat(.comma)) return;
    }
}

fn reserve(a: *Assembler, l: *Line) Error!void {
    const count = try a.expression(l);
    const fill = if (l.eat(.comma)) a.byteOf(try a.expression(l)) else 0;
    if (!count.known) return;
    if (count.value < 0 or count.value > 0x10000) return a.fail("DS count {d} out of range", .{count.value});
    for (0..@intCast(count.value)) |_| try a.store(fill);
}
