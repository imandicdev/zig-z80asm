//! Splits one source line into tokens. Problems such as a stray character or
//! an unterminated string come back as `.invalid` / `.unterminated_string`
//! tokens so the assembler can report them like any other error.
//!
//! '%' is always `.percent`: whether it is modulo or a binary prefix ("%1010")
//! depends on where the expression parser meets it.

const std = @import("std");

const Lexer = @This();

src: []const u8,
pos: usize = 0,

pub const Token = struct {
    tag: Tag,
    text: []const u8,
    /// Column of the first character, starting at 0.
    col: usize,

    pub const Tag = enum {
        identifier,
        number,
        string,
        l_paren,
        r_paren,
        comma,
        colon,
        double_colon,
        plus,
        minus,
        asterisk,
        slash,
        percent,
        ampersand,
        pipe,
        caret,
        tilde,
        shift_left,
        shift_right,
        less,
        greater,
        equal,
        hash,
        dollar,
        end,
        invalid,
        unterminated_string,
    };
};

pub fn init(line: []const u8) Lexer {
    return .{ .src = line };
}

pub fn next(l: *Lexer) Token {
    while (l.pos < l.src.len and (l.src[l.pos] == ' ' or l.src[l.pos] == '\t' or l.src[l.pos] == '\r')) {
        l.pos += 1;
    }
    const start = l.pos;
    if (l.pos >= l.src.len or l.src[l.pos] == ';') {
        l.pos = l.src.len;
        return l.token(.end, start);
    }

    const c = l.src[l.pos];
    l.pos += 1;
    const tag: Token.Tag = switch (c) {
        '(' => .l_paren,
        ')' => .r_paren,
        ',' => .comma,
        '+' => .plus,
        '-' => .minus,
        '*' => .asterisk,
        '/' => .slash,
        '&' => .ampersand,
        '|' => .pipe,
        '^' => .caret,
        '~' => .tilde,
        '=' => .equal,
        '#' => .hash,
        ':' => if (l.eat(':')) .double_colon else .colon,
        '<' => if (l.eat('<')) .shift_left else .less,
        '>' => if (l.eat('>')) .shift_right else .greater,
        '"', '\'' => return l.string(c, start),
        '$' => if (l.pos < l.src.len and std.ascii.isHex(l.src[l.pos])) return l.number(start) else .dollar,
        '%' => .percent,
        '0'...'9' => return l.number(start),
        else => if (isIdentStart(c)) return l.identifier(start) else .invalid,
    };
    return l.token(tag, start);
}

fn token(l: *Lexer, tag: Token.Tag, start: usize) Token {
    return .{ .tag = tag, .text = l.src[start..l.pos], .col = start };
}

fn eat(l: *Lexer, c: u8) bool {
    if (l.pos < l.src.len and l.src[l.pos] == c) {
        l.pos += 1;
        return true;
    }
    return false;
}

/// The whole alphanumeric run is taken so that "12G" is one bad number rather
/// than a number followed by an identifier. SDCC local labels such as 00101$
/// are digits followed by '$' and become identifiers.
fn number(l: *Lexer, start: usize) Token {
    var end = start;
    while (end < l.src.len and std.ascii.isDigit(l.src[end])) end += 1;
    if (end > start and end < l.src.len and l.src[end] == '$') {
        l.pos = end + 1;
        return l.token(.identifier, start);
    }
    while (l.pos < l.src.len and std.ascii.isAlphanumeric(l.src[l.pos])) l.pos += 1;
    return l.token(.number, start);
}

fn identifier(l: *Lexer, start: usize) Token {
    while (l.pos < l.src.len and isIdentChar(l.src[l.pos])) l.pos += 1;
    // AF' is the only identifier that may end in a quote.
    if (l.pos < l.src.len and l.src[l.pos] == '\'' and std.ascii.eqlIgnoreCase(l.src[start..l.pos], "af")) {
        l.pos += 1;
    }
    return l.token(.identifier, start);
}

/// Token text includes the quotes; the assembler decodes it. A backslash
/// escapes the next character in "...", and '' is a quote inside '...'.
fn string(l: *Lexer, quote: u8, start: usize) Token {
    while (l.pos < l.src.len) {
        const c = l.src[l.pos];
        l.pos += 1;
        if (c == '\\' and quote == '"') {
            l.pos += 1;
        } else if (c == quote) {
            if (quote == '\'' and l.pos < l.src.len and l.src[l.pos] == '\'') {
                l.pos += 1;
            } else {
                return l.token(.string, start);
            }
        }
    }
    l.pos = l.src.len;
    return l.token(.unterminated_string, start);
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '.';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.';
}

fn expectTags(line: []const u8, tags: []const Token.Tag) !void {
    var l = init(line);
    for (tags) |tag| try std.testing.expectEqual(tag, l.next().tag);
}

test "operators and punctuation" {
    try expectTags("(a+b)*2<<1>>3&4|5^~6", &.{
        .l_paren,    .identifier, .plus,        .identifier, .r_paren,   .asterisk, .number,
        .shift_left, .number,     .shift_right, .number,     .ampersand, .number,   .pipe,
        .number,     .caret,      .tilde,       .number,     .end,
    });
}

test "dollar is hex before a hex digit and the current address otherwise" {
    var l = init("$FF $ $+2");
    try std.testing.expectEqualStrings("$FF", l.next().text);
    try std.testing.expectEqual(.dollar, l.next().tag);
    try std.testing.expectEqual(.dollar, l.next().tag);
}

test "numbers are lexed as a whole" {
    var l = init("0FFh 12G 0x1F");
    try std.testing.expectEqualStrings("0FFh", l.next().text);
    try std.testing.expectEqualStrings("12G", l.next().text);
    try std.testing.expectEqualStrings("0x1F", l.next().text);
}

test "SDCC local labels, AF' and strings" {
    var l = init("00101$: ex af,af' \"a;b\" 'x");
    try std.testing.expectEqualStrings("00101$", l.next().text);
    _ = l.next();
    _ = l.next();
    _ = l.next();
    _ = l.next();
    try std.testing.expectEqualStrings("af'", l.next().text);
    const s = l.next();
    try std.testing.expectEqual(.string, s.tag);
    try std.testing.expectEqualStrings("\"a;b\"", s.text);
    try std.testing.expectEqual(.unterminated_string, l.next().tag);
}

test "escaped and doubled quotes do not end a string" {
    var l = init("\"a\\\"b\" 'it''s' \"x\\\"");
    try std.testing.expectEqualStrings("\"a\\\"b\"", l.next().text);
    try std.testing.expectEqualStrings("'it''s'", l.next().text);
    try std.testing.expectEqual(.unterminated_string, l.next().tag);
}

test "comment ends the line and stray characters are invalid" {
    try expectTags("nop ; ld a,b", &.{ .identifier, .end });
    try expectTags("ld a,@", &.{ .identifier, .identifier, .comma, .invalid });
}
