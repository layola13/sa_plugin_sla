const std = @import("std");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const monomorphizer_mod = @import("monomorphizer.zig");
const type_checker_mod = @import("type_checker.zig");
const codegen_mod = @import("codegen.zig");
const source_expand = @import("source_expand.zig");

pub const HandlerStateType = enum {
    i1,
    i32,
    i64,
    f64,
    ptr,
};

pub const HandlerStateField = struct {
    name: []const u8,
    ty: HandlerStateType,
    address: []const u8,
};

pub const HandlerAmbientBinding = struct {
    name: []const u8,
    ty: HandlerStateType,
};

pub const CompileHandlerOptions = struct {
    base_dir: []const u8 = ".",
    ambient_bindings: []const HandlerAmbientBinding = &.{},
};

pub const CompileHandlerError = error{
    InvalidHandlerOutput,
} || parser_mod.ParserError || monomorphizer_mod.MonomorphizeError || type_checker_mod.TypeError || codegen_mod.CodegenError || error{OutOfMemory};

pub const CompileHandlerResult = struct {
    body: []const u8,
    support: []const u8,

    pub fn deinit(self: CompileHandlerResult, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        allocator.free(self.support);
    }
};

fn makePrimitive(allocator: std.mem.Allocator, primitive: ast.Primitive) !*ast.Type {
    const ty = try allocator.create(ast.Type);
    ty.* = .{ .primitive = primitive };
    return ty;
}

fn makeHandlerType(allocator: std.mem.Allocator, ty: HandlerStateType) !*ast.Type {
    return switch (ty) {
        .i1 => try makePrimitive(allocator, .boolean),
        .i32 => try makePrimitive(allocator, .i32),
        .i64 => try makePrimitive(allocator, .i64),
        .f64 => try makePrimitive(allocator, .f64),
        .ptr => try makePrimitive(allocator, .void_type),
    };
}

fn handlerSymbolName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "sla__{s}", .{name});
}

fn lineMatchesFunctionHeader(line: []const u8, symbol_name: []const u8) bool {
    if (line.len < symbol_name.len + 2) return false;
    if (line[0] != '@') return false;
    if (!std.mem.startsWith(u8, line[1..], symbol_name)) return false;
    return line[1 + symbol_name.len] == '(';
}

fn isSlaFunctionHeaderLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "@sla__") and std.mem.indexOfScalar(u8, line, '(') != null;
}

fn isInjectedStateRelease(line: []const u8, state_fields: []const HandlerStateField) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, trimmed, "!")) return false;
    const name = std.mem.trim(u8, trimmed[1..], " \t\r");
    for (state_fields) |field| {
        if (std.mem.eql(u8, name, field.name)) return true;
    }
    return false;
}

fn filterSupportFunctions(allocator: std.mem.Allocator, raw_support: []const u8, state_fields: []const HandlerStateField) ![]const u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var lines = std.mem.splitScalar(u8, raw_support, '\n');
    var copying = false;
    while (lines.next()) |line| {
        if (isSlaFunctionHeaderLine(line)) {
            copying = true;
        } else if (copying and line.len != 0 and line[0] == '@') {
            copying = false;
        }

        if (copying) {
            if (isInjectedStateRelease(line, state_fields)) continue;
            try out.appendSlice(line);
            try out.append('\n');
        }
    }

    return try out.toOwnedSlice();
}

fn extractFunctionParts(allocator: std.mem.Allocator, sa_code: []const u8, handler_name: []const u8, state_fields: []const HandlerStateField) !CompileHandlerResult {
    const symbol_name = try handlerSymbolName(allocator, handler_name);
    defer allocator.free(symbol_name);

    var lines = std.mem.splitScalar(u8, sa_code, '\n');
    var found = false;
    var body = std.ArrayList(u8).init(allocator);
    errdefer body.deinit();
    var support = std.ArrayList(u8).init(allocator);
    errdefer support.deinit();

    while (lines.next()) |line| {
        if (!found) {
            if (lineMatchesFunctionHeader(line, symbol_name)) {
                found = true;
            } else {
                try support.appendSlice(line);
                try support.append('\n');
            }
            continue;
        }
        if (line.len != 0 and line[0] == '@') {
            try support.appendSlice(line);
            try support.append('\n');
            while (lines.next()) |rest| {
                try support.appendSlice(rest);
                try support.append('\n');
            }
            break;
        }
        try body.appendSlice(line);
        try body.append('\n');
    }

    if (!found or body.items.len == 0) return CompileHandlerError.InvalidHandlerOutput;
    const raw_support = try support.toOwnedSlice();
    defer allocator.free(raw_support);

    return .{
        .body = try body.toOwnedSlice(),
        .support = try filterSupportFunctions(allocator, raw_support, state_fields),
    };
}

fn extractFunctionBody(allocator: std.mem.Allocator, sa_code: []const u8, handler_name: []const u8) ![]const u8 {
    const parts = try extractFunctionParts(allocator, sa_code, handler_name, &.{});
    allocator.free(parts.support);
    return parts.body;
}

fn resolveImportPath(allocator: std.mem.Allocator, base_dir: []const u8, import_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(import_path)) return try allocator.dupe(u8, import_path);
    return try std.fs.path.join(allocator, &.{ base_dir, import_path });
}

fn appendExpandedSlaImportDecls(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    import_path: []const u8,
    visited: *std.StringHashMap(void),
    out_decls: *std.ArrayList(*ast.Node),
) !void {
    if (!std.mem.endsWith(u8, import_path, ".sla")) {
        const import_decl = try allocator.create(ast.Node);
        import_decl.* = .{ .import_decl = .{ .path = import_path } };
        try out_decls.append(import_decl);
        return;
    }

    const resolved_path = try resolveImportPath(allocator, base_dir, import_path);
    if (visited.contains(resolved_path)) return;
    try visited.put(resolved_path, {});

    const source = std.fs.cwd().readFileAlloc(allocator, resolved_path, 16 * 1024 * 1024) catch return CompileHandlerError.InvalidHandlerOutput;
    const expanded_source = source_expand.expand(allocator, source) catch return CompileHandlerError.InvalidHandlerOutput;
    const import_dir = std.fs.path.dirname(resolved_path) orelse base_dir;
    var p = parser_mod.Parser.initWithDir(allocator, expanded_source, import_dir);
    const imported_prog = p.parseProgram() catch return CompileHandlerError.InvalidHandlerOutput;
    if (imported_prog.* != .program) return error.InvalidHandlerOutput;

    for (imported_prog.program.decls) |decl| {
        if (decl.* == .import_decl) {
            try appendExpandedSlaImportDecls(allocator, import_dir, decl.import_decl.path, visited, out_decls);
        } else {
            try out_decls.append(decl);
        }
    }
}

fn expandSlaImports(allocator: std.mem.Allocator, program: *ast.Node, base_dir: []const u8) !*ast.Node {
    if (program.* != .program) return error.InvalidHandlerOutput;

    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();

    var decls = std.ArrayList(*ast.Node).init(allocator);
    for (program.program.decls) |decl| {
        if (decl.* == .import_decl) {
            try appendExpandedSlaImportDecls(allocator, base_dir, decl.import_decl.path, &visited, &decls);
        } else {
            try decls.append(decl);
        }
    }

    const expanded = try allocator.create(ast.Node);
    expanded.* = .{ .program = .{ .decls = try decls.toOwnedSlice() } };
    return expanded;
}

pub fn compileHandler(
    allocator: std.mem.Allocator,
    handler_name: []const u8,
    handler_source: []const u8,
    state_fields: []const HandlerStateField,
    options: CompileHandlerOptions,
) CompileHandlerError![]const u8 {
    const result = try compileHandlerWithSupport(allocator, handler_name, handler_source, state_fields, options);
    allocator.free(result.support);
    return result.body;
}

pub fn compileHandlerWithSupport(
    allocator: std.mem.Allocator,
    handler_name: []const u8,
    handler_source: []const u8,
    state_fields: []const HandlerStateField,
    options: CompileHandlerOptions,
) CompileHandlerError!CompileHandlerResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = try std.fmt.allocPrint(
        a,
        \\
        \\extern {{
        \\  fn render();
        \\  fn sax_get_time() -> i64;
        \\  fn sax_event_target_value_i64() -> i64;
        \\}}
        \\{s}
        \\
    , .{handler_source});

    const expanded_source = source_expand.expand(a, source) catch return CompileHandlerError.InvalidHandlerOutput;
    var p = parser_mod.Parser.initWithDir(a, expanded_source, options.base_dir);
    const parsed_prog = try p.parseProgram();
    const prog = try expandSlaImports(a, parsed_prog, options.base_dir);

    var mono = monomorphizer_mod.Monomorphizer.init(a);
    defer mono.deinit();
    const specialized_prog = try mono.monomorphize(prog, null, null);

    const scope_bindings = try a.alloc(type_checker_mod.InjectedScopeBinding, state_fields.len + options.ambient_bindings.len);
    const address_bindings = try a.alloc(codegen_mod.InjectedAddressBinding, state_fields.len);
    for (state_fields, 0..) |field, idx| {
        scope_bindings[idx] = .{
            .name = field.name,
            .ty = try makeHandlerType(a, field.ty),
            .is_const = false,
        };
        address_bindings[idx] = .{
            .name = field.name,
            .address = field.address,
        };
    }
    for (options.ambient_bindings, 0..) |binding, offset| {
        scope_bindings[state_fields.len + offset] = .{
            .name = binding.name,
            .ty = try makeHandlerType(a, binding.ty),
            .is_const = true,
        };
    }

    var tc = type_checker_mod.TypeChecker.initWithOptions(a, .{ .injected_scope_bindings = scope_bindings });
    defer tc.deinit();
    try tc.checkProgram(specialized_prog);

    var cg = codegen_mod.Codegen.initWithOptions(a, &tc, .{ .injected_address_bindings = address_bindings });
    defer cg.deinit();
    const sa_code = try cg.generate(specialized_prog);

    return try extractFunctionParts(allocator, sa_code, handler_name, state_fields);
}

test "compileHandler lowers injected state reads and writes" {
    const fields = [_]HandlerStateField{
        .{ .name = "count", .ty = .i64, .address = "state+Counter_count" },
    };
    const body = try compileHandler(
        std.testing.allocator,
        "inc",
        "fn inc() { count = count + 1; render(); }",
        fields[0..],
        .{},
    );
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "load state+Counter_count as i64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "store state+Counter_count"));
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "call @render()"));
}

test "compileHandler expands relative sla imports" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{
        .sub_path = "helpers.sla",
        .data =
            \\fn add_two(value: i64) -> i64 {
            \\    return value + 2;
            \\}
            \\
        ,
    });
    const base_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base_dir);

    const fields = [_]HandlerStateField{
        .{ .name = "count", .ty = .i64, .address = "state+Counter_count" },
    };
    const result = try compileHandlerWithSupport(
        std.testing.allocator,
        "inc",
        
        \\@import "helpers.sla"
        \\fn inc() {
        \\    count = add_two(count);
        \\    render();
        \\}
        ,
        fields[0..],
        .{ .base_dir = base_dir },
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "load state+Counter_count as i64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "call @sla__add_two"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "store state+Counter_count"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.support, 1, "@sla__add_two"));
}
