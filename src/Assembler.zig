//! Z80 assembler core. Works the same at comptime and at runtime: no allocator,
//! no I/O. The caller provides the output, symbol and diagnostic buffers.
//!
//! Input is a "body" that is executed once per pass. It can assemble source
//! text line by line (`line`), call the instruction API directly (`emit`,
//! `label`, `word`, ...), or mix both. Labels defined later in the body get
//! their value in the next pass, so forward references work in both styles.

const std = @import("std");
const builtin = @import("builtin");
const isa = @import("isa.zig");
const formats = @import("formats.zig");
const Machine = @import("machine.zig").Machine;
const Lexer = @import("Lexer.zig");
const Token = Lexer.Token;

const Assembler = @This();

pub const max_passes = 8;
pub const max_line_tokens = 64;
pub const message_capacity = 120;

/// Tokens point into temporary copies of source lines. In tests and Debug
/// builds each copy is overwritten with `poison_byte` after its line, so a name
/// that was kept without going through `kept` turns into garbage and fails a test.
const poison_copies = builtin.is_test or builtin.mode == .Debug;
const poison_byte = 0xAA;

/// Hash tables are kept at most half full, so a probe always reaches a free
/// slot: a table needs this many slots for each entry it holds.
pub const slots_per_entry = 2;

const address_space = 0x10000;

pub const Error = error{AssemblyFailed};

pub const Options = struct {
    /// Address of the first byte when the source does not start with ORG;
    /// without it, the machine's origin, or 0.
    origin: ?u16 = null,
    /// A preset of the output format and the default origin.
    machine: ?Machine = null,
    /// The output format; without it, the machine's, or bin.
    format: ?formats.Format = null,

    fn defaultOrigin(o: Options) u16 {
        return o.origin orelse if (o.machine) |m| m.origin() else 0;
    }

    fn outputFormat(o: Options) formats.Format {
        return o.format orelse if (o.machine) |m| m.format() else .bin;
    }
};

/// A slot of the symbol hash table; an empty name marks a free slot.
pub const Symbol = struct {
    name: []const u8,
    /// For sdas local labels such as 00101$: the label they belong to.
    scope: []const u8,
    hash: u32,
    value: Value,
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
    /// Hash table slots. Only the largest power of two that fits is used, and
    /// it holds at most half as many symbols as it has slots.
    symbols: []Symbol,
    diagnostics: []Diagnostic,
};

/// Fixed-capacity storage for one assembly, usable as a comptime or stack
/// variable. `symbol_slots` must be a power of two; half of it is the symbol limit.
pub fn Workspace(comptime output_size: usize, comptime symbol_slots: usize, comptime diagnostic_count: usize) type {
    if (!std.math.isPowerOfTwo(symbol_slots)) @compileError("symbol_slots must be a power of two");
    return struct {
        output: [output_size]u8,
        symbols: [symbol_slots]Symbol,
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
    /// The operand of END: where execution starts. Null without one.
    entry: ?u16,
    /// The format the image is for; `formats.write` makes the file.
    format: formats.Format,
    diagnostics: []const Diagnostic,
    /// Diagnostics that did not fit in the buffer.
    diagnostics_dropped: usize,
    passes: u8,

    pub fn ok(r: Result) bool {
        return r.diagnostics.len == 0 and r.diagnostics_dropped == 0;
    }

    pub fn image(r: Result) formats.Image {
        return .{ .bytes = r.bytes, .origin = r.origin, .entry = r.entry };
    }
};

/// A value from an expression. `known` is false while a forward reference has
/// no value yet; such values are placeholders and are never range-checked.
pub const Value = struct {
    value: i32,
    known: bool = true,
};

options: Options,
/// Address of the first byte when the source does not start with ORG.
default_origin: u16,
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
/// Set by END. The rest of a source is not read, and code that a Zig body
/// emits afterwards is an error.
ended: bool = false,
/// The operand of END.
entry: ?u16 = null,
/// Uses of symbols without a value in this pass.
unresolved: u32 = 0,
/// Last symbol whose value differs from the previous pass.
changed: ?[]const u8 = null,
/// Last ordinary label; scope of the following sdas local labels.
scope: []const u8 = "",
/// Current sdas area when it is not _CODE. Areas are placed by the SDCC
/// linker, which z80asm does not replace, so only _CODE may hold anything.
other_area: ?[]const u8 = null,
/// The line being assembled, as given by the caller. Tokens point into a
/// temporary copy of it.
original: []const u8 = "",
/// One bit per address, for overlap checks. A byte slice into a local array
/// of run(): at comptime, changing an element of a [1024]usize field of this
/// struct costs about 8 KB of compiler memory per write.
written: []u8,
empty: bool = true,
low: u32 = 0,
high: u32 = 0,
overlap_reported: bool = false,

/// Runs `body(ctx, assembler)` once per pass until every symbol has a stable
/// value. The body is executed several times, so it must not have side effects
/// outside the assembler: it has to do the same thing on every call.
///
/// Symbol names are not copied. The names given to `label` and `equ`, and the
/// text given to `line`, must stay valid and unchanged until `run` returns;
/// a reused formatting buffer would rename earlier symbols.
pub fn run(options: Options, buffers: Buffers, ctx: anytype, comptime body: fn (@TypeOf(ctx), *Assembler) Error!void) Result {
    const slots = if (buffers.symbols.len == 0) 0 else std.math.floorPowerOfTwo(usize, buffers.symbols.len);
    var written: [address_space / @bitSizeOf(u8)]u8 = undefined;
    var a: Assembler = .{
        .options = options,
        .default_origin = options.defaultOrigin(),
        .out = buffers.output,
        .symbols = buffers.symbols[0..slots],
        .diagnostics = buffers.diagnostics,
        .written = &written,
    };
    for (a.symbols) |*s| s.name = "";
    while (true) {
        a.beginPass();
        body(ctx, &a) catch |err| switch (err) {
            error.AssemblyFailed => {}, // already in the diagnostics
        };
        // A second pass is needed only for forward references, and later
        // passes only while some symbol still moves.
        if (a.pass == 1 and a.unresolved == 0) break;
        if (a.pass > 1 and a.changed == null) break;
        if (a.pass == max_passes) {
            a.report("phase error: label '{s}' did not settle", .{a.changed.?});
            break;
        }
    }
    const format = options.outputFormat();
    if (formats.requiredOrigin(format)) |origin| {
        if (!a.empty and a.low != origin) a.report("the {t} format needs origin 0x{X:0>4}, not 0x{X:0>4}", .{ format, origin, a.low });
    }
    return .{
        .origin = if (a.empty) a.default_origin else @intCast(a.low),
        .bytes = a.out[0 .. a.high - a.low],
        .entry = a.entry,
        .format = format,
        .diagnostics = a.diagnostics[0..a.diagnostic_count],
        .diagnostics_dropped = a.diagnostics_dropped,
        .passes = a.pass,
    };
}

/// Assembles a whole source text, up to its END if it has one.
pub fn assemble(source: []const u8, options: Options, buffers: Buffers) Result {
    return run(options, buffers, source, assembleLines);
}

fn assembleLines(source: []const u8, a: *Assembler) Error!void {
    var reader: LineReader = .{ .source = source };
    var start: usize = 0;
    var number: u32 = 0;
    while (start <= source.len and !a.ended) {
        const next = reader.line(start);
        const text = source[start..next.end];
        number += 1;
        a.line_number = number;
        a.assembleLine(text, next.copy orelse text) catch |err| switch (err) {
            error.AssemblyFailed => {}, // already in the diagnostics
        };
        if (poison_copies) if (next.copy) |c| @memset(c, poison_byte);
        start = next.end + 1;
    }
    a.line_number = 0;
}

/// Hands out the lines of the source as copies in a local buffer. At comptime,
/// each read from the source (an @embedFile, say) takes time proportional to
/// its offset in the file, so reading it byte by byte is quadratic; a block
/// copied with one @memcpy pays that cost once.
const LineReader = struct {
    const block_size = 4096;

    source: []const u8,
    buf: [block_size]u8 = undefined,
    /// Source offset of buf[0].
    buf_start: usize = 0,
    buf_len: usize = 0,

    /// The line that starts at `start`: `copy` is it as a slice of the buffer,
    /// or null when it is longer than the buffer, and `end` is the offset of its
    /// '\n' or the end of the source.
    fn line(r: *LineReader, start: usize) struct { copy: ?[]u8, end: usize } {
        while (true) {
            if (start >= r.buf_start and start <= r.buf_start + r.buf_len) {
                const from = start - r.buf_start;
                const i = from + lineEnd(r.buf[from..r.buf_len]);
                if (i < r.buf_len or r.buf_start + r.buf_len == r.source.len) {
                    return .{ .copy = r.buf[from..i], .end = r.buf_start + i };
                }
                if (from == 0 and r.buf_len == r.buf.len) {
                    return .{ .copy = null, .end = start + lineEnd(r.source[start..]) };
                }
            }
            r.buf_start = start;
            r.buf_len = @min(r.buf.len, r.source.len - start);
            @memcpy(r.buf[0..r.buf_len], r.source[start..][0..r.buf_len]);
        }
    }
};

/// Index of the first '\n' in `text`, or `text.len`. Compares 32 bytes at a
/// time, as one vector compare is much cheaper than 32 loop steps at comptime.
fn lineEnd(text: []const u8) usize {
    const vector_len = 32;
    const V = @Vector(vector_len, u8);
    var i: usize = 0;
    while (i + vector_len <= text.len) : (i += vector_len) {
        const chunk: V = text[i..][0..vector_len].*;
        if (@reduce(.Or, chunk == @as(V, @splat('\n')))) break;
    }
    while (i < text.len and text[i] != '\n') i += 1;
    return i;
}

/// The per-pass fields are reset one by one. Kept in a struct and reset with one
/// assignment, they made the Spectrum ROM about 0.5 s slower at comptime.
fn beginPass(a: *Assembler) void {
    a.pass += 1;
    a.pc = a.default_origin;
    a.statement_pc = a.pc;
    a.ended = false;
    a.entry = null;
    a.unresolved = 0;
    a.changed = null;
    a.scope = "";
    a.other_area = null;
    a.diagnostic_count = 0;
    a.diagnostics_dropped = 0;
    @memset(a.written, 0);
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

/// Address of the next byte.
pub fn here(a: *const Assembler) u16 {
    return @truncate(a.pc);
}

pub fn org(a: *Assembler, address: u16) void {
    a.pc = address;
}

/// `name` is kept, not copied; see `run`.
pub fn label(a: *Assembler, name: []const u8) Error!void {
    try a.checkArea();
    try a.define(name, .{ .value = @intCast(a.pc) });
    if (!isLocal(name)) a.scope = name;
}

/// `name` is kept, not copied; see `run`.
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
    try a.expectFits(&l);
    const v = try a.expression(&l);
    try a.expectEnd(&l);
    return v;
}

/// An expression as an 8-bit operand, -128..255. A value out of range is
/// reported and truncated, not returned as an error (see `report`).
pub fn byte(a: *Assembler, text: []const u8) Error!u8 {
    return a.byteOf(try a.eval(text));
}

/// An expression as a 16-bit operand, -32768..65535; out of range as in `byte`.
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
    if (a.ended) return a.fail("code after END", .{});
    try a.checkArea();
    if (a.pc > 0xFFFF) return a.fail("address beyond 0xFFFF", .{});
    const addr = a.pc;
    const bit = @as(u8, 1) << @as(u3, @truncate(addr));
    if (a.written[addr >> 3] & bit != 0) {
        if (!a.overlap_reported) a.report("overlap at 0x{X:0>4}: address written twice", .{addr});
        a.overlap_reported = true;
    }
    a.written[addr >> 3] |= bit;

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

/// FNV-1a over the name and, for local labels, the scope. Written out because
/// std.hash.Fnv1a_32, with its init, update and final calls, made the Spectrum
/// ROM about 0.25 s slower at comptime.
fn hashName(name: []const u8, scope: []const u8) u32 {
    var h: u32 = 0x811C9DC5;
    for (name) |c| h = (h ^ c) *% 0x01000193;
    for (scope) |c| h = (h ^ c) *% 0x01000193;
    return h;
}

/// The slot holding `name`, or the free slot where it belongs. The table is
/// never more than half full, so the probe always ends.
fn slot(a: *Assembler, name: []const u8, scope: []const u8, hash: u32) *Symbol {
    const mask = a.symbols.len - 1;
    var i = hash & mask;
    while (true) : (i = (i + 1) & mask) {
        const s = &a.symbols[i];
        if (s.name.len == 0) return s;
        if (s.hash == hash and std.mem.eql(u8, s.name, name) and std.mem.eql(u8, s.scope, scope)) return s;
    }
}

/// The scope `name` is looked up in: the current one for local labels.
fn scopeOf(a: *const Assembler, name: []const u8) []const u8 {
    return if (isLocal(name)) a.scope else "";
}

fn find(a: *Assembler, name: []const u8) ?*Symbol {
    if (a.symbol_count == 0) return null;
    const scope = a.scopeOf(name);
    const s = a.slot(name, scope, hashName(name, scope));
    return if (s.name.len == 0) null else s;
}

fn define(a: *Assembler, name: []const u8, v: Value) Error!void {
    const capacity = a.symbols.len / slots_per_entry;
    // Also keeps `slot` away from a table without slots.
    if (capacity == 0) return a.fail("too many symbols (capacity 0)", .{});
    const scope = a.scopeOf(name);
    const hash = hashName(name, scope);
    const s = a.slot(name, scope, hash);
    if (s.name.len != 0) {
        if (s.pass == a.pass) return a.fail("duplicate symbol '{s}'", .{name});
        if (!std.meta.eql(s.value, v)) a.changed = s.name;
        s.value = v;
        s.pass = a.pass;
        return;
    }
    if (a.symbol_count == capacity) return a.fail("too many symbols (capacity {d})", .{capacity});
    s.* = .{ .name = name, .scope = scope, .hash = hash, .value = v, .pass = a.pass };
    a.symbol_count += 1;
    if (a.pass > 1) a.changed = name;
}

fn symbolValue(a: *Assembler, name: []const u8) Value {
    if (a.find(name)) |s| {
        if (!s.value.known) {
            a.unresolved += 1;
            // Defined, but only in terms of itself or of undefined symbols.
            if (a.pass > 1) a.report("symbol '{s}' has no value", .{name});
        }
        return s.value;
    }
    a.unresolved += 1;
    // In pass 1 this may be a label further down; only later passes know.
    if (a.pass > 1) a.report("undefined symbol '{s}'", .{name});
    return .{ .value = 0, .known = false };
}

// Value checks are skipped for unknown values and only record a diagnostic,
// so they are reported in the pass where everything is known.

fn outside(v: Value, min: i32, max: i32) bool {
    return v.known and (v.value < min or v.value > max);
}

/// Out of range: reported, and the low 8 bits are used, as in wordOf and
/// bitOf. displacementOf differs on purpose. Both keep the instruction size,
/// and the tool and comptimeAssemble never write the bytes of a result with
/// diagnostics.
fn byteOf(a: *Assembler, v: Value) u8 {
    if (outside(v, std.math.minInt(i8), std.math.maxInt(u8))) a.report("value {d} does not fit in 8 bits", .{v.value});
    return @truncate(@as(u32, @bitCast(v.value)));
}

fn wordOf(a: *Assembler, v: Value) u16 {
    if (outside(v, std.math.minInt(i16), std.math.maxInt(u16))) a.report("value {d} does not fit in 16 bits", .{v.value});
    return @truncate(@as(u32, @bitCast(v.value)));
}

/// Out of range: reported, and 0 is used instead of the low 8 bits, on
/// purpose, as in relativeOf, restart and interruptMode. The image that
/// `assemble` returns with the diagnostic then holds (IX+0), not a wrapped
/// displacement that looks valid, such as (IX-56) for (IX+200).
fn displacementOf(a: *Assembler, v: Value) i8 {
    if (outside(v, std.math.minInt(i8), std.math.maxInt(i8))) {
        a.report("index displacement {d} out of range -128..127", .{v.value});
        return 0;
    }
    return @truncate(v.value);
}

/// Length of JR and of DJNZ.
const jr_len = isa.jr(0).len;

/// Offset of a JR/DJNZ target from the end of the instruction.
fn relativeOf(a: *Assembler, target: Value) i8 {
    if (!target.known) return 0;
    const offset = @as(i64, target.value) - (a.statement_pc + jr_len);
    return std.math.cast(i8, offset) orelse {
        a.report("relative jump out of range ({d} bytes)", .{offset});
        return 0;
    };
}

fn bitOf(a: *Assembler, v: Value) u3 {
    if (outside(v, 0, std.math.maxInt(u3))) a.report("bit number {d} out of range 0..7", .{v.value});
    return @truncate(@as(u32, @bitCast(v.value)));
}

/// The tokens of one line. When a line has more tokens than fit, `tokens`
/// holds the first ones and an `.end` in the last slot, and `truncated` is
/// set; only DB and DW read on (see `nextValue`).
const Line = struct {
    tokens: [max_line_tokens]Token,
    len: usize = 0,
    pos: usize = 0,
    lexer: Lexer,
    truncated: bool = false,

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

    /// Leaves only the `.end` token, for directives whose operands are ignored.
    fn skipRest(l: *Line) void {
        l.pos = l.len - 1;
    }

    fn commaAhead(l: *const Line) bool {
        for (l.tokens[l.pos..l.len]) |t| {
            if (t.tag == .comma) return true;
        }
        return false;
    }
};

fn tokenize(a: *Assembler, text: []const u8) Error!Line {
    var l: Line = .{ .tokens = undefined, .lexer = .init(text) };
    try a.lex(&l);
    return l;
}

/// Fills the free slots of `l.tokens` from its lexer.
fn lex(a: *Assembler, l: *Line) Error!void {
    l.truncated = false;
    while (true) {
        const t = l.lexer.next();
        switch (t.tag) {
            .invalid => return a.fail("unexpected character '{s}'", .{t.text}),
            .unterminated_string => return a.fail("unterminated string", .{}),
            else => {},
        }
        if (l.len == max_line_tokens - 1 and t.tag != .end) {
            l.lexer.pos = t.col;
            l.tokens[l.len] = .{ .tag = .end, .text = "", .col = t.col };
            l.len += 1;
            l.truncated = true;
            return;
        }
        l.tokens[l.len] = t;
        l.len += 1;
        if (t.tag == .end) return;
    }
}

fn expectFits(a: *Assembler, l: *const Line) Error!void {
    if (l.truncated) return a.fail("line has more than {d} tokens", .{max_line_tokens});
}

/// Longest value of DB and DW: the token buffer must also hold the comma after
/// it, and its last slot holds the `.end`.
const max_value_tokens = max_line_tokens - 2;

/// Before each value of DB and DW: on a truncated line, drops the tokens
/// already used and lexes on when the next value might not be complete.
fn nextValue(a: *Assembler, l: *Line) Error!void {
    if (!l.truncated or l.commaAhead()) return;
    const rest = l.len - 1 - l.pos;
    std.mem.copyForwards(Token, l.tokens[0..rest], l.tokens[l.pos..][0..rest]);
    l.len = rest;
    l.pos = 0;
    try a.lex(l);
    if (l.truncated and !l.commaAhead()) return a.fail("value has more than {d} tokens", .{max_value_tokens});
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

// A switch rather than a std.EnumArray constant, which made the Spectrum ROM
// 0.5 s slower at comptime. A higher precedence binds tighter.
fn binaryOperator(tag: Token.Tag) ?struct { op: Operator, precedence: u8 } {
    return switch (tag) {
        .pipe => .{ .op = .@"or", .precedence = 1 },
        .caret => .{ .op = .xor, .precedence = 2 }, // smell-ok: precedence level
        .ampersand => .{ .op = .@"and", .precedence = 3 }, // smell-ok: precedence level
        .shift_left => .{ .op = .shl, .precedence = 4 }, // smell-ok: precedence level
        .shift_right => .{ .op = .shr, .precedence = 4 }, // smell-ok: precedence level
        .plus => .{ .op = .add, .precedence = 5 }, // smell-ok: precedence level
        .minus => .{ .op = .sub, .precedence = 5 }, // smell-ok: precedence level
        .asterisk => .{ .op = .mul, .precedence = 6 }, // smell-ok: precedence level
        .slash => .{ .op = .div, .precedence = 6 }, // smell-ok: precedence level
        .percent => .{ .op = .mod, .precedence = 6 }, // smell-ok: precedence level
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
        .shl => if (std.math.cast(u5, y)) |n| x << n else 0,
        .shr => if (std.math.cast(u5, y)) |n| x >> n else 0,
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
            var it: StringIterator = .init(t.text);
            const c = try it.next(a) orelse return a.fail("string {s} used as a number", .{t.text});
            if (try it.next(a) != null) return a.fail("string {s} used as a number", .{t.text});
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
    // Byte comparisons rather than std.mem.startsWith and friends: those calls,
    // about 19,000 for the Spectrum ROM, cost 0.5 s at comptime.
    const hex = "0x";
    const bin = "0b";
    if (text.len > hex.len and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) return parseDigits(text[hex.len..], 16);
    if (text.len > 1 and text[0] == '$') return parseDigits(text[1..], 16);
    const last = text[text.len - 1];
    if (text.len > 1 and (last == 'h' or last == 'H')) return parseDigits(text[0 .. text.len - 1], 16);
    if (text.len > bin.len and text[0] == '0' and (text[1] == 'b' or text[1] == 'B')) return parseDigits(text[bin.len..], 2);
    if (text.len > 1 and (last == 'b' or last == 'B')) return parseDigits(text[0 .. text.len - 1], 2);
    return parseDigits(text, 10);
}

fn parseDigits(digits: []const u8, base: u8) ?i32 {
    const v = std.fmt.parseUnsigned(u32, digits, base) catch return null;
    return if (v > std.math.maxInt(i32)) null else @intCast(v);
}

const Reg = enum { a, b, c, d, e, h, l, i, r, ixh, ixl, iyh, iyl, af, @"af'", bc, de, hl, sp, ix, iy };

fn register(name: []const u8) ?Reg {
    return NameTable(Reg).get(name);
}

/// Building a NameTable hashes every tag name byte by byte and probes for a
/// free slot; the default quota of 1000 branches is too small for Keyword.
const name_table_quota = 100_000;

/// Case-insensitive lookup of an enum by tag name through a hash table built at
/// comptime. std.meta.stringToEnum on a lowercased copy is much slower when the
/// assembler runs at comptime.
fn NameTable(comptime E: type) type {
    const fields = @typeInfo(E).@"enum".fields;
    const size = std.math.ceilPowerOfTwoAssert(usize, slots_per_entry * fields.len);
    const max_len = blk: {
        var m: usize = 0;
        for (fields) |f| m = @max(m, f.name.len);
        break :blk m;
    };
    return struct {
        const slots: [size]?E = blk: {
            @setEvalBranchQuota(name_table_quota);
            var table: [size]?E = @splat(null);
            for (fields) |f| {
                var i = hashLower(f.name) & (size - 1);
                while (table[i] != null) i = (i + 1) & (size - 1);
                table[i] = @field(E, f.name);
            }
            break :blk table;
        };

        fn get(name: []const u8) ?E {
            if (name.len > max_len) return null;
            var i = hashLower(name) & (size - 1);
            while (slots[i]) |e| : (i = (i + 1) & (size - 1)) {
                if (std.ascii.eqlIgnoreCase(@tagName(e), name)) return e;
            }
            return null;
        }
    };
}

/// FNV-1a over the lowercased bytes.
fn hashLower(s: []const u8) u32 {
    var h: u32 = 0x811C9DC5;
    for (s) |c| h = (h ^ std.ascii.toLower(c)) *% 0x01000193;
    return h;
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

    fn isReg(op: Operand, r: Reg) bool {
        return op == .reg and op.reg == r;
    }

    fn isMemReg(op: Operand, r: Reg) bool {
        return op == .mem_reg and op.mem_reg == r;
    }

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
    if (l.peek().tag == .l_paren and l.peekAt(2).tag == .r_paren) { // smell-ok: the ")" after "(" and the register
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

/// Operands of LD, EX and OUT, the instructions that take two.
const max_operands = 2;

fn operandPair(a: *Assembler, l: *Line) Error![max_operands]Operand {
    const first = try a.operand(l);
    try a.expect(l, .comma, "','");
    return .{ first, try a.operand(l) };
}

/// Condition code at the start of a JP/JR/CALL/RET operand list: the only
/// operand of RET, or the first one, before a comma, of the others.
fn condition(l: *Line, comptime position: enum { only, first }) ?isa.Cc {
    const t = l.peek();
    if (t.tag != .identifier) return null;
    if (position == .first and l.peekAt(1).tag != .comma) return null;
    const cc = NameTable(isa.Cc).get(t.text) orelse return null;
    _ = l.take();
    if (position == .first) _ = l.take();
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
    return NameTable(Keyword).get(name);
}

/// Assembles one line of source text. Labels defined on the line keep
/// pointing into `text`; see `run`.
pub fn line(a: *Assembler, text: []const u8) Error!void {
    // Work on a copy for the same reason as LineReader. Longer lines are parsed
    // in place.
    const copy_size = 256;
    var buf: [copy_size]u8 = undefined;
    if (text.len > buf.len) return a.assembleLine(text, text);
    @memcpy(buf[0..text.len], text);
    defer if (poison_copies) @memset(buf[0..text.len], poison_byte);
    return a.assembleLine(text, buf[0..text.len]);
}

/// `copy` holds the same bytes as `original` and is what gets parsed; names
/// that outlive the line are taken from `original` (see `kept`).
fn assembleLine(a: *Assembler, original: []const u8, copy: []const u8) Error!void {
    a.statement_pc = a.pc;
    a.original = original;
    var l = try a.tokenize(copy);

    // A label is "name:" / "name::" anywhere, or a name in column 0 that is
    // not an instruction or directive.
    var name: ?[]const u8 = null;
    const first = l.peek();
    if (first.tag == .identifier) {
        const next = l.peekAt(1).tag;
        if (next == .colon or next == .double_colon) {
            name = a.kept(first);
            _ = l.take();
            _ = l.take();
        } else if (first.col == 0 and keyword(first.text) == null) {
            name = a.kept(first);
            _ = l.take();
        }
    }

    if (name) |n| {
        const t = l.peek();
        if (t.tag == .equal or (t.tag == .identifier and keyword(t.text) == .equ)) {
            _ = l.take();
            try a.expectFits(&l);
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

/// A token of the current line as a slice of the caller's text, for names kept
/// after the line; the token itself points into a temporary copy.
fn kept(a: *const Assembler, t: Token) []const u8 {
    return a.original[t.col..][0..t.text.len];
}

fn statement(a: *Assembler, l: *Line, kw: Keyword) Error!void {
    switch (kw) {
        .db, .defb, .defm, .dm, .@".db", .@".byte" => return a.dataBytes(l),
        .dw, .defw, .@".dw", .@".word" => return a.dataWords(l),
        else => try a.expectFits(l),
    }

    return switch (kw) {
        .db, .defb, .defm, .dm, .@".db", .@".byte", .dw, .defw, .@".dw", .@".word" => unreachable, // DB and DW return from the switch above
        inline .nop,
        .halt,
        .ei,
        .di,
        .exx,
        .rlca,
        .rrca,
        .rla,
        .rra,
        .daa,
        .cpl,
        .scf,
        .ccf,
        .neg,
        .retn,
        .reti,
        .rrd,
        .rld,
        .ldi,
        .ldd,
        .ldir,
        .lddr,
        .cpi,
        .cpd,
        .cpir,
        .cpdr,
        .ini,
        .ind,
        .inir,
        .indr,
        .outi,
        .outd,
        .otir,
        .otdr,
        => |k| a.emit(@field(isa, @tagName(k))()),
        .ld => a.emit(try a.encodeLd(try a.operandPair(l))),
        inline .add, .adc, .sub, .sbc, .@"and", .xor, .@"or", .cp => |k| a.alu(l, @field(isa.Alu, @tagName(k))),
        .inc => a.incDec(l, .inc),
        .dec => a.incDec(l, .dec),
        .push => a.pushPop(l, .push),
        .pop => a.pushPop(l, .pop),
        .jp => a.jump(l),
        .call => a.callStatement(l),
        .jr => a.relativeJump(l, .jr),
        .djnz => a.relativeJump(l, .djnz),
        .ret => if (condition(l, .only)) |cc| a.emit(isa.retCc(cc)) else a.emit(isa.ret()),
        .rst => a.restart(l),
        .ex => a.exchange(l),
        .in => a.input(l),
        .out => a.output(l),
        .im => a.interruptMode(l),
        inline .bit, .set, .res => |k| a.bitStatement(l, @field(BitOp, @tagName(k))),
        inline .rlc, .rrc, .rl, .rr, .sla, .sra, .sll, .srl => |k| a.rotate(l, @field(isa.Rot, @tagName(k))),
        .sli => a.rotate(l, .sll),
        .org, .@".org" => a.org(a.wordOf(try a.expression(l))),
        .@".ascii" => a.asciiString(l, .ascii),
        .@".asciz" => a.asciiString(l, .asciz),
        .ds, .defs, .@".ds" => a.reserve(l),
        .end => {
            // "END start" names the entry point.
            if (!l.atEnd()) a.entry = a.wordOf(try a.expression(l));
            a.ended = true;
        },
        .equ => a.fail("EQU needs a label", .{}),
        .@".area" => {
            const name = l.take();
            if (name.tag != .identifier) return a.fail("expected an area name, found '{s}'", .{name.text});
            a.other_area = if (std.mem.eql(u8, name.text, "_CODE")) null else a.kept(name);
            l.skipRest(); // "(ABS)" and other attributes
        },
        .@".globl", .@".module", .@".optsdcc" => l.skipRest(),
    };
}

fn invalid(a: *Assembler) Error {
    return a.fail("invalid operands", .{});
}

fn encodeLd(a: *Assembler, ops: [max_operands]Operand) Error!isa.Encoding {
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
            if (d == .i and src.isReg(.a)) return isa.ldIA();
            if (d == .r and src.isReg(.a)) return isa.ldRA();
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
            if (src.isReg(.a)) {
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
                const rr = (if (rhs == .reg) pair(rhs.reg) else null) orelse return a.invalid();
                return a.emit(switch (op) {
                    .add => isa.addHlRr(rr),
                    .adc => isa.adcHlRr(rr),
                    .sbc => isa.sbcHlRr(rr),
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

fn incDec(a: *Assembler, l: *Line, op: enum { inc, dec }) Error!void {
    const target = try a.operand(l);
    const inc = op == .inc;
    if (target.r8()) |r| return a.emit(if (inc) isa.incR(r) else isa.decR(r));
    if (target.indexed()) |m| return a.emit(if (inc) isa.incIdxD(m.idx, m.d) else isa.decIdxD(m.idx, m.d));
    if (target == .reg) {
        if (pair(target.reg)) |rr| return a.emit(if (inc) isa.incRr(rr) else isa.decRr(rr));
        if (index(target.reg)) |idx| return a.emit(if (inc) isa.incIdx(idx) else isa.decIdx(idx));
        if (half(target.reg)) |h| return a.emit(isa.indexHalf(h.idx, if (inc) isa.incR(h.reg) else isa.decR(h.reg)));
    }
    return a.invalid();
}

fn pushPop(a: *Assembler, l: *Line, op: enum { push, pop }) Error!void {
    const target = try a.operand(l);
    if (target != .reg) return a.invalid();
    if (index(target.reg)) |idx| return a.emit(if (op == .push) isa.pushIdx(idx) else isa.popIdx(idx));
    const rr: isa.R16af = switch (target.reg) {
        .bc => .bc,
        .de => .de,
        .hl => .hl,
        .af => .af,
        else => return a.invalid(),
    };
    return a.emit(if (op == .push) isa.push(rr) else isa.pop(rr));
}

fn jump(a: *Assembler, l: *Line) Error!void {
    if (condition(l, .first)) |cc| {
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
    const cc = condition(l, .first);
    const target = try a.operand(l);
    if (target != .imm) return a.invalid();
    const nn = a.wordOf(target.imm);
    return a.emit(if (cc) |c| isa.callCc(c, nn) else isa.call(nn));
}

fn relativeJump(a: *Assembler, l: *Line, op: enum { jr, djnz }) Error!void {
    const cc = if (op == .djnz) null else condition(l, .first);
    if (cc) |c| switch (c) {
        .nz, .z, .nc, .c => {},
        else => return a.fail("JR supports only NZ, Z, NC and C", .{}),
    };
    const target = try a.operand(l);
    if (target != .imm) return a.invalid();
    const e = a.relativeOf(target.imm);
    if (op == .djnz) return a.emit(isa.djnz(e));
    return a.emit(if (cc) |c| isa.jrCc(c, e) else isa.jr(e));
}

fn restart(a: *Assembler, l: *Line) Error!void {
    const target_bits = 0x38; // 0x00, 0x08, ..., 0x38: only bits 3 to 5
    const v = try a.expression(l);
    if (v.known and v.value & ~@as(i32, target_bits) != 0) {
        a.report("RST target must be one of 0x00, 0x08, ..., 0x38", .{});
        return a.emit(isa.rst(0));
    }
    return a.emit(isa.rst(if (v.known) @intCast(v.value) else 0));
}

fn exchange(a: *Assembler, l: *Line) Error!void {
    const dst, const src = try a.operandPair(l);
    if (dst.isReg(.af) and src.isReg(.@"af'")) return a.emit(isa.exAf());
    if (dst.isReg(.de) and src.isReg(.hl)) return a.emit(isa.exDeHl());
    if (dst.isMemReg(.sp) and src == .reg) {
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
        if (first.isMemReg(.c)) return a.emit(isa.inFC());
        return a.invalid();
    }
    const src = try a.operand(l);
    if (first != .reg) return a.invalid();
    const r = plain(first.reg) orelse return a.invalid();
    if (src.isMemReg(.c)) return a.emit(isa.inRC(r));
    if (src == .mem and r == .a) return a.emit(isa.inAN(a.byteOf(src.mem)));
    return a.invalid();
}

fn output(a: *Assembler, l: *Line) Error!void {
    const dst, const src = try a.operandPair(l);
    if (dst == .mem and src.isReg(.a)) return a.emit(isa.outNA(a.byteOf(dst.mem)));
    if (dst.isMemReg(.c)) {
        if (src == .reg) if (plain(src.reg)) |r| return a.emit(isa.outCR(r));
        if (src == .imm and src.imm.value == 0) return a.emit(isa.outC0());
    }
    return a.invalid();
}

fn interruptMode(a: *Assembler, l: *Line) Error!void {
    const v = try a.expression(l);
    if (!v.known) return a.emit(isa.im(.mode0));
    const mode = std.enums.fromInt(isa.Im, v.value) orelse {
        a.report("interrupt mode must be 0, 1 or 2", .{});
        return a.emit(isa.im(.mode0));
    };
    return a.emit(isa.im(mode));
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
        try a.nextValue(l);
        const t = l.peek();
        const next = l.peekAt(1).tag;
        if (t.tag == .string and (next == .comma or next == .end)) {
            _ = l.take();
            try a.emitString(t);
        } else {
            try a.store(a.byteOf(try a.expression(l)));
        }
        if (!l.eat(.comma)) return;
    }
}

fn asciiString(a: *Assembler, l: *Line, op: enum { ascii, asciz }) Error!void {
    const t = l.take();
    if (t.tag != .string) return a.fail("expected a string, found '{s}'", .{t.text});
    try a.emitString(t);
    if (op == .asciz) try a.store(0);
}

/// The bytes of a string token: sjasmplus escapes in "...", and '' for a
/// quote in '...'.
const StringIterator = struct {
    /// The token without its closing quote.
    text: []const u8,
    quote: u8,
    /// Past the opening quote.
    pos: usize = 1,

    fn init(token_text: []const u8) StringIterator {
        return .{ .text = token_text[0 .. token_text.len - 1], .quote = token_text[0] };
    }

    /// `a` reports unknown escapes.
    fn next(it: *StringIterator, a: *Assembler) Error!?u8 {
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
        const ascii = std.ascii.control_code;
        return switch (std.ascii.toLower(e)) {
            '\\', '\'', '"', '?' => e,
            '0' => ascii.nul,
            'a' => ascii.bel,
            'b' => ascii.bs,
            'd' => ascii.del,
            'e' => ascii.esc,
            'f' => ascii.ff,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'v' => ascii.vt,
            else => a.fail("unknown escape '\\{c}' in string", .{e}),
        };
    }
};

fn emitString(a: *Assembler, t: Token) Error!void {
    var it: StringIterator = .init(t.text);
    while (try it.next(a)) |c| try a.store(c);
}

fn dataWords(a: *Assembler, l: *Line) Error!void {
    while (true) {
        try a.nextValue(l);
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
