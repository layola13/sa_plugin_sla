const std = @import("std");

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub const Tag = enum {
        eof,
        invalid,
        identifier,

        // Literals
        int_literal,
        float_literal,
        string_literal,
        // Template literal pieces: `head ${expr} tail`
        template_start, // opening backtick
        template_string, // raw literal chunk (escapes unprocessed)
        template_interp, // ${
        template_end, // closing backtick

        // Keywords
        keyword_struct,
        keyword_union,
        keyword_enum,
        keyword_trait,
        keyword_overload,
        keyword_dyn,
        keyword_impl,
        keyword_mod,
        keyword_using,
        keyword_pub,
        keyword_extern,
        keyword_async,
        keyword_await,
        keyword_unsafe,
        keyword_as,
        keyword_fn,
        keyword_if,
        keyword_else,
        keyword_match,
        keyword_switch,
        keyword_return,
        keyword_for,
        keyword_while,
        keyword_break,
        keyword_continue,
        keyword_in,
        keyword_let,
        keyword_const,
        keyword_var,
        keyword_inline,
        keyword_macro,
        keyword_mut,
        keyword_type,

        // Symbols
        plus, // +
        plus_equal, // +=
        minus_equal, // -=
        asterisk_equal, // *=
        slash_equal, // /=
        percent_equal, // %=
        pipe_equal, // |=
        ampersand_equal, // &=
        minus, // -
        asterisk, // *
        slash, // /
        percent, // %
        equal, // =
        equal_equal, // ==
        bang_equal, // !=
        less_equal, // <=
        greater_equal, // >=
        ampersand, // &
        amp_amp, // &&
        caret, // ^
        bang, // !
        pipe, // |
        pipe_pipe, // ||
        less_less, // <<
        greater_greater, // >>
        spaceship, // <=>
        dot, // .
        comma, // ,
        semicolon, // ;
        colon, // :
        double_colon, // ::
        l_paren, // (
        r_paren, // )
        l_brace, // {
        r_brace, // }
        l_bracket, // [
        r_bracket, // ]
        less_than, // <
        greater_than, // >
        arrow, // ->
        fat_arrow, // =>
        range, // ..
        question_mark, // ?
        question_question, // ??
        question_question_equal, // ??=
        question_dot, // ?.
        at, // @
    };
};

pub const Lexer = struct {
    buffer: []const u8,
    index: usize,
    /// True while scanning template-literal text (between ` and ${ or `).
    in_template: bool = false,
    /// Open `${` depth while lexing an interpolation (0 at template level).
    /// `{`/`}` adjust it only when > 0, so plain blocks are untouched.
    interp_depth: u16 = 0,
    /// Saved interp depths for nested templates (cap 8, else invalid).
    tmpl_stack: [8]u16 = [_]u16{0} ** 8,
    tmpl_sp: u8 = 0,

    pub fn init(buffer: []const u8) Lexer {
        return .{
            .buffer = buffer,
            .index = 0,
        };
    }

    fn invalidAt(self: *Lexer, start: usize) Token {
        return Token{ .tag = .invalid, .loc = .{ .start = start, .end = self.index } };
    }

    /// Scans one template-literal piece. Called with in_template set;
    /// whitespace is significant here. Returns template_string chunks,
    /// template_interp (`${`), or template_end (closing backtick).
    fn nextTemplate(self: *Lexer) Token {
        // `${` opener.
        if (self.index + 1 < self.buffer.len and self.buffer[self.index] == '$' and self.buffer[self.index + 1] == '{') {
            const start = self.index;
            self.index += 2;
            self.in_template = false;
            self.interp_depth = 1;
            return Token{ .tag = .template_interp, .loc = .{ .start = start, .end = self.index } };
        }
        // Closing backtick.
        if (self.index < self.buffer.len and self.buffer[self.index] == '`') {
            const start = self.index;
            self.index += 1;
            if (self.tmpl_sp == 0) return self.invalidAt(start);
            self.tmpl_sp -= 1;
            self.interp_depth = self.tmpl_stack[self.tmpl_sp];
            self.in_template = false;
            return Token{ .tag = .template_end, .loc = .{ .start = start, .end = self.index } };
        }
        // Literal chunk up to (not consuming) `${`, backtick, or EOF.
        const start = self.index;
        while (self.index < self.buffer.len) {
            const c = self.buffer[self.index];
            if (c == '\\') {
                self.index += 2;
                continue;
            }
            if (c == '`') break;
            if (c == '$' and self.index + 1 < self.buffer.len and self.buffer[self.index + 1] == '{') break;
            self.index += 1;
        }
        if (self.index >= self.buffer.len) return self.invalidAt(start);
        return Token{ .tag = .template_string, .loc = .{ .start = start, .end = self.index } };
    }

    pub fn next(self: *Lexer) Token {
        // Template-literal text is significant whitespace: bypass skipping.
        if (self.in_template) return self.nextTemplate();
        self.skipWhitespace();

        if (self.index >= self.buffer.len) {
            return Token{
                .tag = .eof,
                .loc = .{ .start = self.index, .end = self.index },
            };
        }

        const start = self.index;
        const c = self.buffer[self.index];
        self.index += 1;

        switch (c) {
            '@' => return Token{ .tag = .at, .loc = .{ .start = start, .end = self.index } },
            '?' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '?') {
                    // `??=` (but not `??==`, which is `??` + `==`).
                    if (self.index + 1 < self.buffer.len and self.buffer[self.index + 1] == '=' and
                        (self.index + 2 >= self.buffer.len or self.buffer[self.index + 2] != '='))
                    {
                        self.index += 2;
                        return Token{ .tag = .question_question_equal, .loc = .{ .start = start, .end = self.index } };
                    }
                    self.index += 1;
                    return Token{ .tag = .question_question, .loc = .{ .start = start, .end = self.index } };
                }
                // `?.` is the optional chain, but NOT when a digit follows
                // (TS rule: `a?.5:0` stays ternary + number).
                if (self.index < self.buffer.len and self.buffer[self.index] == '.' and
                    (self.index + 1 >= self.buffer.len or !std.ascii.isDigit(self.buffer[self.index + 1])))
                {
                    self.index += 1;
                    return Token{ .tag = .question_dot, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .question_mark, .loc = .{ .start = start, .end = self.index } };
            },
            '+' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return Token{ .tag = .plus_equal, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .plus, .loc = .{ .start = start, .end = self.index } };
            },
            '-' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '>') {
                    self.index += 1;
                    return Token{ .tag = .arrow, .loc = .{ .start = start, .end = self.index } };
                }
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return Token{ .tag = .minus_equal, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .minus, .loc = .{ .start = start, .end = self.index } };
            },
            '*' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return Token{ .tag = .asterisk_equal, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .asterisk, .loc = .{ .start = start, .end = self.index } };
            },
            '/' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '/') {
                    // Line comment, skip till newline
                    self.index += 1;
                    while (self.index < self.buffer.len and self.buffer[self.index] != '\n') : (self.index += 1) {}
                    return self.next();
                }
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return Token{ .tag = .slash_equal, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .slash, .loc = .{ .start = start, .end = self.index } };
            },
            '%' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return Token{ .tag = .percent_equal, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .percent, .loc = .{ .start = start, .end = self.index } };
            },
            '=' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '>') {
                    self.index += 1;
                    return Token{ .tag = .fat_arrow, .loc = .{ .start = start, .end = self.index } };
                }
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return Token{ .tag = .equal_equal, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .equal, .loc = .{ .start = start, .end = self.index } };
            },
            '&' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return Token{ .tag = .ampersand_equal, .loc = .{ .start = start, .end = self.index } };
                }
                if (self.index < self.buffer.len and self.buffer[self.index] == '&') {
                    self.index += 1;
                    return Token{ .tag = .amp_amp, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .ampersand, .loc = .{ .start = start, .end = self.index } };
            },
            '^' => return Token{ .tag = .caret, .loc = .{ .start = start, .end = self.index } },
            '|' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '|') {
                    self.index += 1;
                    return Token{ .tag = .pipe_pipe, .loc = .{ .start = start, .end = self.index } };
                }
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return Token{ .tag = .pipe_equal, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .pipe, .loc = .{ .start = start, .end = self.index } };
            },
            '!' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return Token{ .tag = .bang_equal, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .bang, .loc = .{ .start = start, .end = self.index } };
            },
            '.' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '.') {
                    self.index += 1;
                    return Token{ .tag = .range, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .dot, .loc = .{ .start = start, .end = self.index } };
            },
            ',' => return Token{ .tag = .comma, .loc = .{ .start = start, .end = self.index } },
            ';' => return Token{ .tag = .semicolon, .loc = .{ .start = start, .end = self.index } },
            ':' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == ':') {
                    self.index += 1;
                    return Token{ .tag = .double_colon, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .colon, .loc = .{ .start = start, .end = self.index } };
            },
            '(' => return Token{ .tag = .l_paren, .loc = .{ .start = start, .end = self.index } },
            ')' => return Token{ .tag = .r_paren, .loc = .{ .start = start, .end = self.index } },
            '{' => {
                if (self.interp_depth > 0) self.interp_depth += 1;
                return Token{ .tag = .l_brace, .loc = .{ .start = start, .end = self.index } };
            },
            '}' => {
                if (self.interp_depth > 0) {
                    self.interp_depth -= 1;
                    if (self.interp_depth == 0) self.in_template = true;
                }
                return Token{ .tag = .r_brace, .loc = .{ .start = start, .end = self.index } };
            },
            '[' => return Token{ .tag = .l_bracket, .loc = .{ .start = start, .end = self.index } },
            ']' => return Token{ .tag = .r_bracket, .loc = .{ .start = start, .end = self.index } },
            '<' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '<') {
                    self.index += 1;
                    return Token{ .tag = .less_less, .loc = .{ .start = start, .end = self.index } };
                }
                if (self.index + 1 < self.buffer.len and self.buffer[self.index] == '=' and self.buffer[self.index + 1] == '>') {
                    self.index += 2;
                    return Token{ .tag = .spaceship, .loc = .{ .start = start, .end = self.index } };
                }
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return Token{ .tag = .less_equal, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .less_than, .loc = .{ .start = start, .end = self.index } };
            },
            '>' => {
                if (self.index < self.buffer.len and self.buffer[self.index] == '>') {
                    self.index += 1;
                    return Token{ .tag = .greater_greater, .loc = .{ .start = start, .end = self.index } };
                }
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    return Token{ .tag = .greater_equal, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .greater_than, .loc = .{ .start = start, .end = self.index } };
            },
            '"' => {
                while (self.index < self.buffer.len and self.buffer[self.index] != '"') : (self.index += 1) {
                    if (self.buffer[self.index] == '\\') {
                        self.index += 1;
                    }
                }
                if (self.index < self.buffer.len) {
                    self.index += 1; // skip closing quote
                    return Token{ .tag = .string_literal, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .invalid, .loc = .{ .start = start, .end = self.index } };
            },
            'a'...'z', 'A'...'Z', '_' => {
                while (self.index < self.buffer.len) : (self.index += 1) {
                    const next_c = self.buffer[self.index];
                    if (!std.ascii.isAlphanumeric(next_c) and next_c != '_') break;
                }
                const ident_str = self.buffer[start..self.index];
                const tag = checkKeyword(ident_str);
                return Token{ .tag = tag, .loc = .{ .start = start, .end = self.index } };
            },
            '0'...'9' => {
                if (c == '0' and self.index < self.buffer.len and (self.buffer[self.index] == 'x' or self.buffer[self.index] == 'X')) {
                    self.index += 1;
                    // #11: `_` separators allowed between hex digits (`0xFF_FF`).
                    while (self.index < self.buffer.len) : (self.index += 1) {
                        const hex_c = self.buffer[self.index];
                        if (std.ascii.isHex(hex_c)) continue;
                        if (hex_c == '_' and self.index + 1 < self.buffer.len and std.ascii.isHex(self.buffer[self.index + 1])) continue;
                        break;
                    }
                    while (self.index < self.buffer.len and std.ascii.isAlphabetic(self.buffer[self.index])) : (self.index += 1) {}
                    while (self.index < self.buffer.len and std.ascii.isDigit(self.buffer[self.index])) : (self.index += 1) {}
                    return Token{ .tag = .int_literal, .loc = .{ .start = start, .end = self.index } };
                }
                var is_float = false;
                while (self.index < self.buffer.len) : (self.index += 1) {
                    const next_c = self.buffer[self.index];
                    if (next_c == '.') {
                        // Check if it is a range operator '..' or a float dot '.'
                        if (self.index + 1 < self.buffer.len and self.buffer[self.index + 1] == '.') {
                            break; // Range operator, stop parsing number
                        }
                        if (self.index + 1 >= self.buffer.len or !std.ascii.isDigit(self.buffer[self.index + 1])) {
                            break;
                        }
                        is_float = true;
                    } else if (next_c == '_') {
                        // #11: `_` separators allowed between digits (`1_000`,
                        // `1_000.5`, `1.5_0`); a trailing/lone `_` keeps the
                        // historical split (`1` + identifier) behavior.
                        if (self.index + 1 >= self.buffer.len or !std.ascii.isDigit(self.buffer[self.index + 1])) {
                            break;
                        }
                    } else if (!std.ascii.isDigit(next_c)) {
                        break;
                    }
                }
                if (!is_float) {
                    while (self.index < self.buffer.len and std.ascii.isAlphanumeric(self.buffer[self.index])) : (self.index += 1) {}
                }
                const tag: Token.Tag = if (is_float) .float_literal else .int_literal;
                return Token{ .tag = tag, .loc = .{ .start = start, .end = self.index } };
            },
            '`' => {
                // Template open (possibly nested inside an interpolation).
                if (self.tmpl_sp >= self.tmpl_stack.len) {
                    return Token{ .tag = .invalid, .loc = .{ .start = start, .end = self.index } };
                }
                self.tmpl_stack[self.tmpl_sp] = self.interp_depth;
                self.tmpl_sp += 1;
                self.interp_depth = 0;
                self.in_template = true;
                return Token{ .tag = .template_start, .loc = .{ .start = start, .end = self.index } };
            },
            else => return Token{ .tag = .invalid, .loc = .{ .start = start, .end = self.index } },
        }
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.index < self.buffer.len) : (self.index += 1) {
            const c = self.buffer[self.index];
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
        }
    }

    fn checkKeyword(str: []const u8) Token.Tag {
        if (std.mem.eql(u8, str, "struct")) return .keyword_struct;
        if (std.mem.eql(u8, str, "union")) return .keyword_union;
        if (std.mem.eql(u8, str, "enum")) return .keyword_enum;
        if (std.mem.eql(u8, str, "trait")) return .keyword_trait;
        if (std.mem.eql(u8, str, "overload")) return .keyword_overload;
        if (std.mem.eql(u8, str, "dyn")) return .keyword_dyn;
        if (std.mem.eql(u8, str, "impl")) return .keyword_impl;
        if (std.mem.eql(u8, str, "mod")) return .keyword_mod;
        if (std.mem.eql(u8, str, "using")) return .keyword_using;
        if (std.mem.eql(u8, str, "pub")) return .keyword_pub;
        if (std.mem.eql(u8, str, "extern")) return .keyword_extern;
        if (std.mem.eql(u8, str, "async")) return .keyword_async;
        if (std.mem.eql(u8, str, "await")) return .keyword_await;
        if (std.mem.eql(u8, str, "unsafe")) return .keyword_unsafe;
        if (std.mem.eql(u8, str, "as")) return .keyword_as;
        if (std.mem.eql(u8, str, "fn")) return .keyword_fn;
        if (std.mem.eql(u8, str, "if")) return .keyword_if;
        if (std.mem.eql(u8, str, "else")) return .keyword_else;
        if (std.mem.eql(u8, str, "match")) return .keyword_match;
        if (std.mem.eql(u8, str, "switch")) return .keyword_switch;
        if (std.mem.eql(u8, str, "return")) return .keyword_return;
        if (std.mem.eql(u8, str, "for")) return .keyword_for;
        if (std.mem.eql(u8, str, "while")) return .keyword_while;
        if (std.mem.eql(u8, str, "break")) return .keyword_break;
        if (std.mem.eql(u8, str, "continue")) return .keyword_continue;
        if (std.mem.eql(u8, str, "in")) return .keyword_in;
        if (std.mem.eql(u8, str, "let")) return .keyword_let;
        if (std.mem.eql(u8, str, "const")) return .keyword_const;
        if (std.mem.eql(u8, str, "var")) return .keyword_var;
        if (std.mem.eql(u8, str, "inline")) return .keyword_inline;
        if (std.mem.eql(u8, str, "macro")) return .keyword_macro;
        if (std.mem.eql(u8, str, "mut")) return .keyword_mut;
        if (std.mem.eql(u8, str, "type")) return .keyword_type;
        return .identifier;
    }
};

test "basic lexing" {
    const source = "struct Option<T> { has_value: bool, value: T }";
    var l = Lexer.init(source);

    try std.testing.expectEqual(Token.Tag.keyword_struct, l.next().tag);
    try std.testing.expectEqual(Token.Tag.identifier, l.next().tag);
    try std.testing.expectEqual(Token.Tag.less_than, l.next().tag);
    try std.testing.expectEqual(Token.Tag.identifier, l.next().tag);
    try std.testing.expectEqual(Token.Tag.greater_than, l.next().tag);
    try std.testing.expectEqual(Token.Tag.l_brace, l.next().tag);
    try std.testing.expectEqual(Token.Tag.identifier, l.next().tag);
    try std.testing.expectEqual(Token.Tag.colon, l.next().tag);
    try std.testing.expectEqual(Token.Tag.identifier, l.next().tag);
    try std.testing.expectEqual(Token.Tag.comma, l.next().tag);
    try std.testing.expectEqual(Token.Tag.identifier, l.next().tag);
    try std.testing.expectEqual(Token.Tag.colon, l.next().tag);
    try std.testing.expectEqual(Token.Tag.identifier, l.next().tag);
    try std.testing.expectEqual(Token.Tag.r_brace, l.next().tag);
    try std.testing.expectEqual(Token.Tag.eof, l.next().tag);
}

test "numeric separators lex as single literal" {
    // #11: `_` between digits stays inside the number token.
    var l = Lexer.init("1_000 7_000.5 0xFF_FF 1_000..2");
    var tok = l.next();
    try std.testing.expectEqual(Token.Tag.int_literal, tok.tag);
    try std.testing.expectEqualSlices(u8, "1_000", l.buffer[tok.loc.start..tok.loc.end]);
    tok = l.next();
    try std.testing.expectEqual(Token.Tag.float_literal, tok.tag);
    tok = l.next();
    try std.testing.expectEqual(Token.Tag.int_literal, tok.tag);
    try std.testing.expectEqualSlices(u8, "0xFF_FF", l.buffer[tok.loc.start..tok.loc.end]);
    tok = l.next();
    try std.testing.expectEqual(Token.Tag.int_literal, tok.tag);
    try std.testing.expectEqualSlices(u8, "1_000", l.buffer[tok.loc.start..tok.loc.end]);

    // Trailing/lone `_` keeps the historical split (`1` + identifier).
    var m = Lexer.init("1_ ");
    tok = m.next();
    try std.testing.expectEqual(Token.Tag.int_literal, tok.tag);
    try std.testing.expectEqualSlices(u8, "1", m.buffer[tok.loc.start..tok.loc.end]);
    tok = m.next();
    try std.testing.expectEqual(Token.Tag.identifier, tok.tag);
}
