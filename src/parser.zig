const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

pub const ParserError = error{
    SyntaxError,
    InlineStructNotAllowed,
    InlineImplNotAllowed,
    InlineMacroNotAllowed,
    ExpectedDeclaration,
    UnexpectedToken,
    UnexpectedInfixToken,
    InvalidCallTarget,
    UnexpectedTypeToken,
    OutOfMemory,
    Overflow,
    InvalidCharacter,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lex: lexer.Lexer,
    tok: lexer.Token,
    known_types: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, buffer: []const u8) Parser {
        var p = Parser{
            .allocator = allocator,
            .lex = lexer.Lexer.init(buffer),
            .tok = undefined,
            .known_types = std.ArrayList([]const u8).init(allocator),
        };
        p.tok = p.lex.next();
        return p;
    }

    fn advance(self: *Parser) void {
        self.tok = self.lex.next();
    }

    fn peek(self: *Parser) lexer.Token.Tag {
        return self.tok.tag;
    }

    fn match(self: *Parser, tag: lexer.Token.Tag) bool {
        if (self.tok.tag == tag) {
            self.advance();
            return true;
        }
        return false;
    }

    fn expect(self: *Parser, tag: lexer.Token.Tag) ParserError!void {
        if (self.tok.tag != tag) {
            std.debug.print("Expected token {s}, found {s} at index {}\n", .{ @tagName(tag), @tagName(self.tok.tag), self.tok.loc.start });
            return ParserError.SyntaxError;
        }
        self.advance();
    }

    fn lexeme(self: *Parser, loc: lexer.Token.Loc) []const u8 {
        return self.lex.buffer[loc.start..loc.end];
    }

    fn isKnownTypeName(self: *Parser, name: []const u8) bool {
        for (self.known_types.items) |ty_name| {
            if (std.mem.eql(u8, ty_name, name)) return true;
        }
        return false;
    }

    pub fn parseProgram(self: *Parser) ParserError!*ast.Node {
        var decls = std.ArrayList(*ast.Node).init(self.allocator);
        errdefer decls.deinit();

        while (self.peek() != .eof) {
            const decl = try self.parseDecl();
            try decls.append(decl);
            switch (decl.*) {
                .struct_decl => try self.known_types.append(decl.struct_decl.name),
                .enum_decl => try self.known_types.append(decl.enum_decl.name),
                .impl_decl => try self.known_types.append(decl.impl_decl.target_ty.user_defined.name),
                else => {},
            }
            // Consume optional semicolon after top‑level declaration to tolerate both styles
            _ = self.match(.semicolon);
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .program = .{ .decls = try decls.toOwnedSlice() } };
        return node;
    }

    fn parseDecl(self: *Parser) ParserError!*ast.Node {
        const is_inline = self.match(.keyword_inline);
        const is_async = self.match(.keyword_async);
        if (self.peek() == .keyword_struct) {
            if (is_inline) return ParserError.InlineStructNotAllowed;
            if (is_async) return ParserError.ExpectedDeclaration;
            return try self.parseStructDecl();
        } else if (self.peek() == .keyword_enum) {
            if (is_inline) return ParserError.ExpectedDeclaration;
            if (is_async) return ParserError.ExpectedDeclaration;
            return try self.parseEnumDecl();
        } else if (self.peek() == .keyword_impl) {
            if (is_inline) return ParserError.InlineImplNotAllowed;
            if (is_async) return ParserError.ExpectedDeclaration;
            return try self.parseImplDecl();
        } else if (self.peek() == .keyword_fn) {
            return try self.parseFuncDecl(is_inline, is_async);
        } else if (self.peek() == .keyword_macro) {
            if (is_inline) return ParserError.InlineMacroNotAllowed;
            if (is_async) return ParserError.ExpectedDeclaration;
            return try self.parseMacroDecl();
        } else if (self.peek() == .at) {
            if (is_inline) return ParserError.ExpectedDeclaration;
            if (is_async) return ParserError.ExpectedDeclaration;
            return try self.parseAtDecl();
        } else {
            return ParserError.ExpectedDeclaration;
        }
    }

    fn parseAtDecl(self: *Parser) ParserError!*ast.Node {
        try self.expect(.at);
        const ident = self.tok;
        try self.expect(.identifier);
        const name = self.lexeme(ident.loc);

        if (std.mem.eql(u8, name, "test")) {
            return try self.parseTestDeclAfterAt();
        } else if (std.mem.eql(u8, name, "import")) {
            return try self.parseImportDeclAfterAt();
        }

        return ParserError.SyntaxError;
    }

    fn parseStructDecl(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_struct);
        const name_tok = self.tok;
        try self.expect(.identifier);
        const name = self.lexeme(name_tok.loc);

        var generics = std.ArrayList([]const u8).init(self.allocator);
        if (self.match(.less_than)) {
            while (true) {
                const g_tok = self.tok;
                try self.expect(.identifier);
                try generics.append(self.lexeme(g_tok.loc));
                if (!self.match(.comma)) break;
            }
            try self.expect(.greater_than);
        }

        try self.expect(.l_brace);

        var fields = std.ArrayList(ast.Field).init(self.allocator);
        while (self.peek() != .r_brace and self.peek() != .eof) {
            const f_tok = self.tok;
            try self.expect(.identifier);
            const f_name = self.lexeme(f_tok.loc);
            try self.expect(.colon);
            const f_ty = try self.parseType();
            try fields.append(.{ .name = f_name, .ty = f_ty });
            _ = self.match(.comma);
        }

        try self.expect(.r_brace);

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .struct_decl = .{
                .name = name,
                .generics = try generics.toOwnedSlice(),
                .fields = try fields.toOwnedSlice(),
            },
        };
        return node;
    }

    fn parseEnumDecl(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_enum);
        const name_tok = self.tok;
        try self.expect(.identifier);
        const name = self.lexeme(name_tok.loc);

        var generics = std.ArrayList([]const u8).init(self.allocator);
        if (self.match(.less_than)) {
            while (true) {
                const g_tok = self.tok;
                try self.expect(.identifier);
                try generics.append(self.lexeme(g_tok.loc));
                if (!self.match(.comma)) break;
            }
            try self.expect(.greater_than);
        }

        try self.expect(.l_brace);
        var variants = std.ArrayList(ast.EnumVariant).init(self.allocator);
        while (self.peek() != .r_brace and self.peek() != .eof) {
            const variant_tok = self.tok;
            try self.expect(.identifier);
            const variant_name = self.lexeme(variant_tok.loc);

            var fields = std.ArrayList(ast.Field).init(self.allocator);
            if (self.match(.l_brace)) {
                while (self.peek() != .r_brace and self.peek() != .eof) {
                    const f_tok = self.tok;
                    try self.expect(.identifier);
                    const f_name = self.lexeme(f_tok.loc);
                    try self.expect(.colon);
                    const f_ty = try self.parseType();
                    try fields.append(.{ .name = f_name, .ty = f_ty });
                    _ = self.match(.comma);
                }
                try self.expect(.r_brace);
            }

            try variants.append(.{ .name = variant_name, .fields = try fields.toOwnedSlice() });
            _ = self.match(.comma);
        }
        try self.expect(.r_brace);

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .enum_decl = .{ .name = name, .generics = try generics.toOwnedSlice(), .variants = try variants.toOwnedSlice() } };
        return node;
    }

    fn parseImplDecl(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_impl);
        const target_ty = try self.parseType();
        try self.expect(.l_brace);

        var methods = std.ArrayList(*ast.Node).init(self.allocator);
        while (self.peek() != .r_brace and self.peek() != .eof) {
            const is_inline = self.match(.keyword_inline);
            const is_async = self.match(.keyword_async);
            if (is_inline or is_async) return ParserError.ExpectedDeclaration;
            try methods.append(try self.parseMethodDecl(target_ty));
            _ = self.match(.semicolon);
        }
        try self.expect(.r_brace);

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .impl_decl = .{ .target_ty = target_ty, .methods = try methods.toOwnedSlice() } };
        return node;
    }

    fn parseMethodDecl(self: *Parser, target_ty: *ast.Type) ParserError!*ast.Node {
        try self.expect(.keyword_fn);
        const name_tok = self.tok;
        try self.expect(.identifier);
        const name = self.lexeme(name_tok.loc);

        var generics = std.ArrayList([]const u8).init(self.allocator);
        if (self.match(.less_than)) {
            while (true) {
                const g_tok = self.tok;
                try self.expect(.identifier);
                try generics.append(self.lexeme(g_tok.loc));
                if (!self.match(.comma)) break;
            }
            try self.expect(.greater_than);
        }

        try self.expect(.l_paren);

        var params = std.ArrayList(ast.Param).init(self.allocator);
        if (self.peek() != .r_paren and self.peek() != .eof) {
            const is_borrow = self.match(.ampersand);
            const is_move = if (!is_borrow) self.match(.caret) else false;
            const self_tok = self.tok;
            try self.expect(.identifier);
            const self_name = self.lexeme(self_tok.loc);
            if (!std.mem.eql(u8, self_name, "self")) return ParserError.SyntaxError;
            try params.append(.{ .name = "self", .ty = target_ty, .is_borrow = is_borrow, .is_move = is_move });
            if (self.match(.comma)) {
                while (self.peek() != .r_paren and self.peek() != .eof) {
                    const p_is_borrow = self.match(.ampersand);
                    const p_is_move = if (!p_is_borrow) self.match(.caret) else false;
                    const p_tok = self.tok;
                    try self.expect(.identifier);
                    const p_name = self.lexeme(p_tok.loc);
                    try self.expect(.colon);
                    const p_ty = try self.parseType();
                    try params.append(.{ .name = p_name, .ty = p_ty, .is_borrow = p_is_borrow, .is_move = p_is_move });
                    if (!self.match(.comma)) break;
                }
            }
        }

        try self.expect(.r_paren);

        var ret_ty: *ast.Type = undefined;
        if (self.match(.arrow)) {
            ret_ty = try self.parseType();
        } else {
            ret_ty = try self.allocator.create(ast.Type);
            ret_ty.* = .{ .primitive = .void_type };
        }

        const body = try self.parseBlock();

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .func_decl = .{
                .name = name,
                .generics = try generics.toOwnedSlice(),
                .params = try params.toOwnedSlice(),
                .ret_ty = ret_ty,
                .body = body,
                .is_inline = false,
                .is_async = false,
            },
        };
        return node;
    }

    fn parseFuncDecl(self: *Parser, is_inline: bool, is_async: bool) ParserError!*ast.Node {
        try self.expect(.keyword_fn);
        const name_tok = self.tok;
        try self.expect(.identifier);
        const name = self.lexeme(name_tok.loc);

        var generics = std.ArrayList([]const u8).init(self.allocator);
        if (self.match(.less_than)) {
            while (true) {
                const g_tok = self.tok;
                try self.expect(.identifier);
                try generics.append(self.lexeme(g_tok.loc));
                if (!self.match(.comma)) break;
            }
            try self.expect(.greater_than);
        }

        try self.expect(.l_paren);

        var params = std.ArrayList(ast.Param).init(self.allocator);
        while (self.peek() != .r_paren and self.peek() != .eof) {
            const is_borrow = self.match(.ampersand);
            const is_move = if (!is_borrow) self.match(.caret) else false;
            const p_tok = self.tok;
            try self.expect(.identifier);
            const p_name = self.lexeme(p_tok.loc);
            try self.expect(.colon);
            const p_ty = try self.parseType();
            try params.append(.{ .name = p_name, .ty = p_ty, .is_borrow = is_borrow, .is_move = is_move });
            if (!self.match(.comma)) break;
        }

        try self.expect(.r_paren);

        var ret_ty: *ast.Type = undefined;
        if (self.match(.arrow)) {
            ret_ty = try self.parseType();
        } else {
            ret_ty = try self.allocator.create(ast.Type);
            ret_ty.* = .{ .primitive = .void_type };
        }

        const body = try self.parseBlock();

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .func_decl = .{
                .name = name,
                .generics = try generics.toOwnedSlice(),
                .params = try params.toOwnedSlice(),
                .ret_ty = ret_ty,
                .body = body,
                .is_inline = is_inline,
                .is_async = is_async,
            },
        };
        return node;
    }

    fn parseMacroDecl(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_macro);
        const name_tok = self.tok;
        try self.expect(.identifier);
        const name = self.lexeme(name_tok.loc);

        try self.expect(.l_paren);

        var params = std.ArrayList([]const u8).init(self.allocator);
        while (self.peek() != .r_paren and self.peek() != .eof) {
            const p_tok = self.tok;
            try self.expect(.identifier);
            try params.append(self.lexeme(p_tok.loc));
            if (!self.match(.comma)) break;
        }

        try self.expect(.r_paren);

        const body = try self.parseBlock();

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .macro_decl = .{
                .name = name,
                .params = try params.toOwnedSlice(),
                .body = body,
            },
        };
        return node;
    }

    fn parseImportDeclAfterAt(self: *Parser) ParserError!*ast.Node {
        const path_tok = self.tok;
        try self.expect(.string_literal);
        const raw_path = self.lexeme(path_tok.loc);
        if (raw_path.len < 2 or raw_path[0] != '"' or raw_path[raw_path.len - 1] != '"') {
            return ParserError.SyntaxError;
        }
        _ = self.match(.semicolon);

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .import_decl = .{ .path = raw_path[1 .. raw_path.len - 1] } };
        return node;
    }

    fn parseTestDeclAfterAt(self: *Parser) ParserError!*ast.Node {
        var is_ignored = false;
        var should_panic = false;

        while (self.peek() == .identifier) {
            const mod_str = self.lexeme(self.tok.loc);
            if (std.mem.eql(u8, mod_str, "ignored")) {
                is_ignored = true;
                self.advance();
            } else if (std.mem.eql(u8, mod_str, "should_panic")) {
                should_panic = true;
                self.advance();
            } else {
                break;
            }
        }

        const name_tok = self.tok;
        try self.expect(.string_literal);
        const raw_name = self.lexeme(name_tok.loc);
        if (raw_name.len < 2 or raw_name[0] != '"' or raw_name[raw_name.len - 1] != '"') {
            return ParserError.SyntaxError;
        }
        const name = raw_name[1 .. raw_name.len - 1];

        try self.expect(.l_paren);
        try self.expect(.r_paren);

        const body = try self.parseBlock();

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .test_decl = .{
                .name = name,
                .is_ignored = is_ignored,
                .should_panic = should_panic,
                .body = body,
            },
        };
        return node;
    }

    fn parseBlock(self: *Parser) ParserError![]const *ast.Node {
        try self.expect(.l_brace);
        var stmts = std.ArrayList(*ast.Node).init(self.allocator);
        while (self.peek() != .r_brace and self.peek() != .eof) {
            const stmt = try self.parseStmt();
            try stmts.append(stmt);
        }
        try self.expect(.r_brace);
        return try stmts.toOwnedSlice();
    }

    fn parseStmt(self: *Parser) ParserError!*ast.Node {
        if (self.peek() == .keyword_let) {
            return try self.parseLetStmt();
        } else if (self.peek() == .keyword_const) {
            return try self.parseConstStmt();
        } else if (self.peek() == .keyword_return) {
            return try self.parseReturnStmt();
        } else if (self.peek() == .keyword_for) {
            return try self.parseForStmt();
        } else if (self.peek() == .bang) {
            return try self.parseReleaseStmt();
        } else {
            const expr = try self.parseExpr(0);
            if (self.match(.equal)) {
                const rhs = try self.parseExpr(0);
                try self.expect(.semicolon);
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .assign_stmt = .{ .target = expr, .value = rhs } };
                return node;
            }
            try self.expect(.semicolon);
            const node = try self.allocator.create(ast.Node);
            node.* = .{ .expr_stmt = expr };
            return node;
        }
    }

    fn parseLetStmt(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_let);

        if (self.peek() == .l_paren) {
            self.advance();
            var names = std.ArrayList([]const u8).init(self.allocator);
            while (self.peek() != .r_paren and self.peek() != .eof) {
                const name_tok = self.tok;
                try self.expect(.identifier);
                try names.append(self.lexeme(name_tok.loc));
                if (!self.match(.comma)) break;
            }
            try self.expect(.r_paren);
            try self.expect(.equal);
            const val = try self.parseExpr(0);
            try self.expect(.semicolon);

            const node = try self.allocator.create(ast.Node);
            node.* = .{
                .let_destructure_stmt = .{
                    .names = try names.toOwnedSlice(),
                    .value = val,
                },
            };
            return node;
        }

        const name_tok = self.tok;
        try self.expect(.identifier);
        const name = self.lexeme(name_tok.loc);

        var ty: ?*ast.Type = null;
        if (self.match(.colon)) {
            ty = try self.parseType();
        }

        try self.expect(.equal);
        const val = try self.parseExpr(0);
        try self.expect(.semicolon);

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .let_stmt = .{
                .name = name,
                .ty = ty,
                .value = val,
            },
        };
        return node;
    }

    fn parseConstStmt(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_const);
        const name_tok = self.tok;
        try self.expect(.identifier);
        const name = self.lexeme(name_tok.loc);

        var ty: ?*ast.Type = null;
        if (self.match(.colon)) {
            ty = try self.parseType();
        }

        try self.expect(.equal);
        const val = try self.parseExpr(0);
        try self.expect(.semicolon);

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .const_stmt = .{
                .name = name,
                .ty = ty,
                .value = val,
            },
        };
        return node;
    }

    fn parseReturnStmt(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_return);
        var val: ?*ast.Node = null;
        if (self.peek() != .semicolon) {
            val = try self.parseExpr(0);
        }
        try self.expect(.semicolon);

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .return_stmt = .{
                .value = val,
            },
        };
        return node;
    }

    fn parseForStmt(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_for);
        const var_tok = self.tok;
        try self.expect(.identifier);
        const var_name = self.lexeme(var_tok.loc);

        try self.expect(.keyword_in);
        const start = try self.parseExpr(0);
        try self.expect(.range);
        const end = try self.parseExpr(0);

        const body = try self.parseBlock();

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .for_stmt = .{
                .var_name = var_name,
                .start = start,
                .end = end,
                .body = body,
            },
        };
        return node;
    }

    fn parseReleaseStmt(self: *Parser) ParserError!*ast.Node {
        try self.expect(.bang);
        const var_tok = self.tok;
        try self.expect(.identifier);
        const var_name = self.lexeme(var_tok.loc);
        try self.expect(.semicolon);

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .release_stmt = .{
                .var_name = var_name,
            },
        };
        return node;
    }

    fn makeUserDefinedType(self: *Parser, name: []const u8, generics: []const *ast.Type) ParserError!*ast.Type {
        const ty = try self.allocator.create(ast.Type);
        ty.* = .{
            .user_defined = .{
                .name = name,
                .generics = generics,
            },
        };
        return ty;
    }

    fn looksLikeGenericStructLiteralTail(self: *Parser) bool {
        var lex_copy = self.lex;
        var tok_copy = self.tok;
        var depth: usize = 1;

        while (tok_copy.tag != .eof) {
            switch (tok_copy.tag) {
                .less_than => depth += 1,
                .greater_than => {
                    depth -= 1;
                    if (depth == 0) {
                        tok_copy = lex_copy.next();
                        return tok_copy.tag == .l_brace;
                    }
                },
                else => {},
            }
            tok_copy = lex_copy.next();
        }
        return false;
    }

    fn parseStructLiteral(self: *Parser, ty: *ast.Type) ParserError!*ast.Node {
        try self.expect(.l_brace);

        var fields = std.ArrayList(ast.StructLiteralField).init(self.allocator);
        while (self.peek() != .r_brace and self.peek() != .eof) {
            const field_tok = self.tok;
            try self.expect(.identifier);
            const field_name = self.lexeme(field_tok.loc);
            try self.expect(.colon);
            const value = try self.parseExpr(0);
            try fields.append(.{ .name = field_name, .value = value });
            _ = self.match(.comma);
        }

        try self.expect(.r_brace);

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .struct_literal = .{
                .ty = ty,
                .fields = try fields.toOwnedSlice(),
            },
        };
        return node;
    }

    fn parseGenericStructLiteralTail(self: *Parser, name: []const u8) ParserError!*ast.Node {
        var generics = std.ArrayList(*ast.Type).init(self.allocator);
        while (true) {
            const ty = try self.parseType();
            try generics.append(ty);
            if (!self.match(.comma)) break;
        }
        try self.expect(.greater_than);
        const lit_ty = try self.makeUserDefinedType(name, try generics.toOwnedSlice());
        return try self.parseStructLiteral(lit_ty);
    }

    fn parseEnumLiteralAfterName(self: *Parser, enum_name: []const u8) ParserError!*ast.Node {
        try self.expect(.double_colon);
        const variant_tok = self.tok;
        try self.expect(.identifier);
        const variant_name = self.lexeme(variant_tok.loc);

        var fields = std.ArrayList(ast.EnumLiteralField).init(self.allocator);
        if (self.match(.l_brace)) {
            while (self.peek() != .r_brace and self.peek() != .eof) {
                const field_tok = self.tok;
                try self.expect(.identifier);
                const field_name = self.lexeme(field_tok.loc);
                try self.expect(.colon);
                const value = try self.parseExpr(0);
                try fields.append(.{ .name = field_name, .value = value });
                _ = self.match(.comma);
            }
            try self.expect(.r_brace);
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .enum_literal = .{ .enum_name = enum_name, .variant_name = variant_name, .fields = try fields.toOwnedSlice() } };
        return node;
    }

    fn parseClosureLiteral(self: *Parser) ParserError!*ast.Node {
        try self.expect(.pipe);
        var params = std.ArrayList(ast.Param).init(self.allocator);
        while (self.peek() != .pipe and self.peek() != .eof) {
            const p_tok = self.tok;
            try self.expect(.identifier);
            const p_name = self.lexeme(p_tok.loc);
            try self.expect(.colon);
            const p_ty = try self.parseType();
            try params.append(.{ .name = p_name, .ty = p_ty });
            if (!self.match(.comma)) break;
        }
        try self.expect(.pipe);
        const body = try self.parseExpr(0);
        const node = try self.allocator.create(ast.Node);
        node.* = .{ .closure_literal = .{ .params = try params.toOwnedSlice(), .body = body } };
        return node;
    }

    fn parseEnumPattern(self: *Parser) ParserError!ast.EnumPattern {
        const enum_tok = self.tok;
        try self.expect(.identifier);
        const enum_name = self.lexeme(enum_tok.loc);
        try self.expect(.double_colon);
        const variant_tok = self.tok;
        try self.expect(.identifier);
        const variant_name = self.lexeme(variant_tok.loc);

        var bindings = std.ArrayList([]const u8).init(self.allocator);
        if (self.match(.l_brace)) {
            while (self.peek() != .r_brace and self.peek() != .eof) {
                const bind_tok = self.tok;
                try self.expect(.identifier);
                try bindings.append(self.lexeme(bind_tok.loc));
                _ = self.match(.comma);
            }
            try self.expect(.r_brace);
        }

        return .{ .enum_name = enum_name, .variant_name = variant_name, .bindings = try bindings.toOwnedSlice() };
    }

    fn parseMatchExpr(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_match);
        const val = try self.parseExpr(0);
        try self.expect(.l_brace);

        var cases = std.ArrayList(ast.MatchCase).init(self.allocator);
        while (self.peek() != .r_brace and self.peek() != .eof) {
            const pattern = try self.parseEnumPattern();
            try self.expect(.fat_arrow);
            const body = try self.parseBlock();
            try cases.append(.{ .pattern = pattern, .body = body });
            _ = self.match(.comma);
        }
        try self.expect(.r_brace);

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .match_expr = .{ .val = val, .cases = try cases.toOwnedSlice() } };
        return node;
    }

    fn parseExpr(self: *Parser, precedence: u8) ParserError!*ast.Node {
        var left = try self.parsePrefixExpr();

        while (true) {
            const op_prec = self.getInfixPrecedence(self.peek());
            if (op_prec <= precedence) break;
            left = try self.parseInfixExpr(left, op_prec);
        }

        return left;
    }

    fn parsePrefixExpr(self: *Parser) ParserError!*ast.Node {
        const tag = self.peek();
        switch (tag) {
            .int_literal => {
                const tok = self.tok;
                self.advance();
                const str = self.lexeme(tok.loc);
                const val = std.fmt.parseInt(i64, str, 10) catch return ParserError.InvalidCharacter;
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .literal = .{ .int_val = val } };
                return node;
            },
            .float_literal => {
                const tok = self.tok;
                self.advance();
                const str = self.lexeme(tok.loc);
                const val = std.fmt.parseFloat(f64, str) catch return ParserError.InvalidCharacter;
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .literal = .{ .float_val = val } };
                return node;
            },
            .string_literal => {
                const tok = self.tok;
                self.advance();
                const raw = self.lexeme(tok.loc);
                const val = raw[1 .. raw.len - 1];
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .literal = .{ .string_val = val } };
                return node;
            },
            .identifier => {
                const tok = self.tok;
                self.advance();
                const str = self.lexeme(tok.loc);
                if (self.peek() == .double_colon) {
                    return try self.parseEnumLiteralAfterName(str);
                }
                if (self.peek() == .l_brace and self.isKnownTypeName(str)) {
                    const lit_ty = try self.makeUserDefinedType(str, &.{});
                    return try self.parseStructLiteral(lit_ty);
                }
                if (std.mem.eql(u8, str, "true")) {
                    const node = try self.allocator.create(ast.Node);
                    node.* = .{ .literal = .{ .bool_val = true } };
                    return node;
                } else if (std.mem.eql(u8, str, "false")) {
                    const node = try self.allocator.create(ast.Node);
                    node.* = .{ .literal = .{ .bool_val = false } };
                    return node;
                }
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .identifier = str };
                return node;
            },
            .ampersand => {
                self.advance();
                const expr = try self.parseExpr(6);
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .borrow_expr = .{ .expr = expr } };
                return node;
            },
            .caret => {
                self.advance();
                const expr = try self.parseExpr(6);
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .move_expr = .{ .expr = expr } };
                return node;
            },
            .asterisk => {
                self.advance();
                const expr = try self.parseExpr(6);
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .deref_expr = .{ .expr = expr } };
                return node;
            },
            .minus => {
                // Unary minus: lower to (0 - expr)
                self.advance();
                const zero = try self.allocator.create(ast.Node);
                zero.* = .{ .literal = .{ .int_val = 0 } };
                const expr = try self.parseExpr(6);
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .binary_expr = .{ .op = .sub, .left = zero, .right = expr } };
                return node;
            },
            .keyword_if => {
                return try self.parseIfExpr();
            },
            .keyword_switch => {
                return try self.parseSwitchExpr();
            },
            .keyword_match => {
                return try self.parseMatchExpr();
            },
            .keyword_await => {
                self.advance();
                const expr = try self.parseExpr(6);
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .await_expr = .{ .expr = expr } };
                return node;
            },
            .pipe => {
                return try self.parseClosureLiteral();
            },
            .l_paren => {
                self.advance();
                const expr = try self.parseExpr(0);
                if (self.match(.comma)) {
                    var elements = std.ArrayList(*ast.Node).init(self.allocator);
                    try elements.append(expr);
                    while (self.peek() != .r_paren and self.peek() != .eof) {
                        const elem = try self.parseExpr(0);
                        try elements.append(elem);
                        if (!self.match(.comma)) break;
                    }
                    try self.expect(.r_paren);
                    const node = try self.allocator.create(ast.Node);
                    node.* = .{ .tuple_literal = .{ .elements = try elements.toOwnedSlice() } };
                    return node;
                }
                try self.expect(.r_paren);
                return expr;
            },
            .l_bracket => {
                self.advance();
                var elements = std.ArrayList(*ast.Node).init(self.allocator);
                while (self.peek() != .r_bracket and self.peek() != .eof) {
                    const elem = try self.parseExpr(0);
                    try elements.append(elem);
                    if (!self.match(.comma)) break;
                }
                try self.expect(.r_bracket);
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .array_literal = .{ .elements = try elements.toOwnedSlice() } };
                return node;
            },
            else => {
                std.debug.print("Unexpected prefix token: {s} at index {}\n", .{ @tagName(tag), self.tok.loc.start });
                return ParserError.UnexpectedToken;
            },
        }
    }

    fn parseInfixExpr(self: *Parser, left: *ast.Node, precedence: u8) ParserError!*ast.Node {
        const tag = self.peek();
        self.advance();

        switch (tag) {
            .plus, .minus, .asterisk, .slash, .percent, .less_than, .greater_than, .less_equal, .greater_equal, .equal_equal, .bang_equal => {
                if (tag == .less_than and left.* == .identifier and self.looksLikeGenericStructLiteralTail()) {
                    return try self.parseGenericStructLiteralTail(left.identifier);
                }

                const op = switch (tag) {
                    .plus => ast.BinaryOp.add,
                    .minus => ast.BinaryOp.sub,
                    .asterisk => ast.BinaryOp.mul,
                    .slash => ast.BinaryOp.div,
                    .percent => ast.BinaryOp.mod,
                    .less_than => ast.BinaryOp.lt,
                    .less_equal => ast.BinaryOp.le,
                    .greater_than => ast.BinaryOp.gt,
                    .greater_equal => ast.BinaryOp.ge,
                    .equal_equal => ast.BinaryOp.eq,
                    .bang_equal => ast.BinaryOp.ne,
                    else => unreachable,
                };
                const right = try self.parseExpr(precedence);
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .binary_expr = .{ .op = op, .left = left, .right = right } };
                return node;
            },
            .dot => {
                if (self.peek() == .keyword_await) {
                    self.advance();
                    const node = try self.allocator.create(ast.Node);
                    node.* = .{ .await_expr = .{ .expr = left } };
                    return node;
                }
                const field_tok = self.tok;
                if (self.peek() != .identifier and self.peek() != .int_literal) {
                    return ParserError.UnexpectedToken;
                }
                self.advance();
                const field_name = self.lexeme(field_tok.loc);

                if (self.peek() == .l_paren or self.peek() == .less_than) {
                    var generic_args = std.ArrayList(*ast.Type).init(self.allocator);
                    if (self.match(.less_than)) {
                        while (true) {
                            const t = try self.parseType();
                            try generic_args.append(t);
                            if (!self.match(.comma)) break;
                        }
                        try self.expect(.greater_than);
                    }

                    try self.expect(.l_paren);
                    var args = std.ArrayList(*ast.Node).init(self.allocator);
                    try args.append(left);
                    while (self.peek() != .r_paren and self.peek() != .eof) {
                        const arg = try self.parseExpr(0);
                        try args.append(arg);
                        if (!self.match(.comma)) break;
                    }
                    try self.expect(.r_paren);

                    const node = try self.allocator.create(ast.Node);
                    node.* = .{
                        .call_expr = .{
                            .func_name = field_name,
                            .generics = try generic_args.toOwnedSlice(),
                            .args = try args.toOwnedSlice(),
                        },
                    };
                    return node;
                }

                const node = try self.allocator.create(ast.Node);
                node.* = .{ .field_expr = .{ .expr = left, .field_name = field_name } };
                return node;
            },
            .bang => {
                if (self.peek() != .l_paren) return ParserError.UnexpectedInfixToken;
                if (left.* != .identifier) return ParserError.InvalidCallTarget;
                var args = std.ArrayList(*ast.Node).init(self.allocator);
                self.advance();
                while (self.peek() != .r_paren and self.peek() != .eof) {
                    const arg = try self.parseExpr(0);
                    try args.append(arg);
                    if (!self.match(.comma)) break;
                }
                try self.expect(.r_paren);
                const node = try self.allocator.create(ast.Node);
                node.* = .{
                    .call_expr = .{
                        .func_name = left.identifier,
                        .generics = &.{},
                        .args = try args.toOwnedSlice(),
                    },
                };
                return node;
            },
            .l_paren => {
                var func_name: []const u8 = "";
                switch (left.*) {
                    .identifier => |id| func_name = id,
                    else => return ParserError.InvalidCallTarget,
                }

                var args = std.ArrayList(*ast.Node).init(self.allocator);
                while (self.peek() != .r_paren and self.peek() != .eof) {
                    const arg = try self.parseExpr(0);
                    try args.append(arg);
                    if (!self.match(.comma)) break;
                }
                try self.expect(.r_paren);

                const node = try self.allocator.create(ast.Node);
                node.* = .{
                    .call_expr = .{
                        .func_name = func_name,
                        .generics = &.{},
                        .args = try args.toOwnedSlice(),
                    },
                };
                return node;
            },
            .l_bracket => {
                const start = try self.parseExpr(0);
                if (self.match(.range)) {
                    const end = try self.parseExpr(0);
                    try self.expect(.r_bracket);
                    const node = try self.allocator.create(ast.Node);
                    node.* = .{ .slice_expr = .{ .target = left, .start = start, .end = end } };
                    return node;
                }
                try self.expect(.r_bracket);
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .index_expr = .{ .target = left, .index = start } };
                return node;
            },
            .question_mark => {
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .try_expr = .{ .expr = left } };
                return node;
            },
            else => return ParserError.UnexpectedInfixToken,
        }
    }

    fn getInfixPrecedence(self: *Parser, tag: lexer.Token.Tag) u8 {
        _ = self;
        return switch (tag) {
            .plus, .minus => 4,
            .asterisk, .slash, .percent => 5,
            .less_than, .greater_than, .less_equal, .greater_equal => 3,
            .equal_equal, .bang_equal => 2,
            .dot, .bang, .l_paren, .l_bracket, .question_mark => 7,
            else => 0,
        };
    }

    fn parseIfExpr(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_if);
        const cond = try self.parseExpr(0);
        const then_block = try self.parseBlock();
        var else_block: ?[]const *ast.Node = null;
        if (self.match(.keyword_else)) {
            if (self.peek() == .keyword_if) {
                const nested_if = try self.parseIfExpr();
                const slice = try self.allocator.alloc(*ast.Node, 1);
                slice[0] = nested_if;
                else_block = slice;
            } else {
                else_block = try self.parseBlock();
            }
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .if_expr = .{
                .cond = cond,
                .then_block = then_block,
                .else_block = else_block,
            },
        };
        return node;
    }

    fn parseSwitchExpr(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_switch);
        const val = try self.parseExpr(0);
        try self.expect(.l_brace);

        var cases = std.ArrayList(ast.Case).init(self.allocator);
        while (self.peek() != .r_brace and self.peek() != .eof) {
            const pattern = try self.parseExpr(0);
            try self.expect(.fat_arrow);

            var body: []const *ast.Node = undefined;
            if (self.peek() == .l_brace) {
                body = try self.parseBlock();
            } else {
                const single = try self.parseStmt();
                const slice = try self.allocator.alloc(*ast.Node, 1);
                slice[0] = single;
                body = slice;
            }

            try cases.append(.{ .pattern = pattern, .body = body });
            if (self.peek() == .comma) self.advance();
        }

        try self.expect(.r_brace);

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .switch_expr = .{
                .val = val,
                .cases = try cases.toOwnedSlice(),
            },
        };
        return node;
    }

    fn parseType(self: *Parser) ParserError!*ast.Type {
        const tag = self.peek();
        const tok = self.tok;
        self.advance();

        switch (tag) {
            .identifier => {
                const name = self.lexeme(tok.loc);
                if (std.mem.eql(u8, name, "int")) {
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .primitive = .integer };
                    return ty;
                } else if (std.mem.eql(u8, name, "float")) {
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .primitive = .float };
                    return ty;
                } else if (std.mem.eql(u8, name, "bool")) {
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .primitive = .boolean };
                    return ty;
                } else if (std.mem.eql(u8, name, "void")) {
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .primitive = .void_type };
                    return ty;
                } else if (std.mem.eql(u8, name, "ptr")) {
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .primitive = .void_type };
                    return ty;
                }

                var generics = std.ArrayList(*ast.Type).init(self.allocator);
                if (self.match(.less_than)) {
                    while (true) {
                        const t = try self.parseType();
                        try generics.append(t);
                        if (!self.match(.comma)) break;
                    }
                    try self.expect(.greater_than);
                }

                if (std.mem.eql(u8, name, "future")) {
                    if (generics.items.len != 1) return ParserError.UnexpectedTypeToken;
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .future = generics.items[0] };
                    return ty;
                }

                const ty = try self.allocator.create(ast.Type);
                ty.* = .{
                    .user_defined = .{
                        .name = name,
                        .generics = try generics.toOwnedSlice(),
                    },
                };
                return ty;
            },
            .ampersand => {
                const inner = try self.parseType();
                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .borrow = inner };
                return ty;
            },
            .asterisk => {
                const inner = try self.parseType();
                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .pointer = inner };
                return ty;
            },
            .l_bracket => {
                const elem = try self.parseType();
                try self.expect(.semicolon);
                const len_tok = self.tok;
                try self.expect(.int_literal);
                const len_str = self.lexeme(len_tok.loc);
                const len = std.fmt.parseInt(usize, len_str, 10) catch return ParserError.InvalidCharacter;
                try self.expect(.r_bracket);
                const ty = try self.allocator.create(ast.Type);
                ty.* = .{ .array = .{ .elem = elem, .len = len } };
                return ty;
            },
            .l_paren => {
                const first = try self.parseType();
                if (self.match(.comma)) {
                    var elems = std.ArrayList(*ast.Type).init(self.allocator);
                    try elems.append(first);
                    while (self.peek() != .r_paren and self.peek() != .eof) {
                        const elem = try self.parseType();
                        try elems.append(elem);
                        if (!self.match(.comma)) break;
                    }
                    try self.expect(.r_paren);
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .tuple = .{ .elems = try elems.toOwnedSlice() } };
                    return ty;
                }
                try self.expect(.r_paren);
                return first;
            },
            else => return ParserError.UnexpectedTypeToken,
        }
    }
};

test "parse struct and function" {
    const source =
        \\struct Option<T> {
        \\    has_value: bool,
        \\    value: T
        \\}
        \\
        \\fn sum_range(limit: int) -> int {
        \\    let sum = 0;
        \\    for i in 1..limit {
        \\        sum = sum + i;
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn try_demo() -> int {
        \\    let val = fetch()?;
        \\    return val;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, source);
    const prog = try p.parseProgram();

    try std.testing.expect(prog.* == .program);
    try std.testing.expectEqual(@as(usize, 3), prog.program.decls.len);

    const d1 = prog.program.decls[0];
    try std.testing.expect(d1.* == .struct_decl);
    try std.testing.expectEqualSlices(u8, "Option", d1.struct_decl.name);
    try std.testing.expectEqual(@as(usize, 1), d1.struct_decl.generics.len);
    try std.testing.expectEqualSlices(u8, "T", d1.struct_decl.generics[0]);
    try std.testing.expectEqual(@as(usize, 2), d1.struct_decl.fields.len);
    try std.testing.expectEqualSlices(u8, "has_value", d1.struct_decl.fields[0].name);

    const d2 = prog.program.decls[1];
    try std.testing.expect(d2.* == .func_decl);
    try std.testing.expectEqualSlices(u8, "sum_range", d2.func_decl.name);
    try std.testing.expectEqual(@as(usize, 1), d2.func_decl.params.len);
    try std.testing.expectEqualSlices(u8, "limit", d2.func_decl.params[0].name);
    try std.testing.expect(d2.func_decl.ret_ty.* == .primitive);
    try std.testing.expect(d2.func_decl.ret_ty.primitive == .integer);

    const d3 = prog.program.decls[2];
    try std.testing.expect(d3.* == .func_decl);
    try std.testing.expectEqualSlices(u8, "try_demo", d3.func_decl.name);
    try std.testing.expectEqual(@as(usize, 2), d3.func_decl.body.len);
    const s1 = d3.func_decl.body[0];
    try std.testing.expect(s1.* == .let_stmt);
    try std.testing.expectEqualSlices(u8, "val", s1.let_stmt.name);
    try std.testing.expect(s1.let_stmt.value.* == .try_expr);
    try std.testing.expect(s1.let_stmt.value.try_expr.expr.* == .call_expr);
    try std.testing.expectEqualSlices(u8, "fetch", s1.let_stmt.value.try_expr.expr.call_expr.func_name);
}
