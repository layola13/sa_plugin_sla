//! J-1 (declaration sublanguage registration): the `shader`
//! sublanguage — the motivating registered declaration kind.
//!
//! The parser half produces a typed `ast.ShaderDecl` (the SLASL
//! schema of DESIGN.md section 6.1); the checker half implements the
//! section 6.2 rule subset (declaration rules, dimension/type rules,
//! stage rules) and reports through the shared diagnostic channel:
//! the caller (`type_checker`) turns `Diagnostic.text` into the
//! program's check error. Target emission is NOT here — per J-7 the
//! SLASL linker is ordinary library code, so a shader declaration
//! lowers to no SA in this batch.

const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const parser_mod = @import("parser.zig");

const Parser = parser_mod.Parser;
const ParserError = parser_mod.ParserError;

pub const Diagnostic = struct {
    text: []const u8 = "",
};

const CheckError = error{ CheckFailed, OutOfMemory };

// ---------------------------------------------------------------------
// Sub-parser
// ---------------------------------------------------------------------

fn newExpr(p: *Parser, expr: ast.ShaderExpr) ParserError!*ast.ShaderExpr {
    const node = p.allocator.create(ast.ShaderExpr) catch return ParserError.OutOfMemory;
    node.* = expr;
    return node;
}

fn shaderTypeFromName(name: []const u8) ?ast.ShaderType {
    const table = .{
        .{ "f32", ast.ShaderType.float },
        .{ "float", ast.ShaderType.float },
        .{ "i32", ast.ShaderType.int },
        .{ "int", ast.ShaderType.int },
        .{ "u32", ast.ShaderType.uint },
        .{ "uint", ast.ShaderType.uint },
        .{ "bool", ast.ShaderType.bool_ },
        .{ "vec2", ast.ShaderType.vec2 },
        .{ "vec3", ast.ShaderType.vec3 },
        .{ "vec4", ast.ShaderType.vec4 },
        .{ "mat3", ast.ShaderType.mat3 },
        .{ "mat4", ast.ShaderType.mat4 },
        .{ "sampler2D", ast.ShaderType.sampler2d },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

fn parseShaderType(p: *Parser) ParserError!ast.ShaderType {
    const tok = p.tok;
    try p.expect(.identifier);
    return shaderTypeFromName(p.lexeme(tok.loc)) orelse return ParserError.SyntaxError;
}

fn parseShaderField(p: *Parser) ParserError!ast.ShaderField {
    const name_tok = p.tok;
    try p.expect(.identifier);
    const name = p.lexeme(name_tok.loc);
    try p.expect(.colon);
    const ty = try parseShaderType(p);
    return .{ .name = name, .ty = ty };
}

fn parseLiteral(p: *Parser) ParserError!ast.ShaderLiteral {
    const tok = p.tok;
    switch (p.peek()) {
        .int_literal => {
            p.advance();
            const value = std.fmt.parseInt(i64, p.lexeme(tok.loc), 0) catch return ParserError.Overflow;
            return .{ .int = value };
        },
        .float_literal => {
            p.advance();
            const value = std.fmt.parseFloat(f64, p.lexeme(tok.loc)) catch return ParserError.SyntaxError;
            return .{ .float = value };
        },
        .identifier => {
            const text = p.lexeme(tok.loc);
            if (std.mem.eql(u8, text, "true")) {
                p.advance();
                return .{ .boolean = true };
            }
            if (std.mem.eql(u8, text, "false")) {
                p.advance();
                return .{ .boolean = false };
            }
            return ParserError.SyntaxError;
        },
        .minus => {
            p.advance();
            const inner = try parseLiteral(p);
            return switch (inner) {
                .int => |v| .{ .int = -v },
                .float => |v| .{ .float = -v },
                .boolean => return ParserError.SyntaxError,
            };
        },
        else => return ParserError.SyntaxError,
    }
}

/// Entry point registered in parser.zig for the `shader` kind.
/// Consumes `shader Name { ... }` (the caller dispatched on the
/// leading identifier) and returns the typed declaration node.
pub fn parseShaderDecl(p: *Parser) ParserError!*ast.Node {
    try p.expect(.identifier); // the kind name itself
    const name_tok = p.tok;
    try p.expect(.identifier);
    const name = p.lexeme(name_tok.loc);
    try p.expect(.l_brace);

    var priority: ?i64 = null;
    var globals = std.array_list.Managed(ast.ShaderGlobalGroup).init(p.allocator);
    var inputs = std.array_list.Managed(ast.ShaderField).init(p.allocator);
    var params = std.array_list.Managed(ast.ShaderField).init(p.allocator);
    var consts = std.array_list.Managed(ast.ShaderConst).init(p.allocator);
    var vars = std.array_list.Managed(ast.ShaderField).init(p.allocator);
    var init_stmts = std.array_list.Managed(*ast.ShaderStmt).init(p.allocator);
    var vertex_stmts = std.array_list.Managed(*ast.ShaderStmt).init(p.allocator);
    var fragment_stmts = std.array_list.Managed(*ast.ShaderStmt).init(p.allocator);

    while (p.peek() != .r_brace and p.peek() != .eof) {
        if (p.peek() == .at) {
            p.advance();
            if (p.peek() == .keyword_const) {
                p.advance();
                const field = try parseShaderField(p);
                try p.expect(.equal);
                const value = try parseLiteral(p);
                try p.expect(.semicolon);
                try consts.append(.{ .name = field.name, .ty = field.ty, .value = value });
                continue;
            }
            const qual_tok = p.tok;
            try p.expect(.identifier);
            const qual = p.lexeme(qual_tok.loc);
            if (std.mem.eql(u8, qual, "global")) {
                try p.expect(.keyword_struct);
                const group_tok = p.tok;
                try p.expect(.identifier);
                const group_name = p.lexeme(group_tok.loc);
                try p.expect(.l_brace);
                var fields = std.array_list.Managed(ast.ShaderField).init(p.allocator);
                while (p.peek() != .r_brace and p.peek() != .eof) {
                    try fields.append(try parseShaderField(p));
                    try p.expect(.semicolon);
                }
                try p.expect(.r_brace);
                try globals.append(.{ .name = group_name, .fields = try fields.toOwnedSlice() });
            } else if (std.mem.eql(u8, qual, "input")) {
                try inputs.append(try parseShaderField(p));
                try p.expect(.semicolon);
            } else if (std.mem.eql(u8, qual, "param")) {
                try params.append(try parseShaderField(p));
                try p.expect(.semicolon);
            } else {
                return ParserError.SyntaxError;
            }
        } else if (p.peek() == .keyword_var) {
            p.advance();
            try vars.append(try parseShaderField(p));
            try p.expect(.semicolon);
        } else if (p.peek() == .identifier) {
            const kw_tok = p.tok;
            const kw = p.lexeme(kw_tok.loc);
            if (std.mem.eql(u8, kw, "priority")) {
                p.advance();
                const val_tok = p.tok;
                try p.expect(.int_literal);
                priority = std.fmt.parseInt(i64, p.lexeme(val_tok.loc), 0) catch return ParserError.Overflow;
                try p.expect(.semicolon);
            } else if (std.mem.eql(u8, kw, "init")) {
                p.advance();
                try parseStageBlockInto(p, &init_stmts);
            } else if (std.mem.eql(u8, kw, "vertex")) {
                p.advance();
                try parseStageBlockInto(p, &vertex_stmts);
            } else if (std.mem.eql(u8, kw, "fragment")) {
                p.advance();
                try parseStageBlockInto(p, &fragment_stmts);
            } else {
                return ParserError.SyntaxError;
            }
        } else {
            return ParserError.SyntaxError;
        }
    }
    try p.expect(.r_brace);

    const node = p.allocator.create(ast.Node) catch return ParserError.OutOfMemory;
    node.* = .{ .sublanguage_decl = .{
        .kind = "shader",
        .name = name,
        .payload = .{ .shader = .{
            .name = name,
            .priority = priority,
            .globals = try globals.toOwnedSlice(),
            .inputs = try inputs.toOwnedSlice(),
            .params = try params.toOwnedSlice(),
            .consts = try consts.toOwnedSlice(),
            .vars = try vars.toOwnedSlice(),
            .init = try init_stmts.toOwnedSlice(),
            .vertex = try vertex_stmts.toOwnedSlice(),
            .fragment = try fragment_stmts.toOwnedSlice(),
        } },
    } };
    return node;
}

fn parseStageBlockInto(p: *Parser, out: *std.array_list.Managed(*ast.ShaderStmt)) ParserError!void {
    try p.expect(.l_brace);
    while (p.peek() != .r_brace and p.peek() != .eof) {
        try out.append(try parseShaderStmt(p));
    }
    try p.expect(.r_brace);
}

fn parseShaderStmt(p: *Parser) ParserError!*ast.ShaderStmt {
    const stmt = p.allocator.create(ast.ShaderStmt) catch return ParserError.OutOfMemory;
    if (p.peek() == .keyword_if) {
        p.advance();
        const cond = try parseShaderExpr(p);
        var body = std.array_list.Managed(*ast.ShaderStmt).init(p.allocator);
        try parseStageBlockInto(p, &body);
        stmt.* = .{ .if_stmt = .{ .cond = cond, .body = try body.toOwnedSlice() } };
        return stmt;
    }
    const target = try parseShaderExpr(p);
    try p.expect(.equal);
    const value = try parseShaderExpr(p);
    try p.expect(.semicolon);
    stmt.* = .{ .assign = .{ .target = target, .value = value } };
    return stmt;
}

fn infixOp(tag: lexer.Token.Tag) ?struct { op: ast.ShaderBinOp, prec: u8 } {
    return switch (tag) {
        .pipe_pipe => .{ .op = .or_, .prec = 1 },
        .amp_amp => .{ .op = .and_, .prec = 2 },
        .equal_equal => .{ .op = .eq, .prec = 3 },
        .bang_equal => .{ .op = .ne, .prec = 3 },
        .less_than => .{ .op = .lt, .prec = 4 },
        .less_equal => .{ .op = .le, .prec = 4 },
        .greater_than => .{ .op = .gt, .prec = 4 },
        .greater_equal => .{ .op = .ge, .prec = 4 },
        .plus => .{ .op = .add, .prec = 5 },
        .minus => .{ .op = .sub, .prec = 5 },
        .asterisk => .{ .op = .mul, .prec = 6 },
        .slash => .{ .op = .div, .prec = 6 },
        .percent => .{ .op = .mod, .prec = 6 },
        else => null,
    };
}

fn parseShaderExpr(p: *Parser) ParserError!*ast.ShaderExpr {
    return parseBinary(p, 0);
}

fn parseBinary(p: *Parser, min_prec: u8) ParserError!*ast.ShaderExpr {
    var lhs = try parseUnary(p);
    while (infixOp(p.peek())) |infix| {
        if (infix.prec < min_prec) break;
        p.advance();
        const rhs = try parseBinary(p, infix.prec + 1);
        lhs = try newExpr(p, .{ .binary = .{ .op = infix.op, .lhs = lhs, .rhs = rhs } });
    }
    return lhs;
}

fn parseUnary(p: *Parser) ParserError!*ast.ShaderExpr {
    if (p.peek() == .minus) {
        p.advance();
        const inner = try parseUnary(p);
        return newExpr(p, .{ .unary = .{ .op = .neg, .expr = inner } });
    }
    if (p.peek() == .bang) {
        p.advance();
        const inner = try parseUnary(p);
        return newExpr(p, .{ .unary = .{ .op = .not, .expr = inner } });
    }
    return parsePostfix(p);
}

fn parsePostfix(p: *Parser) ParserError!*ast.ShaderExpr {
    var expr = try parsePrimary(p);
    while (p.peek() == .dot) {
        p.advance();
        const field_tok = p.tok;
        try p.expect(.identifier);
        const field = p.lexeme(field_tok.loc);
        if (std.mem.eql(u8, field, "get") and p.peek() == .l_paren) {
            p.advance();
            const uv = try parseShaderExpr(p);
            try p.expect(.r_paren);
            expr = try newExpr(p, .{ .sample = .{ .tex = expr, .uv = uv } });
        } else {
            expr = try newExpr(p, .{ .member_access = .{ .base = expr, .field = field } });
        }
    }
    return expr;
}

fn parsePrimary(p: *Parser) ParserError!*ast.ShaderExpr {
    const tok = p.tok;
    switch (p.peek()) {
        .int_literal => {
            p.advance();
            const value = std.fmt.parseInt(i64, p.lexeme(tok.loc), 0) catch return ParserError.Overflow;
            return newExpr(p, .{ .int_literal = value });
        },
        .float_literal => {
            p.advance();
            const value = std.fmt.parseFloat(f64, p.lexeme(tok.loc)) catch return ParserError.SyntaxError;
            return newExpr(p, .{ .float_literal = value });
        },
        .l_paren => {
            p.advance();
            const inner = try parseShaderExpr(p);
            try p.expect(.r_paren);
            return inner;
        },
        .identifier => {
            const text = p.lexeme(tok.loc);
            if (std.mem.eql(u8, text, "true")) {
                p.advance();
                return newExpr(p, .{ .bool_literal = true });
            }
            if (std.mem.eql(u8, text, "false")) {
                p.advance();
                return newExpr(p, .{ .bool_literal = false });
            }
            p.advance();
            if (p.peek() == .l_paren) {
                p.advance();
                var args = std.array_list.Managed(*ast.ShaderExpr).init(p.allocator);
                if (p.peek() != .r_paren) {
                    while (true) {
                        try args.append(try parseShaderExpr(p));
                        if (!p.match(.comma)) break;
                    }
                }
                try p.expect(.r_paren);
                const arg_slice = try args.toOwnedSlice();
                if (shaderTypeFromName(text)) |ty| {
                    return newExpr(p, .{ .construct = .{ .ty = ty, .args = arg_slice } });
                }
                return newExpr(p, .{ .call = .{ .name = text, .args = arg_slice } });
            }
            return newExpr(p, .{ .ident = text });
        },
        else => return ParserError.SyntaxError,
    }
}

// ---------------------------------------------------------------------
// Checker (DESIGN.md section 6.2, prototype subset)
// ---------------------------------------------------------------------

const Stage = enum { init, vertex, fragment };

const EntryKind = enum { input, param, constant, variable };

const Entry = struct {
    ty: ast.ShaderType,
    kind: EntryKind,
};

const Checker = struct {
    allocator: std.mem.Allocator,
    diag: *Diagnostic,
    entries: std.StringHashMap(Entry),
    groups: std.StringHashMap(*const ast.ShaderGlobalGroup),

    fn fail(self: *Checker, comptime fmt: []const u8, args: anytype) void {
        if (self.diag.text.len == 0) {
            self.diag.text = std.fmt.allocPrint(self.allocator, fmt, args) catch "ShaderCheckFailed";
        }
    }
};

/// Type-check one shader declaration. On the first violated rule,
/// returns error.CheckFailed with `diag.text` set to the named
/// diagnostic; the caller surfaces it through the shared error
/// channel.
pub fn checkShaderDecl(allocator: std.mem.Allocator, decl: *const ast.ShaderDecl, diag: *Diagnostic) CheckError!void {
    var checker = Checker{
        .allocator = allocator,
        .diag = diag,
        .entries = std.StringHashMap(Entry).init(allocator),
        .groups = std.StringHashMap(*const ast.ShaderGlobalGroup).init(allocator),
    };
    // Declaration rules: one shared namespace across qualifiers;
    // duplicates are an error (cross-fragment merge semantics belong
    // to the linker, J-7, not to a single declaration).
    for (decl.globals) |*group| {
        try declareName(&checker, group.name);
        var seen = std.StringHashMap(void).init(allocator);
        for (group.fields) |field| {
            if (seen.contains(field.name)) {
                checker.fail("ShaderDuplicateName: field `{s}` is declared twice in @global struct `{s}`", .{ field.name, group.name });
                return error.CheckFailed;
            }
            try seen.put(field.name, {});
        }
        try checker.groups.put(group.name, group);
    }
    for (decl.inputs) |field| {
        try declareName(&checker, field.name);
        try checker.entries.put(field.name, .{ .ty = field.ty, .kind = .input });
    }
    for (decl.params) |field| {
        try declareName(&checker, field.name);
        try checker.entries.put(field.name, .{ .ty = field.ty, .kind = .param });
    }
    for (decl.vars) |field| {
        try declareName(&checker, field.name);
        try checker.entries.put(field.name, .{ .ty = field.ty, .kind = .variable });
    }
    for (decl.consts) |constant| {
        try declareName(&checker, constant.name);
        try checker.entries.put(constant.name, .{ .ty = constant.ty, .kind = .constant });
        // @const must carry a literal default of its declared type.
        const matches = switch (constant.value) {
            .boolean => constant.ty == .bool_,
            .float => constant.ty == .float,
            .int => |v| constant.ty == .int or (constant.ty == .uint and v >= 0),
        };
        if (!matches) {
            checker.fail("ShaderConstTypeMismatch: @const `{s}` is declared {s} but its literal default has a different type", .{ constant.name, constant.ty.name() });
            return error.CheckFailed;
        }
    }

    try checkStage(&checker, decl.init, .init);
    try checkStage(&checker, decl.vertex, .vertex);
    try checkStage(&checker, decl.fragment, .fragment);
}

fn declareName(checker: *Checker, name: []const u8) CheckError!void {
    if (std.mem.eql(u8, name, "clip_position") or std.mem.eql(u8, name, "frag_color")) {
        checker.fail("ShaderDuplicateName: `{s}` is a reserved stage output name", .{name});
        return error.CheckFailed;
    }
    if (checker.entries.contains(name) or checker.groups.contains(name)) {
        checker.fail("ShaderDuplicateName: `{s}` is declared more than once in this shader", .{name});
        return error.CheckFailed;
    }
}

fn checkStage(checker: *Checker, stmts: []const *ast.ShaderStmt, stage: Stage) CheckError!void {
    for (stmts) |stmt| {
        switch (stmt.*) {
            .assign => |assign| {
                const target_ty = try checkTarget(checker, assign.target, stage);
                const value_ty = try checkExpr(checker, assign.value, stage);
                if (value_ty != target_ty and !(assign.value.* == .int_literal and target_ty == .float)) {
                    checker.fail("ShaderAssignTypeMismatch: cannot assign {s} to {s}", .{ value_ty.name(), target_ty.name() });
                    return error.CheckFailed;
                }
            },
            .if_stmt => |if_stmt| {
                const cond_ty = try checkExpr(checker, if_stmt.cond, stage);
                if (cond_ty != .bool_) {
                    checker.fail("ShaderConditionType: an if condition must be bool, got {s}", .{cond_ty.name()});
                    return error.CheckFailed;
                }
                try checkStage(checker, if_stmt.body, stage);
            },
        }
    }
}

/// Resolve an assignment target to its type, enforcing writability
/// and stage rules.
fn checkTarget(checker: *Checker, target: *ast.ShaderExpr, stage: Stage) CheckError!ast.ShaderType {
    switch (target.*) {
        .ident => |name| return resolveWritable(checker, name, stage),
        .member_access => |member| {
            if (member.base.* != .ident) {
                checker.fail("ShaderAssignTarget: only a variable or stage output can be assigned", .{});
                return error.CheckFailed;
            }
            const base_name = member.base.ident;
            if (checker.groups.contains(base_name)) {
                checker.fail("ShaderReadOnlyAssign: @global group `{s}` is host-provided and cannot be assigned", .{base_name});
                return error.CheckFailed;
            }
            const base_ty = try resolveWritable(checker, base_name, stage);
            return checkSwizzle(checker, base_ty, member.field, true);
        },
        else => {
            checker.fail("ShaderAssignTarget: only a variable or stage output can be assigned", .{});
            return error.CheckFailed;
        },
    }
}

fn resolveWritable(checker: *Checker, name: []const u8, stage: Stage) CheckError!ast.ShaderType {
    if (std.mem.eql(u8, name, "clip_position")) {
        if (stage != .vertex) {
            checker.fail("ShaderStageViolation: clip_position may only be written in the vertex stage", .{});
            return error.CheckFailed;
        }
        return .vec4;
    }
    if (std.mem.eql(u8, name, "frag_color")) {
        if (stage != .fragment) {
            checker.fail("ShaderStageViolation: frag_color may only be written in the fragment stage", .{});
            return error.CheckFailed;
        }
        return .vec4;
    }
    const entry = checker.entries.get(name) orelse {
        checker.fail("ShaderUnknownName: `{s}` is not declared in this shader", .{name});
        return error.CheckFailed;
    };
    switch (entry.kind) {
        .variable => return entry.ty,
        .param => {
            checker.fail("ShaderReadOnlyAssign: @param `{s}` is read-only", .{name});
            return error.CheckFailed;
        },
        .constant => {
            checker.fail("ShaderReadOnlyAssign: @const `{s}` is read-only", .{name});
            return error.CheckFailed;
        },
        .input => {
            checker.fail("ShaderReadOnlyAssign: @input `{s}` is read-only", .{name});
            return error.CheckFailed;
        },
    }
}

fn resolveReadable(checker: *Checker, name: []const u8, stage: Stage) CheckError!ast.ShaderType {
    if (std.mem.eql(u8, name, "clip_position")) {
        if (stage != .vertex) {
            checker.fail("ShaderStageViolation: clip_position is a vertex-stage output and cannot be read in this stage", .{});
            return error.CheckFailed;
        }
        return .vec4;
    }
    if (std.mem.eql(u8, name, "frag_color")) {
        if (stage != .fragment) {
            checker.fail("ShaderStageViolation: frag_color is a fragment-stage output and cannot be read in this stage", .{});
            return error.CheckFailed;
        }
        return .vec4;
    }
    if (checker.groups.contains(name)) {
        checker.fail("ShaderUnqualifiedGlobal: @global struct `{s}` must be accessed as `{s}.<field>`", .{ name, name });
        return error.CheckFailed;
    }
    const entry = checker.entries.get(name) orelse {
        checker.fail("ShaderUnknownName: `{s}` is not declared in this shader", .{name});
        return error.CheckFailed;
    };
    if (entry.kind == .input and stage != .vertex) {
        checker.fail("ShaderStageViolation: @input `{s}` may only be read in the vertex stage", .{name});
        return error.CheckFailed;
    }
    return entry.ty;
}

/// Validate a swizzle mask against a vector base type and return the
/// result type. Lvalue swizzles may not repeat a component.
fn checkSwizzle(checker: *Checker, base_ty: ast.ShaderType, mask: []const u8, is_lvalue: bool) CheckError!ast.ShaderType {
    if (!base_ty.isVector()) {
        checker.fail("ShaderInvalidSwizzle: cannot swizzle {s}", .{base_ty.name()});
        return error.CheckFailed;
    }
    if (mask.len == 0 or mask.len > 4) {
        checker.fail("ShaderInvalidSwizzle: swizzle `.{s}` must have 1 to 4 components", .{mask});
        return error.CheckFailed;
    }
    const set: []const u8 = if (mask[0] == 'r' or mask[0] == 'g' or mask[0] == 'b' or mask[0] == 'a') "rgba" else "xyzw";
    var seen = [_]bool{ false, false, false, false };
    for (mask) |ch| {
        const idx = std.mem.indexOfScalar(u8, set, ch) orelse {
            checker.fail("ShaderInvalidSwizzle: `.{s}` mixes or uses unknown swizzle components", .{mask});
            return error.CheckFailed;
        };
        if (idx >= base_ty.components()) {
            checker.fail("ShaderInvalidSwizzle: component `{c}` does not exist on {s}", .{ ch, base_ty.name() });
            return error.CheckFailed;
        }
        if (is_lvalue and seen[idx]) {
            checker.fail("ShaderInvalidSwizzle: lvalue swizzle `.{s}` repeats a component", .{mask});
            return error.CheckFailed;
        }
        seen[idx] = true;
    }
    return ast.ShaderType.vecOf(mask.len) orelse unreachable;
}

fn promoteScalars(a: ast.ShaderType, b: ast.ShaderType) ?ast.ShaderType {
    if (a == b) return a;
    if (a == .float and (b == .int or b == .uint)) return .float;
    if (b == .float and (a == .int or a == .uint)) return .float;
    return null;
}

fn checkExpr(checker: *Checker, expr: *ast.ShaderExpr, stage: Stage) CheckError!ast.ShaderType {
    switch (expr.*) {
        .float_literal => return .float,
        .int_literal => return .int,
        .bool_literal => return .bool_,
        .ident => |name| return resolveReadable(checker, name, stage),
        .member_access => |member| {
            if (member.base.* == .ident and checker.groups.get(member.base.ident) != null) {
                const group = checker.groups.get(member.base.ident).?;
                for (group.fields) |field| {
                    if (std.mem.eql(u8, field.name, member.field)) return field.ty;
                }
                checker.fail("ShaderUnknownMember: @global struct `{s}` has no field `{s}`", .{ group.name, member.field });
                return error.CheckFailed;
            }
            const base_ty = try checkExpr(checker, member.base, stage);
            return checkSwizzle(checker, base_ty, member.field, false);
        },
        .sample => |sample| {
            const tex_ty = try checkExpr(checker, sample.tex, stage);
            if (tex_ty != .sampler2d) {
                checker.fail("ShaderSampleTarget: .get() samples a sampler2D, got {s}", .{tex_ty.name()});
                return error.CheckFailed;
            }
            const uv_ty = try checkExpr(checker, sample.uv, stage);
            if (uv_ty != .vec2) {
                checker.fail("ShaderSampleCoord: sampler2D coordinates must be vec2, got {s}", .{uv_ty.name()});
                return error.CheckFailed;
            }
            return .vec4;
        },
        .construct => |construct| return checkConstruct(checker, construct, stage),
        .call => |call| {
            checker.fail("ShaderUnknownCall: `{s}` is not a shader builtin in this subset", .{call.name});
            return error.CheckFailed;
        },
        .unary => |unary| {
            const inner = try checkExpr(checker, unary.expr, stage);
            switch (unary.op) {
                .neg => {
                    if (inner.isScalar() or inner.isVector() or inner.isMatrix()) return inner;
                    checker.fail("ShaderTypeMismatch: cannot negate {s}", .{inner.name()});
                    return error.CheckFailed;
                },
                .not => {
                    if (inner == .bool_) return .bool_;
                    checker.fail("ShaderTypeMismatch: logical not needs bool, got {s}", .{inner.name()});
                    return error.CheckFailed;
                },
            }
        },
        .binary => |binary| return checkBinary(checker, binary, stage),
    }
}

fn checkConstruct(checker: *Checker, construct: ast.ShaderConstruct, stage: Stage) CheckError!ast.ShaderType {
    var arg_tys = std.array_list.Managed(ast.ShaderType).init(checker.allocator);
    for (construct.args) |arg| {
        try arg_tys.append(try checkExpr(checker, arg, stage));
    }
    const target = construct.ty;
    if (target.isVector()) {
        var total: usize = 0;
        for (arg_tys.items) |arg_ty| {
            if (arg_ty.isScalar()) {
                total += 1;
            } else if (arg_ty.isVector()) {
                total += arg_ty.components();
            } else {
                checker.fail("ShaderConstructType: cannot build {s} from {s}", .{ target.name(), arg_ty.name() });
                return error.CheckFailed;
            }
        }
        // A single scalar argument splats; otherwise the component
        // counts must add up exactly.
        if (total == target.components() or (arg_tys.items.len == 1 and arg_tys.items[0].isScalar())) return target;
        checker.fail("ShaderConstructArity: {s} needs {} components, got {}", .{ target.name(), target.components(), total });
        return error.CheckFailed;
    }
    if (target.isMatrix()) {
        const order: usize = if (target == .mat3) 3 else 4;
        if (arg_tys.items.len == 1 and arg_tys.items[0].isScalar()) return target;
        if (arg_tys.items.len == 1 and arg_tys.items[0] == target) return target;
        var total: usize = 0;
        for (arg_tys.items) |arg_ty| {
            if (!arg_ty.isScalar()) {
                checker.fail("ShaderConstructType: cannot build {s} from {s}", .{ target.name(), arg_ty.name() });
                return error.CheckFailed;
            }
            total += 1;
        }
        if (total == order * order) return target;
        checker.fail("ShaderConstructArity: {s} needs {} scalar components, got {}", .{ target.name(), order * order, total });
        return error.CheckFailed;
    }
    if (target.isScalar()) {
        // Scalar construction is a cast: exactly one numeric scalar.
        if (arg_tys.items.len == 1 and arg_tys.items[0].isScalar()) return target;
        checker.fail("ShaderConstructArity: {s} construction takes one scalar argument", .{target.name()});
        return error.CheckFailed;
    }
    checker.fail("ShaderInvalidConstruct: {s} cannot be constructed", .{target.name()});
    return error.CheckFailed;
}

fn checkBinary(checker: *Checker, binary: ast.ShaderBinary, stage: Stage) CheckError!ast.ShaderType {
    const lhs = try checkExpr(checker, binary.lhs, stage);
    const rhs = try checkExpr(checker, binary.rhs, stage);
    switch (binary.op) {
        .and_, .or_ => {
            if (lhs == .bool_ and rhs == .bool_) return .bool_;
            checker.fail("ShaderTypeMismatch: logical operators need bool operands, got {s} and {s}", .{ lhs.name(), rhs.name() });
            return error.CheckFailed;
        },
        .eq, .ne => {
            if (lhs == rhs) return .bool_;
            if (lhs.isScalar() and rhs.isScalar() and promoteScalars(lhs, rhs) != null) return .bool_;
            checker.fail("ShaderTypeMismatch: cannot compare {s} with {s}", .{ lhs.name(), rhs.name() });
            return error.CheckFailed;
        },
        .lt, .le, .gt, .ge => {
            if (lhs.isScalar() and rhs.isScalar() and lhs != .bool_ and rhs != .bool_ and promoteScalars(lhs, rhs) != null) return .bool_;
            checker.fail("ShaderTypeMismatch: ordered comparison needs numeric scalars, got {s} and {s}", .{ lhs.name(), rhs.name() });
            return error.CheckFailed;
        },
        .mod => {
            if ((lhs == .int or lhs == .uint) and lhs == rhs) return lhs;
            checker.fail("ShaderTypeMismatch: % needs matching integer operands, got {s} and {s}", .{ lhs.name(), rhs.name() });
            return error.CheckFailed;
        },
        .add, .sub, .mul, .div => return checkArithmetic(checker, lhs, rhs),
    }
}

fn checkArithmetic(checker: *Checker, lhs: ast.ShaderType, rhs: ast.ShaderType) CheckError!ast.ShaderType {
    if (lhs.isScalar() and rhs.isScalar()) {
        if (promoteScalars(lhs, rhs)) |promoted| return promoted;
        checker.fail("ShaderTypeMismatch: cannot combine {s} with {s}", .{ lhs.name(), rhs.name() });
        return error.CheckFailed;
    }
    if (lhs.isVector() and rhs == .float) return lhs;
    if (rhs.isVector() and lhs == .float) return rhs;
    if (lhs.isVector() and rhs.isVector() and lhs == rhs) return lhs;
    if (lhs.isMatrix() and rhs == .float) return lhs;
    if (rhs.isMatrix() and lhs == .float) return rhs;
    if (lhs == .mat4 and rhs == .vec4) return .vec4;
    if (lhs == .vec4 and rhs == .mat4) return .vec4;
    if (lhs == .mat3 and rhs == .vec3) return .vec3;
    if (lhs == .vec3 and rhs == .mat3) return .vec3;
    if (lhs.isMatrix() and lhs == rhs) return lhs;
    checker.fail("ShaderDimensionMismatch: cannot combine {s} with {s}", .{ lhs.name(), rhs.name() });
    return error.CheckFailed;
}
