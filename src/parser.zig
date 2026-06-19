const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

pub const ParserError = error{
    SyntaxError,
    InlineStructNotAllowed,
    InlineImplNotAllowed,
    InlineMacroNotAllowed,
    ExternBlockRequiresExtern,
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
    known_enums: std.ArrayList([]const u8),
    known_modules: std.ArrayList([]const u8),
    current_impl_target: ?*ast.Type,
    base_dir: []const u8,
    import_scan_depth: usize,

    pub fn init(allocator: std.mem.Allocator, buffer: []const u8) Parser {
        return initWithDir(allocator, buffer, ".");
    }

    pub fn initWithDir(allocator: std.mem.Allocator, buffer: []const u8, base_dir: []const u8) Parser {
        var p = Parser{
            .allocator = allocator,
            .lex = lexer.Lexer.init(buffer),
            .tok = undefined,
            .known_types = std.ArrayList([]const u8).init(allocator),
            .known_enums = std.ArrayList([]const u8).init(allocator),
            .known_modules = std.ArrayList([]const u8).init(allocator),
            .current_impl_target = null,
            .base_dir = base_dir,
            .import_scan_depth = 0,
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

    fn expectGenericClose(self: *Parser) ParserError!void {
        switch (self.tok.tag) {
            .greater_than => self.advance(),
            .greater_greater => {
                self.tok = lexer.Token{
                    .tag = .greater_than,
                    .loc = .{
                        .start = self.tok.loc.start + 1,
                        .end = self.tok.loc.end,
                    },
                };
            },
            else => {
                std.debug.print("Expected generic close token, found {s} at index {}\n", .{ @tagName(self.tok.tag), self.tok.loc.start });
                return ParserError.SyntaxError;
            },
        }
    }

    fn lexeme(self: *Parser, loc: lexer.Token.Loc) []const u8 {
        return self.lex.buffer[loc.start..loc.end];
    }

    fn stringSliceLessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    fn isImportPathToken(tag: lexer.Token.Tag) bool {
        return switch (tag) {
            .identifier,
            .asterisk,
            .slash,
            .dot,
            .range,
            .minus,
            => true,
            else => false,
        };
    }

    fn parseImportPathTokenSequence(self: *Parser) ParserError![]const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        while (isImportPathToken(self.peek())) {
            const part = self.lexeme(self.tok.loc);
            try buf.appendSlice(part);
            self.advance();
        }
        if (buf.items.len == 0) return ParserError.SyntaxError;
        return try buf.toOwnedSlice();
    }

    fn isGlobImportPath(path: []const u8) bool {
        return std.mem.indexOfScalar(u8, path, '*') != null;
    }

    fn globNameMatches(pattern: []const u8, name: []const u8) bool {
        const star = std.mem.indexOfScalar(u8, pattern, '*') orelse return std.mem.eql(u8, pattern, name);
        if (std.mem.indexOfScalarPos(u8, pattern, star + 1, '*') != null) return false;
        const prefix = pattern[0..star];
        const suffix = pattern[star + 1 ..];
        if (name.len < prefix.len + suffix.len) return false;
        return std.mem.startsWith(u8, name, prefix) and std.mem.endsWith(u8, name, suffix);
    }

    fn isKnownTypeName(self: *Parser, name: []const u8) bool {
        if (std.mem.eql(u8, name, "Self") and self.current_impl_target != null) return true;
        for (self.known_types.items) |ty_name| {
            if (std.mem.eql(u8, ty_name, name)) return true;
        }
        return false;
    }

    fn isKnownEnumName(self: *Parser, name: []const u8) bool {
        for (self.known_enums.items) |enum_name| {
            if (std.mem.eql(u8, enum_name, name)) return true;
        }
        return false;
    }

    fn isKnownModuleName(self: *Parser, name: []const u8) bool {
        for (self.known_modules.items) |module_name| {
            if (std.mem.eql(u8, module_name, name)) return true;
        }
        return false;
    }

    fn recordImplTargetType(self: *Parser, target_ty: *ast.Type) !void {
        switch (target_ty.*) {
            .user_defined => try self.known_types.append(target_ty.user_defined.name),
            else => {},
        }
    }

    pub fn parseProgram(self: *Parser) ParserError!*ast.Node {
        var decls = std.ArrayList(*ast.Node).init(self.allocator);
        errdefer decls.deinit();

        while (self.peek() != .eof) {
            if (self.peek() == .keyword_mod) {
                try self.parseModuleDeclInto(&decls, null);
                _ = self.match(.semicolon);
                continue;
            }
            const decl = try self.parseDecl();
            if (decl.* == .program) {
                for (decl.program.decls) |inner_decl| {
                    try decls.append(inner_decl);
                    switch (inner_decl.*) {
                        .struct_decl => try self.known_types.append(inner_decl.struct_decl.name),
                        .enum_decl => {
                            try self.known_types.append(inner_decl.enum_decl.name);
                            try self.known_enums.append(inner_decl.enum_decl.name);
                        },
                        .impl_decl => try self.recordImplTargetType(inner_decl.impl_decl.target_ty),
                        else => {},
                    }
                }
            } else {
                try decls.append(decl);
                switch (decl.*) {
                    .struct_decl => try self.known_types.append(decl.struct_decl.name),
                    .enum_decl => {
                        try self.known_types.append(decl.enum_decl.name);
                        try self.known_enums.append(decl.enum_decl.name);
                    },
                    .impl_decl => try self.recordImplTargetType(decl.impl_decl.target_ty),
                    else => {},
                }
            }
            // Consume optional semicolon after top‑level declaration to tolerate both styles
            _ = self.match(.semicolon);
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .program = .{ .decls = try decls.toOwnedSlice() } };
        return node;
    }

    fn parseDecl(self: *Parser) ParserError!*ast.Node {
        const is_pub = self.match(.keyword_pub);
        const is_extern = self.match(.keyword_extern);
        const abi = if (is_extern) try self.parseOptionalExternAbi() else null;
        const is_inline = self.match(.keyword_inline);
        const is_async = self.match(.keyword_async);
        if (self.peek() == .keyword_struct) {
            if (is_inline) return ParserError.InlineStructNotAllowed;
            if (is_async) return ParserError.ExpectedDeclaration;
            return try self.parseStructDecl();
        } else if (self.peek() == .keyword_union) {
            if (is_inline) return ParserError.ExpectedDeclaration;
            if (is_async) return ParserError.ExpectedDeclaration;
            return try self.parseUnionDecl();
        } else if (self.peek() == .keyword_enum) {
            if (is_inline) return ParserError.ExpectedDeclaration;
            if (is_async) return ParserError.ExpectedDeclaration;
            return try self.parseEnumDecl();
        } else if (self.peek() == .keyword_trait) {
            if (is_inline) return ParserError.ExpectedDeclaration;
            if (is_async) return ParserError.ExpectedDeclaration;
            return try self.parseTraitDecl();
        } else if (self.peek() == .l_brace) {
            if (!is_extern) return ParserError.ExternBlockRequiresExtern;
            if (is_inline) return ParserError.ExpectedDeclaration;
            if (is_async) return ParserError.ExpectedDeclaration;
            return try self.parseExternBlock(abi);
        } else if (self.peek() == .keyword_impl) {
            if (is_inline) return ParserError.InlineImplNotAllowed;
            if (is_async) return ParserError.ExpectedDeclaration;
            return try self.parseImplDecl();
        } else if (self.peek() == .keyword_fn) {
            return try self.parseFuncDecl(is_pub, is_inline, is_async, is_extern, abi, false, false);
        } else if (self.peek() == .keyword_const) {
            if (is_inline) return ParserError.ExpectedDeclaration;
            if (is_async) return ParserError.ExpectedDeclaration;
            return try self.parseConstStmt();
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

    fn parseModuleDeclInto(self: *Parser, decls: *std.ArrayList(*ast.Node), parent_prefix: ?[]const u8) ParserError!void {
        try self.expect(.keyword_mod);
        const name_tok = self.tok;
        try self.expect(.identifier);
        const module_name = self.lexeme(name_tok.loc);

        if (parent_prefix == null and !self.isKnownModuleName(module_name)) {
            try self.known_modules.append(module_name);
        }

        const module_prefix = if (parent_prefix) |prefix|
            std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ prefix, module_name }) catch return ParserError.OutOfMemory
        else
            std.fmt.allocPrint(self.allocator, "{s}", .{module_name}) catch return ParserError.OutOfMemory;

        try self.expect(.l_brace);
        while (self.peek() != .r_brace and self.peek() != .eof) {
            if (self.peek() == .keyword_mod) {
                try self.parseModuleDeclInto(decls, module_prefix);
                _ = self.match(.semicolon);
                continue;
            }

            const is_pub = self.match(.keyword_pub);
            const is_extern = self.match(.keyword_extern);
            const abi = if (is_extern) try self.parseOptionalExternAbi() else null;
            const is_inline = self.match(.keyword_inline);
            const is_async = self.match(.keyword_async);
            if (self.peek() != .keyword_fn) return ParserError.ExpectedDeclaration;

            const decl = try self.parseFuncDecl(is_pub, is_inline, is_async, is_extern, abi, false, false);
            const mangled = std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ module_prefix, decl.func_decl.name }) catch return ParserError.OutOfMemory;
            decl.func_decl.name = mangled;
            try decls.append(decl);
            _ = self.match(.semicolon);
        }
        try self.expect(.r_brace);
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
        } else if (std.mem.eql(u8, name, "no_mangle")) {
            const is_pub = self.match(.keyword_pub);
            const is_extern = self.match(.keyword_extern);
            const abi = if (is_extern) try self.parseOptionalExternAbi() else null;
            const is_inline = self.match(.keyword_inline);
            const is_async = self.match(.keyword_async);
            if (self.peek() != .keyword_fn) return ParserError.ExpectedDeclaration;
            return try self.parseFuncDecl(is_pub, is_inline, is_async, is_extern, abi, true, false);
        }

        return ParserError.SyntaxError;
    }

    fn parseOptionalExternAbi(self: *Parser) ParserError!?[]const u8 {
        if (self.peek() != .string_literal) return null;
        const abi_tok = self.tok;
        try self.expect(.string_literal);
        const raw = self.lexeme(abi_tok.loc);
        if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return ParserError.SyntaxError;
        return raw[1 .. raw.len - 1];
    }

    fn parseStructDecl(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_struct);
        return try self.parseAggregateDecl(false);
    }

    fn parseUnionDecl(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_union);
        return try self.parseAggregateDecl(true);
    }

    fn parseExternBlock(self: *Parser, abi: ?[]const u8) ParserError!*ast.Node {
        try self.expect(.l_brace);
        var decls = std.ArrayList(*ast.Node).init(self.allocator);
        while (self.peek() != .r_brace and self.peek() != .eof) {
            const is_pub = self.match(.keyword_pub);
            if (self.peek() != .keyword_fn) return ParserError.ExpectedDeclaration;
            const decl = try self.parseFuncDecl(is_pub, false, false, true, abi, false, true);
            try decls.append(decl);
            _ = self.match(.semicolon);
        }
        try self.expect(.r_brace);

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .program = .{ .decls = try decls.toOwnedSlice() } };
        return node;
    }

    fn parseAggregateDecl(self: *Parser, is_union: bool) ParserError!*ast.Node {
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
            try self.expectGenericClose();
        }

        var fields = std.ArrayList(ast.Field).init(self.allocator);
        var is_opaque = false;
        if (self.match(.semicolon)) {
            is_opaque = true;
        } else if (self.match(.l_paren)) {
            var field_index: usize = 0;
            while (self.peek() != .r_paren and self.peek() != .eof) {
                const f_ty = try self.parseType();
                const f_name = std.fmt.allocPrint(self.allocator, "{}", .{field_index}) catch return ParserError.OutOfMemory;
                try fields.append(.{ .name = f_name, .ty = f_ty });
                field_index += 1;
                if (!self.match(.comma)) break;
            }
            try self.expect(.r_paren);
        } else {
            try self.expect(.l_brace);
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

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .struct_decl = .{
                .name = name,
                .generics = try generics.toOwnedSlice(),
                .fields = try fields.toOwnedSlice(),
                .is_union = is_union,
                .is_opaque = is_opaque,
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
            try self.expectGenericClose();
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
            } else if (self.match(.l_paren)) {
                var field_index: usize = 0;
                while (self.peek() != .r_paren and self.peek() != .eof) {
                    const f_ty = try self.parseType();
                    const f_name = std.fmt.allocPrint(self.allocator, "{}", .{field_index}) catch return ParserError.OutOfMemory;
                    try fields.append(.{ .name = f_name, .ty = f_ty });
                    field_index += 1;
                    if (!self.match(.comma)) break;
                }
                try self.expect(.r_paren);
            }

            try variants.append(.{ .name = variant_name, .fields = try fields.toOwnedSlice() });
            _ = self.match(.comma);
        }
        try self.expect(.r_brace);

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .enum_decl = .{ .name = name, .generics = try generics.toOwnedSlice(), .variants = try variants.toOwnedSlice() } };
        return node;
    }

    fn parseTraitDecl(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_trait);
        const name_tok = self.tok;
        try self.expect(.identifier);
        const name = self.lexeme(name_tok.loc);
        var supertraits = std.ArrayList([]const u8).init(self.allocator);
        if (self.match(.colon)) {
            while (true) {
                const super_tok = self.tok;
                try self.expect(.identifier);
                try supertraits.append(self.lexeme(super_tok.loc));
                if (!self.match(.plus)) break;
            }
        }
        try self.expect(.l_brace);

        var methods = std.ArrayList(ast.TraitMethod).init(self.allocator);
        while (self.peek() != .r_brace and self.peek() != .eof) {
            try self.expect(.keyword_fn);
            const method_name_tok = self.tok;
            try self.expect(.identifier);
            const method_name = self.lexeme(method_name_tok.loc);

            _ = try self.parseGenericParams();

            try self.expect(.l_paren);
            var params = std.ArrayList(ast.Param).init(self.allocator);
            if (self.peek() != .r_paren and self.peek() != .eof) {
                const first_is_borrow = self.match(.ampersand);
                const first_is_move = if (!first_is_borrow) self.match(.caret) else false;
                const first_tok = self.tok;
                try self.expect(.identifier);
                const first_name = self.lexeme(first_tok.loc);

                if (std.mem.eql(u8, first_name, "self")) {
                    const self_ty = try self.makeUserDefinedType("Self", &.{});
                    try params.append(.{ .name = "self", .ty = self_ty, .is_borrow = first_is_borrow, .is_move = first_is_move });
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
                } else {
                    try self.expect(.colon);
                    const first_ty = try self.parseType();
                    try params.append(.{ .name = first_name, .ty = first_ty, .is_borrow = first_is_borrow, .is_move = first_is_move });
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
            try self.expect(.semicolon);
            try methods.append(.{ .name = method_name, .params = try params.toOwnedSlice(), .ret_ty = ret_ty });
        }
        try self.expect(.r_brace);

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .trait_decl = .{ .name = name, .supertraits = try supertraits.toOwnedSlice(), .methods = try methods.toOwnedSlice() } };
        return node;
    }

    fn parseImplDecl(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_impl);
        const first_ty = try self.parseType();
        var trait_name: ?[]const u8 = null;
        var target_ty = first_ty;
        if (self.match(.keyword_for)) {
            switch (first_ty.*) {
                .user_defined => |ud| trait_name = ud.name,
                else => return ParserError.UnexpectedTypeToken,
            }
            target_ty = try self.parseType();
        }
        try self.expect(.l_brace);

        var methods = std.ArrayList(*ast.Node).init(self.allocator);
        const prev_impl_target = self.current_impl_target;
        self.current_impl_target = target_ty;
        defer self.current_impl_target = prev_impl_target;
        while (self.peek() != .r_brace and self.peek() != .eof) {
            const is_inline = self.match(.keyword_inline);
            const is_async = self.match(.keyword_async);
            if (is_inline or is_async) return ParserError.ExpectedDeclaration;
            try methods.append(try self.parseMethodDecl(target_ty));
            _ = self.match(.semicolon);
        }
        try self.expect(.r_brace);

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .impl_decl = .{ .trait_name = trait_name, .target_ty = target_ty, .methods = try methods.toOwnedSlice() } };
        return node;
    }

    fn parseGenericParams(self: *Parser) ParserError![]const []const u8 {
        var generics = std.ArrayList([]const u8).init(self.allocator);
        if (self.match(.less_than)) {
            while (true) {
                const g_tok = self.tok;
                try self.expect(.identifier);
                try generics.append(self.lexeme(g_tok.loc));
                if (self.match(.colon)) {
                    try self.expect(.identifier);
                }
                if (!self.match(.comma)) break;
            }
            try self.expectGenericClose();
        }
        return try generics.toOwnedSlice();
    }

    fn parseMethodDecl(self: *Parser, target_ty: *ast.Type) ParserError!*ast.Node {
        try self.expect(.keyword_fn);
        const name_tok = self.tok;
        try self.expect(.identifier);
        const name = self.lexeme(name_tok.loc);

        const generics = try self.parseGenericParams();

        try self.expect(.l_paren);

        var params = std.ArrayList(ast.Param).init(self.allocator);
        if (self.peek() != .r_paren and self.peek() != .eof) {
            const first_is_borrow = self.match(.ampersand);
            const first_is_move = if (!first_is_borrow) self.match(.caret) else false;
            const first_tok = self.tok;
            try self.expect(.identifier);
            const first_name = self.lexeme(first_tok.loc);

            if (std.mem.eql(u8, first_name, "self")) {
                try params.append(.{ .name = "self", .ty = target_ty, .is_borrow = first_is_borrow, .is_move = first_is_move });
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
            } else {
                try self.expect(.colon);
                const first_ty = try self.parseType();
                try params.append(.{ .name = first_name, .ty = first_ty, .is_borrow = first_is_borrow, .is_move = first_is_move });
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
                .is_pub = false,
                .generics = generics,
                .params = try params.toOwnedSlice(),
                .ret_ty = ret_ty,
                .body = body,
                .is_inline = false,
                .is_async = false,
            },
        };
        return node;
    }

    fn parseFuncDecl(self: *Parser, is_pub: bool, is_inline: bool, is_async: bool, is_extern: bool, abi: ?[]const u8, no_mangle: bool, is_decl_only: bool) ParserError!*ast.Node {
        try self.expect(.keyword_fn);
        const name_tok = self.tok;
        try self.expect(.identifier);
        const name = self.lexeme(name_tok.loc);

        const generics = try self.parseGenericParams();

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

        const body = if (is_decl_only) &.{} else try self.parseBlock();

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .func_decl = .{
                .name = name,
                .is_pub = is_pub,
                .is_extern = is_extern,
                .abi = abi,
                .no_mangle = no_mangle,
                .is_decl_only = is_decl_only,
                .generics = generics,
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
        const import_path = if (self.peek() == .string_literal) blk: {
            const path_tok = self.tok;
            try self.expect(.string_literal);
            const raw_path = self.lexeme(path_tok.loc);
            if (raw_path.len < 2 or raw_path[0] != '"' or raw_path[raw_path.len - 1] != '"') {
                return ParserError.SyntaxError;
            }
            break :blk raw_path[1 .. raw_path.len - 1];
        } else try self.parseImportPathTokenSequence();
        _ = self.match(.semicolon);

        // For cross-file .sla imports, pre-scan the imported file for declared
        // type/enum names so the rest of this file can recognize struct literals
        // like `ImportedType { ... }`. This mirrors how plugin.zig later merges
        // the imported AST, but the parser needs the names earlier to disambiguate
        // `Name { ... }` from a block during its single forward pass.
        if (std.mem.endsWith(u8, import_path, ".sla")) {
            self.prescanSlaImportTypes(import_path) catch {};
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .import_decl = .{ .path = import_path } };
        return node;
    }

    fn prescanSlaImportTypes(self: *Parser, import_path: []const u8) !void {
        // Bound recursion depth to avoid pathological import graphs.
        if (self.import_scan_depth >= 32) return;

        if (isGlobImportPath(import_path)) {
            const pattern_path = if (std.fs.path.isAbsolute(import_path))
                try self.allocator.dupe(u8, import_path)
            else
                try std.fs.path.join(self.allocator, &.{ self.base_dir, import_path });

            const dir_path = std.fs.path.dirname(pattern_path) orelse ".";
            const pattern_name = std.fs.path.basename(pattern_path);
            var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
            defer dir.close();

            var matches = std.ArrayList([]const u8).init(self.allocator);
            var it = dir.iterate();
            while (try it.next()) |entry| {
                if (entry.kind != .file and entry.kind != .sym_link) continue;
                if (!globNameMatches(pattern_name, entry.name)) continue;
                if (!std.mem.endsWith(u8, entry.name, ".sla")) continue;
                const child_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
                try matches.append(child_path);
            }
            std.mem.sort([]const u8, matches.items, {}, stringSliceLessThan);
            for (matches.items) |child_path| {
                try self.prescanResolvedSlaImportTypes(child_path);
            }
            return;
        }

        const resolved_path = if (std.fs.path.isAbsolute(import_path))
            try self.allocator.dupe(u8, import_path)
        else
            try std.fs.path.join(self.allocator, &.{ self.base_dir, import_path });

        try self.prescanResolvedSlaImportTypes(resolved_path);
    }

    fn prescanResolvedSlaImportTypes(self: *Parser, resolved_path: []const u8) !void {
        const source = std.fs.cwd().readFileAlloc(self.allocator, resolved_path, 16 * 1024 * 1024) catch return;

        const import_dir = std.fs.path.dirname(resolved_path) orelse ".";

        var sub = initWithDir(self.allocator, source, import_dir);
        sub.import_scan_depth = self.import_scan_depth + 1;
        const prog = sub.parseProgram() catch return;
        if (prog.* != .program) return;

        // Merge the names the sub-parser collected (it recursively pre-scans its
        // own .sla imports too, so transitive types come along).
        for (sub.known_types.items) |name| {
            if (!self.isKnownTypeName(name)) try self.known_types.append(name);
        }
        for (sub.known_enums.items) |name| {
            if (!self.isKnownEnumName(name)) try self.known_enums.append(name);
        }
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
        } else if (self.peek() == .keyword_while) {
            return try self.parseWhileStmt();
        } else if (self.peek() == .keyword_break) {
            return try self.parseBreakStmt();
        } else if (self.peek() == .keyword_continue) {
            return try self.parseContinueStmt();
        } else if (self.peek() == .bang) {
            return try self.parseReleaseStmt();
        } else if (self.peek() == .l_brace) {
            const body = try self.parseBlock();
            const node = try self.allocator.create(ast.Node);
            node.* = .{ .block_stmt = .{ .body = body } };
            return node;
        } else {
            const expr = try self.parseExpr(0);
            if (self.match(.equal)) {
                const rhs = try self.parseExpr(0);
                try self.expect(.semicolon);
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .assign_stmt = .{ .target = expr, .value = rhs } };
                return node;
            }
            if (self.match(.plus_equal)) {
                const rhs = try self.parseExpr(0);
                try self.expect(.semicolon);
                const sum = try self.allocator.create(ast.Node);
                sum.* = .{ .binary_expr = .{ .op = .add, .left = expr, .right = rhs } };
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .assign_stmt = .{ .target = expr, .value = sum } };
                return node;
            }
            if (self.match(.pipe_equal)) {
                const rhs = try self.parseExpr(0);
                try self.expect(.semicolon);
                const value = try self.allocator.create(ast.Node);
                value.* = .{ .binary_expr = .{ .op = .bit_or, .left = expr, .right = rhs } };
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .assign_stmt = .{ .target = expr, .value = value } };
                return node;
            }
            if (self.match(.ampersand_equal)) {
                const rhs = try self.parseExpr(0);
                try self.expect(.semicolon);
                const value = try self.allocator.create(ast.Node);
                value.* = .{ .binary_expr = .{ .op = .bit_and, .left = expr, .right = rhs } };
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .assign_stmt = .{ .target = expr, .value = value } };
                return node;
            }
            if (!self.match(.semicolon)) {
                if (self.peek() != .r_brace) {
                    try self.expect(.semicolon);
                }
            }
            const node = try self.allocator.create(ast.Node);
            node.* = .{ .expr_stmt = expr };
            return node;
        }
    }

    fn parseLetStmt(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_let);
        _ = self.match(.keyword_mut);

        if (self.peek() == .identifier) {
            const first_name = self.lexeme(self.tok.loc);
            if (std.mem.eql(u8, first_name, "Some") or std.mem.eql(u8, first_name, "None") or std.mem.eql(u8, first_name, "Option") or
                std.mem.eql(u8, first_name, "Ok") or std.mem.eql(u8, first_name, "Err") or std.mem.eql(u8, first_name, "Result") or
                self.isKnownEnumName(first_name))
            {
                const pattern = try self.parseLetPattern();
                try self.expect(.equal);
                const val = try self.parseExpr(0);
                try self.expect(.keyword_else);
                const else_block = try self.parseBlock();
                try self.expect(.semicolon);

                const node = try self.allocator.create(ast.Node);
                node.* = .{ .let_else_stmt = .{ .pattern = pattern, .value = val, .else_block = else_block } };
                return node;
            }
        }

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
        const end = if (self.match(.range)) try self.parseExpr(0) else null;

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

    fn parseWhileStmt(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_while);
        var let_pattern: ?ast.EnumPattern = null;
        const cond = if (self.match(.keyword_let)) blk: {
            let_pattern = try self.parseLetPattern();
            try self.expect(.equal);
            break :blk try self.parseExpr(0);
        } else try self.parseExpr(0);
        const body = try self.parseBlock();

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .while_stmt = .{
                .cond = cond,
                .let_pattern = let_pattern,
                .body = body,
            },
        };
        return node;
    }

    fn parseBreakStmt(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_break);
        try self.expect(.semicolon);

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .break_stmt = .{} };
        return node;
    }

    fn parseContinueStmt(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_continue);
        try self.expect(.semicolon);

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .continue_stmt = .{} };
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
                .greater_greater => {
                    if (depth <= 2) {
                        tok_copy = lex_copy.next();
                        return tok_copy.tag == .l_brace;
                    }
                    depth -= 2;
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
        try self.expectGenericClose();
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
        } else if (self.match(.l_paren)) {
            var field_index: usize = 0;
            while (self.peek() != .r_paren and self.peek() != .eof) {
                const value = try self.parseExpr(0);
                const field_name = std.fmt.allocPrint(self.allocator, "{}", .{field_index}) catch return ParserError.OutOfMemory;
                try fields.append(.{ .name = field_name, .value = value });
                field_index += 1;
                if (!self.match(.comma)) break;
            }
            try self.expect(.r_paren);
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .enum_literal = .{ .enum_name = enum_name, .variant_name = variant_name, .fields = try fields.toOwnedSlice() } };
        return node;
    }

    fn parseModuleCallAfterName(self: *Parser, module_name: []const u8) ParserError!*ast.Node {
        try self.expect(.double_colon);

        var path_parts = std.ArrayList([]const u8).init(self.allocator);
        try path_parts.append(module_name);

        while (true) {
            const part_tok = self.tok;
            try self.expect(.identifier);
            try path_parts.append(self.lexeme(part_tok.loc));
            if (self.peek() == .double_colon) {
                var lex_copy = self.lex;
                const next_tok = lex_copy.next();
                if (next_tok.tag == .less_than) break;
                self.advance();
                continue;
            }
            break;
        }

        var generics = std.ArrayList(*ast.Type).init(self.allocator);
        _ = self.match(.double_colon);
        if (self.match(.less_than)) {
            while (true) {
                const ty = try self.parseType();
                try generics.append(ty);
                if (!self.match(.comma)) break;
            }
            try self.expectGenericClose();
        }

        try self.expect(.l_paren);
        var args = std.ArrayList(*ast.Node).init(self.allocator);
        while (self.peek() != .r_paren and self.peek() != .eof) {
            const arg = try self.parseExpr(0);
            try args.append(arg);
            if (!self.match(.comma)) break;
        }
        try self.expect(.r_paren);

        var name_buf = std.ArrayList(u8).init(self.allocator);
        for (path_parts.items, 0..) |part, i| {
            if (i > 0) try name_buf.appendSlice("__");
            try name_buf.appendSlice(part);
        }

        const node = try self.allocator.create(ast.Node);
        node.* = .{
            .call_expr = .{
                .func_name = try name_buf.toOwnedSlice(),
                .associated_target = null,
                .generics = try generics.toOwnedSlice(),
                .args = try args.toOwnedSlice(),
            },
        };
        return node;
    }

    fn parseAssociatedCallAfterName(self: *Parser, target_name: []const u8) ParserError!*ast.Node {
        try self.expect(.double_colon);
        const name_tok = self.tok;
        try self.expect(.identifier);
        const func_name = self.lexeme(name_tok.loc);
        try self.expect(.l_paren);

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
                .associated_target = target_name,
                .generics = &.{},
                .args = try args.toOwnedSlice(),
            },
        };
        return node;
    }

    fn looksLikeGenericFunctionCallTail(self: *Parser) bool {
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
                        return tok_copy.tag == .l_paren;
                    }
                },
                .greater_greater => {
                    if (depth <= 2) {
                        tok_copy = lex_copy.next();
                        return tok_copy.tag == .l_paren;
                    }
                    depth -= 2;
                },
                else => {},
            }
            tok_copy = lex_copy.next();
        }
        return false;
    }

    fn parseGenericCallTail(self: *Parser, func_name: []const u8) ParserError!*ast.Node {
        var generics = std.ArrayList(*ast.Type).init(self.allocator);
        while (true) {
            const ty = try self.parseType();
            try generics.append(ty);
            if (!self.match(.comma)) break;
        }
        try self.expectGenericClose();
        try self.expect(.l_paren);

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
                .associated_target = null,
                .generics = try generics.toOwnedSlice(),
                .args = try args.toOwnedSlice(),
            },
        };
        return node;
    }

    fn parseClosureLiteral(self: *Parser) ParserError!*ast.Node {
        try self.expect(.pipe);
        var params = std.ArrayList(ast.Param).init(self.allocator);
        while (self.peek() != .pipe and self.peek() != .eof) {
            const p_tok = self.tok;
            try self.expect(.identifier);
            const p_name = self.lexeme(p_tok.loc);
            const p_ty = if (self.match(.colon)) blk: {
                break :blk try self.parseType();
            } else blk: {
                const ty = try self.allocator.create(ast.Type);
                ty.* = .infer;
                break :blk ty;
            };
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
        const first_name = self.lexeme(enum_tok.loc);

        var enum_name: []const u8 = if (std.mem.eql(u8, first_name, "Ok") or std.mem.eql(u8, first_name, "Err")) "Result" else "Option";
        var variant_name: []const u8 = first_name;
        if (self.match(.double_colon)) {
            const variant_tok = self.tok;
            try self.expect(.identifier);
            enum_name = first_name;
            variant_name = self.lexeme(variant_tok.loc);
        } else if (!std.mem.eql(u8, first_name, "Some") and !std.mem.eql(u8, first_name, "None") and
            !std.mem.eql(u8, first_name, "Ok") and !std.mem.eql(u8, first_name, "Err"))
        {
            return ParserError.UnexpectedToken;
        }

        var bindings = std.ArrayList([]const u8).init(self.allocator);
        if (self.match(.l_brace)) {
            while (self.peek() != .r_brace and self.peek() != .eof) {
                const bind_tok = self.tok;
                try self.expect(.identifier);
                try bindings.append(self.lexeme(bind_tok.loc));
                _ = self.match(.comma);
            }
            try self.expect(.r_brace);
        } else if (self.match(.l_paren)) {
            while (self.peek() != .r_paren and self.peek() != .eof) {
                const bind_tok = self.tok;
                try self.expect(.identifier);
                try bindings.append(self.lexeme(bind_tok.loc));
                if (!self.match(.comma)) break;
            }
            try self.expect(.r_paren);
        }

        return .{ .enum_name = enum_name, .variant_name = variant_name, .bindings = try bindings.toOwnedSlice() };
    }

    fn parseLetPattern(self: *Parser) ParserError!ast.EnumPattern {
        const first_tok = self.tok;
        try self.expect(.identifier);
        const first_name = self.lexeme(first_tok.loc);

        var enum_name: []const u8 = if (std.mem.eql(u8, first_name, "Ok") or std.mem.eql(u8, first_name, "Err")) "Result" else "Option";
        var variant_name: []const u8 = first_name;
        if (self.match(.double_colon)) {
            const variant_tok = self.tok;
            try self.expect(.identifier);
            enum_name = first_name;
            variant_name = self.lexeme(variant_tok.loc);
        }

        var bindings = std.ArrayList([]const u8).init(self.allocator);
        if (self.match(.l_brace)) {
            while (self.peek() != .r_brace and self.peek() != .eof) {
                const bind_tok = self.tok;
                try self.expect(.identifier);
                try bindings.append(self.lexeme(bind_tok.loc));
                _ = self.match(.comma);
            }
            try self.expect(.r_brace);
        } else if (self.match(.l_paren)) {
            while (self.peek() != .r_paren and self.peek() != .eof) {
                const bind_tok = self.tok;
                try self.expect(.identifier);
                try bindings.append(self.lexeme(bind_tok.loc));
                if (!self.match(.comma)) break;
            }
            try self.expect(.r_paren);
        }

        return .{ .enum_name = enum_name, .variant_name = variant_name, .bindings = try bindings.toOwnedSlice() };
    }

    fn parseIfLetChain(self: *Parser) ParserError![]const ast.IfLetCond {
        var chain = std.ArrayList(ast.IfLetCond).init(self.allocator);
        while (true) {
            try self.expect(.keyword_let);
            const pattern = try self.parseLetPattern();
            try self.expect(.equal);
            const value = try self.parseExpr(0);
            try chain.append(.{ .pattern = pattern, .value = value });
            if (!self.match(.amp_amp)) break;
            if (self.peek() != .keyword_let) return ParserError.UnexpectedToken;
        }
        return try chain.toOwnedSlice();
    }

    fn parseMatchExpr(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_match);
        const val = try self.parseExpr(0);
        try self.expect(.l_brace);

        var cases = std.ArrayList(ast.MatchCase).init(self.allocator);
        while (self.peek() != .r_brace and self.peek() != .eof) {
            const pattern = try self.parseEnumPattern();
            const guard = if (self.match(.keyword_if)) try self.parseExpr(0) else null;
            try self.expect(.fat_arrow);
            const body = try self.parseBlock();
            try cases.append(.{ .pattern = pattern, .guard = guard, .body = body });
            _ = self.match(.comma);
        }
        try self.expect(.r_brace);

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .match_expr = .{ .val = val, .cases = try cases.toOwnedSlice() } };
        return node;
    }

    fn parseInlineAsmExpr(self: *Parser) ParserError!*ast.Node {
        try self.expect(.l_paren);
        const template_tok = self.tok;
        try self.expect(.string_literal);
        const raw_template = self.lexeme(template_tok.loc);

        var operands = std.ArrayList(ast.InlineAsmOperand).init(self.allocator);
        while (self.match(.comma)) {
            if (self.peek() == .r_paren) break;
            const constraint_tok = self.tok;
            try self.expect(.identifier);
            const constraint = self.lexeme(constraint_tok.loc);
            try self.expect(.l_paren);
            const reg_tok = self.tok;
            try self.expect(.string_literal);
            const raw_reg = self.lexeme(reg_tok.loc);
            try self.expect(.r_paren);
            const value_tok = self.tok;
            try self.expect(.identifier);
            const value_name = self.lexeme(value_tok.loc);
            _ = raw_reg;
            try operands.append(.{ .constraint = constraint, .var_name = value_name });
        }
        try self.expect(.r_paren);

        const node = try self.allocator.create(ast.Node);
        node.* = .{ .inline_asm_expr = .{ .template = raw_template[1 .. raw_template.len - 1], .operands = try operands.toOwnedSlice() } };
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
                var digit_len: usize = 0;
                var base: u8 = 10;
                var digits_start: usize = 0;
                if (str.len >= 2 and str[0] == '0' and (str[1] == 'x' or str[1] == 'X')) {
                    base = 16;
                    digits_start = 2;
                    digit_len = 2;
                    while (digit_len < str.len and std.ascii.isHex(str[digit_len])) : (digit_len += 1) {}
                } else {
                    while (digit_len < str.len and std.ascii.isDigit(str[digit_len])) : (digit_len += 1) {}
                }
                const val = std.fmt.parseInt(i64, str[digits_start..digit_len], base) catch return ParserError.InvalidCharacter;
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .literal = .{ .int_val = val } };
                if (digit_len < str.len) {
                    const suffix = str[digit_len..];
                    const primitive: ast.Primitive = if (std.mem.eql(u8, suffix, "i8")) .i8 else if (std.mem.eql(u8, suffix, "i16")) .i16 else if (std.mem.eql(u8, suffix, "i32")) .i32 else if (std.mem.eql(u8, suffix, "i64")) .i64 else if (std.mem.eql(u8, suffix, "isize")) .isize else if (std.mem.eql(u8, suffix, "u8")) .u8 else if (std.mem.eql(u8, suffix, "u16")) .u16 else if (std.mem.eql(u8, suffix, "u32")) .u32 else if (std.mem.eql(u8, suffix, "u64")) .u64 else if (std.mem.eql(u8, suffix, "usize")) .usize else return ParserError.InvalidCharacter;
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .primitive = primitive };
                    const cast_node = try self.allocator.create(ast.Node);
                    cast_node.* = .{ .cast_expr = .{ .expr = node, .ty = ty } };
                    return cast_node;
                }
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
                if (std.mem.eql(u8, str, "asm") and self.match(.bang)) {
                    return try self.parseInlineAsmExpr();
                }
                if (self.peek() == .double_colon) {
                    if (self.isKnownEnumName(str)) {
                        return try self.parseEnumLiteralAfterName(str);
                    }
                    if (self.isKnownModuleName(str)) {
                        return try self.parseModuleCallAfterName(str);
                    }
                    var lex_copy = self.lex;
                    var tok_copy = lex_copy.next();
                    if (tok_copy.tag == .identifier) {
                        const assoc_name = self.lexeme(tok_copy.loc);
                        tok_copy = lex_copy.next();
                        if (tok_copy.tag == .double_colon) {
                            return try self.parseModuleCallAfterName(str);
                        }
                        if (tok_copy.tag == .l_paren) {
                            return try self.parseAssociatedCallAfterName(str);
                        }
                        if (std.mem.eql(u8, str, "Ordering")) {
                            _ = self.match(.double_colon);
                            const assoc_tok = self.tok;
                            try self.expect(.identifier);
                            const node = try self.allocator.create(ast.Node);
                            node.* = .{ .identifier = try std.fmt.allocPrint(self.allocator, "{s}::{s}", .{ str, self.lexeme(assoc_tok.loc) }) };
                            return node;
                        }
                        _ = assoc_name;
                    }
                    return try self.parseEnumLiteralAfterName(str);
                }
                if (self.peek() == .l_brace and self.isKnownTypeName(str)) {
                    const lit_ty = if (std.mem.eql(u8, str, "Self"))
                        self.current_impl_target orelse return ParserError.UnexpectedTypeToken
                    else
                        try self.makeUserDefinedType(str, &.{});
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
            .keyword_unsafe => {
                self.advance();
                const body = try self.parseBlock();
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .unsafe_expr = .{ .body = body } };
                return node;
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
                if (self.peek() != .r_bracket and self.peek() != .eof) {
                    const first = try self.parseExpr(0);
                    if (self.match(.semicolon)) {
                        const len_tok = self.tok;
                        try self.expect(.int_literal);
                        const len_str = self.lexeme(len_tok.loc);
                        var digit_len: usize = 0;
                        while (digit_len < len_str.len and std.ascii.isDigit(len_str[digit_len])) : (digit_len += 1) {}
                        const len = std.fmt.parseInt(usize, len_str[0..digit_len], 10) catch return ParserError.InvalidCharacter;
                        try self.expect(.r_bracket);
                        const node = try self.allocator.create(ast.Node);
                        node.* = .{ .repeat_array_literal = .{ .value = first, .len = len } };
                        return node;
                    }
                    try elements.append(first);
                    while (self.peek() != .r_bracket and self.peek() != .eof) {
                        if (!self.match(.comma)) break;
                        if (self.peek() == .r_bracket) break;
                        const elem = try self.parseExpr(0);
                        try elements.append(elem);
                    }
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
            .plus, .minus, .asterisk, .slash, .percent, .ampersand, .pipe, .caret, .less_less, .greater_greater, .less_than, .greater_than, .less_equal, .greater_equal, .equal_equal, .bang_equal => {
                if (tag == .less_than and left.* == .identifier and self.looksLikeGenericStructLiteralTail()) {
                    return try self.parseGenericStructLiteralTail(left.identifier);
                }
                if (tag == .less_than and left.* == .identifier and self.looksLikeGenericFunctionCallTail()) {
                    return try self.parseGenericCallTail(left.identifier);
                }

                const op = switch (tag) {
                    .plus => ast.BinaryOp.add,
                    .minus => ast.BinaryOp.sub,
                    .asterisk => ast.BinaryOp.mul,
                    .slash => ast.BinaryOp.div,
                    .percent => ast.BinaryOp.mod,
                    .ampersand => ast.BinaryOp.bit_and,
                    .pipe => ast.BinaryOp.bit_or,
                    .caret => ast.BinaryOp.bit_xor,
                    .less_less => ast.BinaryOp.shl,
                    .greater_greater => ast.BinaryOp.shr,
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
                        try self.expectGenericClose();
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
                            .associated_target = null,
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
                        .associated_target = null,
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
                        .associated_target = null,
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
            .keyword_as => {
                const cast_ty = try self.parseType();
                const node = try self.allocator.create(ast.Node);
                node.* = .{ .cast_expr = .{ .expr = left, .ty = cast_ty } };
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
            .pipe => 1,
            .caret => 2,
            .ampersand => 3,
            .equal_equal, .bang_equal => 4,
            .less_than, .greater_than, .less_equal, .greater_equal => 5,
            .less_less, .greater_greater => 6,
            .plus, .minus => 7,
            .asterisk, .slash, .percent => 8,
            .dot, .bang, .l_paren, .l_bracket, .question_mark => 10,
            .keyword_as => 9,
            else => 0,
        };
    }

    fn parseIfExpr(self: *Parser) ParserError!*ast.Node {
        try self.expect(.keyword_if);
        var let_chain: ?[]const ast.IfLetCond = null;
        const cond = if (self.peek() == .keyword_let) blk: {
            const parsed_chain = try self.parseIfLetChain();
            let_chain = parsed_chain;
            break :blk parsed_chain[0].value;
        } else try self.parseExpr(0);
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
                .let_chain = let_chain,
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

        const makePrimitive = struct {
            fn apply(allocator: std.mem.Allocator, primitive: ast.Primitive) ParserError!*ast.Type {
                const ty = allocator.create(ast.Type) catch return ParserError.OutOfMemory;
                ty.* = .{ .primitive = primitive };
                return ty;
            }
        }.apply;

        switch (tag) {
            .identifier => {
                const name = self.lexeme(tok.loc);
                if (std.mem.eql(u8, name, "Self")) {
                    return self.current_impl_target orelse return ParserError.UnexpectedTypeToken;
                } else if (std.mem.eql(u8, name, "int")) {
                    return try makePrimitive(self.allocator, .i64);
                } else if (std.mem.eql(u8, name, "float")) {
                    return try makePrimitive(self.allocator, .f64);
                } else if (std.mem.eql(u8, name, "bool")) {
                    return try makePrimitive(self.allocator, .boolean);
                } else if (std.mem.eql(u8, name, "void")) {
                    return try makePrimitive(self.allocator, .void_type);
                } else if (std.mem.eql(u8, name, "ptr")) {
                    return try makePrimitive(self.allocator, .void_type);
                } else if (std.mem.eql(u8, name, "i8")) {
                    return try makePrimitive(self.allocator, .i8);
                } else if (std.mem.eql(u8, name, "i16")) {
                    return try makePrimitive(self.allocator, .i16);
                } else if (std.mem.eql(u8, name, "i32")) {
                    return try makePrimitive(self.allocator, .i32);
                } else if (std.mem.eql(u8, name, "i64")) {
                    return try makePrimitive(self.allocator, .i64);
                } else if (std.mem.eql(u8, name, "isize")) {
                    return try makePrimitive(self.allocator, .isize);
                } else if (std.mem.eql(u8, name, "u8")) {
                    return try makePrimitive(self.allocator, .u8);
                } else if (std.mem.eql(u8, name, "u16")) {
                    return try makePrimitive(self.allocator, .u16);
                } else if (std.mem.eql(u8, name, "u32")) {
                    return try makePrimitive(self.allocator, .u32);
                } else if (std.mem.eql(u8, name, "u64")) {
                    return try makePrimitive(self.allocator, .u64);
                } else if (std.mem.eql(u8, name, "usize")) {
                    return try makePrimitive(self.allocator, .usize);
                } else if (std.mem.eql(u8, name, "f32")) {
                    return try makePrimitive(self.allocator, .f32);
                } else if (std.mem.eql(u8, name, "f64")) {
                    return try makePrimitive(self.allocator, .f64);
                }

                var generics = std.ArrayList(*ast.Type).init(self.allocator);
                if (self.match(.less_than)) {
                    while (true) {
                        const t = try self.parseType();
                        try generics.append(t);
                        if (!self.match(.comma)) break;
                    }
                    try self.expectGenericClose();
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
            .keyword_dyn => {
                const trait_tok = self.tok;
                try self.expect(.identifier);
                const trait_name = self.lexeme(trait_tok.loc);
                return try self.makeUserDefinedType(
                    try std.fmt.allocPrint(self.allocator, "__dyn_{s}", .{trait_name}),
                    &.{},
                );
            },
            .keyword_extern => {
                const abi = try self.parseOptionalExternAbi();
                try self.expect(.keyword_fn);
                return try self.parseFunctionType(abi);
            },
            .keyword_fn => {
                return try self.parseFunctionType(null);
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
                if (self.match(.semicolon)) {
                    const len_tok = self.tok;
                    try self.expect(.int_literal);
                    const len_str = self.lexeme(len_tok.loc);
                    const len = std.fmt.parseInt(usize, len_str, 10) catch return ParserError.InvalidCharacter;
                    try self.expect(.r_bracket);
                    const ty = try self.allocator.create(ast.Type);
                    ty.* = .{ .array = .{ .elem = elem, .len = len } };
                    return ty;
                }
                try self.expect(.r_bracket);
                const generics = try self.allocator.alloc(*ast.Type, 1);
                generics[0] = elem;
                return try self.makeUserDefinedType("Slice", generics);
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

    fn parseFunctionType(self: *Parser, abi: ?[]const u8) ParserError!*ast.Type {
        try self.expect(.l_paren);
        var params = std.ArrayList(*ast.Type).init(self.allocator);
        while (self.peek() != .r_paren and self.peek() != .eof) {
            const param_ty = try self.parseType();
            try params.append(param_ty);
            if (!self.match(.comma)) break;
        }
        try self.expect(.r_paren);

        var ret_ty = try self.allocator.create(ast.Type);
        ret_ty.* = .{ .primitive = .void_type };
        if (self.match(.arrow)) {
            ret_ty = try self.parseType();
        }

        const ty = try self.allocator.create(ast.Type);
        ty.* = .{ .fn_ptr = .{ .abi = abi, .params = try params.toOwnedSlice(), .ret = ret_ty } };
        return ty;
    }
};

test "parse struct and function" {
    const source =
        \\struct Option<T> {
        \\    has_value: bool,
        \\    value: T
        \\}
        \\
        \\fn sum_range(limit: i64) -> i64 {
        \\    let sum = 0;
        \\    for i in 1..limit {
        \\        sum = sum + i;
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn try_demo() -> i64 {
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
    try std.testing.expect(d2.func_decl.ret_ty.primitive == .i64);

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
