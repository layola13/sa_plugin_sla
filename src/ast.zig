const std = @import("std");

pub const Node = union(enum) {
    program: Program,

    // Declarations
    struct_decl: StructDecl,
    enum_decl: EnumDecl,
    trait_decl: TraitDecl,
    impl_decl: ImplDecl,
    type_alias_decl: TypeAliasDecl,
    overload_decl: OverloadDecl,
    func_decl: FuncDecl,
    macro_decl: MacroDecl,
    import_decl: ImportDecl,
    using_decl: UsingDecl,
    test_decl: TestDecl,
    sublanguage_decl: SublanguageDecl,
    sublanguage_registration: SublanguageRegistration,
    check_hook_decl: CheckHookDecl,

    // Statements
    let_stmt: LetStmt,
    let_else_stmt: LetElseStmt,
    let_destructure_stmt: LetDestructureStmt,
    const_stmt: ConstStmt,
    var_stmt: VarStmt,
    assign_stmt: AssignStmt,
    block_stmt: BlockStmt,
    expr_stmt: *Node,
    return_stmt: ReturnStmt,
    for_stmt: ForStmt,
    while_stmt: WhileStmt,
    break_stmt: BreakStmt,
    continue_stmt: ContinueStmt,
    release_stmt: ReleaseStmt,
    defer_stmt: DeferStmt,
    select_stmt: SelectStmt,

    // Expressions
    literal: Literal,
    identifier: []const u8,
    generic_func_ref: GenericFuncRef,
    go_expr: GoExpr,
    if_expr: IfExpr,
    switch_expr: SwitchExpr,
    match_expr: MatchExpr,
    unsafe_expr: UnsafeExpr,
    await_expr: AwaitExpr,
    inline_asm_expr: InlineAsmExpr,
    binary_expr: BinaryExpr,
    call_expr: CallExpr,
    closure_literal: ClosureLiteral,
    borrow_expr: BorrowExpr,
    move_expr: MoveExpr,
    deref_expr: DerefExpr,
    cast_expr: CastExpr,
    field_expr: FieldExpr,
    struct_literal: StructLiteral,
    enum_literal: EnumLiteral,
    tuple_literal: TupleLiteral,
    array_literal: ArrayLiteral,
    repeat_array_literal: RepeatArrayLiteral,
    index_expr: IndexExpr,
    slice_expr: SliceExpr,
    try_expr: TryExpr,
};

pub const Program = struct {
    decls: []const *Node,
};

pub const StructDecl = struct {
    name: []const u8,
    derives: []const []const u8 = &.{},
    generics: []const []const u8,
    fields: []const Field,
    is_union: bool = false,
    is_opaque: bool = false,
};

pub const EnumDecl = struct {
    name: []const u8,
    generics: []const []const u8,
    variants: []const EnumVariant,
};

pub const EnumVariant = struct {
    name: []const u8,
    fields: []const Field,
    /// Explicit discriminant from `Variant = N` (C/TS-like). Null means
    /// auto-increment (first variant 0, then previous + 1). Only allowed
    /// on fieldless variants; see `enumVariantValue` for resolution.
    discriminant: ?i64 = null,
};

pub const ImplDecl = struct {
    trait_name: ?[]const u8 = null,
    target_ty: *Type,
    methods: []const *Node,
};

pub const TypeAliasDecl = struct {
    name: []const u8,
    components: []const TypeAliasComponent,
};

pub const TypeAliasComponent = union(enum) {
    ty: *Type,
    inline_struct: []const Field,
};

pub const OverloadDecl = struct {
    target_ty: *Type,
    methods: []const *Node,
};

pub const TraitMethod = struct {
    name: []const u8,
    params: []const Param,
    ret_ty: *Type,
};

pub const TraitDecl = struct {
    name: []const u8,
    supertraits: []const []const u8 = &.{},
    methods: []const TraitMethod,
};

pub const Field = struct {
    name: []const u8,
    ty: *Type,
};

pub const FuncDecl = struct {
    name: []const u8,
    is_pub: bool = false,
    is_extern: bool = false,
    abi: ?[]const u8 = null,
    no_mangle: bool = false,
    is_decl_only: bool = false,
    generics: []const []const u8,
    params: []const Param,
    ret_ty: *Type,
    body: []const *Node,
    is_inline: bool,
    is_async: bool = false,
    operator: ?BinaryOp = null,
    /// Extern variadic batch: the parameter list ends with a trailing
    /// `...` marker. Only legal on extern declarations and on exported
    /// extern "C" definitions (whose final Param is the VaList binding).
    is_variadic: bool = false,
};

pub const Param = struct {
    name: []const u8,
    ty: *Type,
    is_borrow: bool = false,
    is_move: bool = false,
};

pub const MacroDecl = struct {
    name: []const u8,
    params: []const []const u8,
    body: []const *Node,
    /// J-3 (typed macro parameters, Jev slasl_macro_ruling j3 =
    /// typed_macro_params): optional declared type per parameter,
    /// parallel to `params`. Empty for declarations written without
    /// parameter types; a null entry leaves that parameter untyped
    /// (the pre-J-3 `.infer` behaviour).
    param_types: []const ?*Type = &.{},

    pub fn declaredParamType(self: *const MacroDecl, index: usize) ?*Type {
        if (index >= self.param_types.len) return null;
        return self.param_types[index];
    }
};

pub const ImportDecl = struct {
    path: []const u8,
};

pub const UsingDecl = struct {
    path: []const u8,
};

/// J-1 (declaration sublanguage registration, Jev slasl_macro_ruling
/// j1 = declaration_sublanguage_registration): `@sublanguage <kind>;`
/// opts the file into a registered declaration kind. The kind's own
/// sub-parser produces typed declarations (SublanguageDecl) that
/// enter the shared checker/lowering. Registration is load-bearing:
/// without it, a sublanguage declaration is not recognised at all.
pub const SublanguageRegistration = struct {
    kind: []const u8,
};

pub const SublanguageDecl = struct {
    kind: []const u8,
    name: []const u8,
    payload: SublanguagePayload,
};

pub const SublanguagePayload = union(enum) {
    shader: ShaderDecl,
};

/// SLASL shader declaration (the J-1 motivating kind). The schema
/// follows the SLASL design (DESIGN.md section 6.1): a typed,
/// serialisable declaration consumed by the shared checker; target
/// emission is ordinary library code (J-7), not part of the compiler.
pub const ShaderDecl = struct {
    name: []const u8,
    priority: ?i64 = null,
    globals: []const ShaderGlobalGroup = &.{},
    inputs: []const ShaderField = &.{},
    params: []const ShaderField = &.{},
    consts: []const ShaderConst = &.{},
    vars: []const ShaderField = &.{},
    init: []const *ShaderStmt = &.{},
    vertex: []const *ShaderStmt = &.{},
    fragment: []const *ShaderStmt = &.{},
};

pub const ShaderGlobalGroup = struct {
    name: []const u8,
    fields: []const ShaderField,
};

pub const ShaderField = struct {
    name: []const u8,
    ty: ShaderType,
};

pub const ShaderConst = struct {
    name: []const u8,
    ty: ShaderType,
    value: ShaderLiteral,
};

pub const ShaderLiteral = union(enum) {
    float: f64,
    int: i64,
    boolean: bool,
};

pub const ShaderType = enum {
    float,
    int,
    uint,
    bool_,
    vec2,
    vec3,
    vec4,
    mat3,
    mat4,
    sampler2d,

    pub fn name(self: ShaderType) []const u8 {
        return switch (self) {
            .float => "f32",
            .int => "i32",
            .uint => "u32",
            .bool_ => "bool",
            .vec2 => "vec2",
            .vec3 => "vec3",
            .vec4 => "vec4",
            .mat3 => "mat3",
            .mat4 => "mat4",
            .sampler2d => "sampler2D",
        };
    }

    /// Component count for vectors, 1 for scalars, 0 for
    /// matrix/sampler/bool (not component-addressable here).
    pub fn components(self: ShaderType) usize {
        return switch (self) {
            .float, .int, .uint => 1,
            .vec2 => 2,
            .vec3 => 3,
            .vec4 => 4,
            else => 0,
        };
    }

    pub fn isScalar(self: ShaderType) bool {
        return self == .float or self == .int or self == .uint;
    }

    pub fn isVector(self: ShaderType) bool {
        return self == .vec2 or self == .vec3 or self == .vec4;
    }

    pub fn isMatrix(self: ShaderType) bool {
        return self == .mat3 or self == .mat4;
    }

    pub fn vecOf(count: usize) ?ShaderType {
        return switch (count) {
            1 => .float,
            2 => .vec2,
            3 => .vec3,
            4 => .vec4,
            else => null,
        };
    }
};

pub const ShaderStmt = union(enum) {
    assign: ShaderAssign,
    if_stmt: ShaderIf,
};

pub const ShaderAssign = struct {
    target: *ShaderExpr,
    value: *ShaderExpr,
};

pub const ShaderIf = struct {
    cond: *ShaderExpr,
    body: []const *ShaderStmt,
};

pub const ShaderExpr = union(enum) {
    float_literal: f64,
    int_literal: i64,
    bool_literal: bool,
    ident: []const u8,
    /// `base.field`: resolved by the checker — a qualified global
    /// group access when `base` names a @global group, otherwise a
    /// swizzle when `base` has a vector type (DESIGN 6.1 lists both
    /// as AST nodes; the classification needs declaration context,
    /// so it happens in the checker).
    member_access: ShaderMemberAccess,
    binary: ShaderBinary,
    unary: ShaderUnary,
    construct: ShaderConstruct,
    sample: ShaderSample,
    call: ShaderCall,
};

pub const ShaderMemberAccess = struct {
    base: *ShaderExpr,
    field: []const u8,
};

pub const ShaderBinary = struct {
    op: ShaderBinOp,
    lhs: *ShaderExpr,
    rhs: *ShaderExpr,
};

pub const ShaderUnary = struct {
    op: ShaderUnOp,
    expr: *ShaderExpr,
};

pub const ShaderConstruct = struct {
    ty: ShaderType,
    args: []const *ShaderExpr,
};

pub const ShaderSample = struct {
    tex: *ShaderExpr,
    uv: *ShaderExpr,
};

pub const ShaderCall = struct {
    name: []const u8,
    args: []const *ShaderExpr,
};

pub const ShaderBinOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    and_,
    or_,
};

pub const ShaderUnOp = enum {
    neg,
    not,
};

/// J-5 (independent check hooks, Jev slasl_macro_ruling j5 =
/// independent_check_hooks): `@check_hook <name>;` attaches a named
/// read-only checker hook to the file. The hook receives the typed
/// AST and may only emit named diagnostics; it cannot transform.
pub const CheckHookDecl = struct {
    name: []const u8,
};

pub const TestDecl = struct {
    name: []const u8,
    is_ignored: bool,
    should_panic: bool,
    body: []const *Node,
};

pub const LetStmt = struct {
    name: []const u8,
    ty: ?*Type,
    value: *Node,
};

pub const LetElseStmt = struct {
    pattern: EnumPattern,
    value: *Node,
    else_block: []const *Node,
};

pub const LetDestructureStmt = struct {
    names: []const []const u8,
    value: *Node,
    rest_name: ?[]const u8 = null,
    rest_alias: ?[]const u8 = null,
    is_slice: bool = false,
};

pub const ConstStmt = struct {
    name: []const u8,
    ty: ?*Type,
    value: *Node,
};

pub const VarStmt = struct {
    name: []const u8,
    ty: *Type,
};

pub const AssignStmt = struct {
    target: *Node,
    value: *Node,
};

pub const BlockStmt = struct {
    body: []const *Node,
};

pub const ReturnStmt = struct {
    value: ?*Node,
};

pub const ForStmt = struct {
    var_name: []const u8,
    start: *Node,
    end: ?*Node,
    body: []const *Node,
};

pub const WhileStmt = struct {
    cond: *Node,
    let_pattern: ?EnumPattern = null,
    body: []const *Node,
};

pub const BreakStmt = struct {};

pub const ContinueStmt = struct {};

pub const ReleaseStmt = struct {
    var_name: []const u8,
};

/// `go f(args)` / `go supervised f(args)` — goroutine spawn expression.
/// The operand is always a call expression (parser-enforced); the whole
/// node evaluates to the u64 goroutine handle.
pub const GoExpr = struct {
    supervised: bool = false,
    call: *Node,
};

/// `defer <call>;` — scope-exit deferred call (desugared pre-check).
pub const DeferStmt = struct {
    call: *Node,
};

pub const SelectCase = struct {
    kind: enum { recv, send },
    /// The full method-call node (`ch.recv()` / `ch.send(v)`); the
    /// channel expression is its args[0].
    call: *Node,
    bind_name: ?[]const u8 = null,
    bind_closed: ?[]const u8 = null,
    body: []const *Node,
};

/// `select { case ... { } default { } timeout(e) { } }` — statement.
pub const SelectStmt = struct {
    cases: []const SelectCase,
    default_body: ?[]const *Node = null,
    timeout_expr: ?*Node = null,
    timeout_body: ?[]const *Node = null,
};

pub const Literal = union(enum) {
    int_val: i64,
    float_val: f64,
    bool_val: bool,
    string_val: []const u8,
};

pub const IfExpr = struct {
    cond: *Node,
    let_chain: ?[]const IfLetCond = null,
    then_block: []const *Node,
    else_block: ?[]const *Node,
};

pub const IfLetCond = struct {
    pattern: EnumPattern,
    value: *Node,
};

pub const Case = struct {
    pattern: *Node, // Literal or Identifier (for default pattern, e.g. "default")
    body: []const *Node,
};

pub const SwitchExpr = struct {
    val: *Node,
    cases: []const Case,
};

pub const MatchExpr = struct {
    val: *Node,
    cases: []const MatchCase,
};

pub const UnsafeExpr = struct {
    body: []const *Node,
};

pub const MatchCase = struct {
    pattern: EnumPattern,
    guard: ?*Node = null,
    body: []const *Node,
};

pub const AwaitExpr = struct {
    expr: *Node,
};

pub const InlineAsmOperand = struct {
    constraint: []const u8,
    var_name: []const u8,
};

pub const InlineAsmExpr = struct {
    template: []const u8,
    operands: []const InlineAsmOperand,
};

pub const ClosureLiteral = struct {
    params: []const Param,
    body: *Node,
};

pub const EnumPattern = struct {
    enum_name: []const u8,
    variant_name: []const u8,
    bindings: []const []const u8,
};

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    spaceship,
    logical_and,
    logical_or,
};

pub const BinaryExpr = struct {
    op: BinaryOp,
    left: *Node,
    right: *Node,
};

pub const CallExpr = struct {
    func_name: []const u8,
    associated_target: ?[]const u8 = null,
    generics: []const *Type,
    args: []const *Node,
    /// #13: immediately-invoked closure literal callee (`(|x| ...)(args)`).
    /// Null for every ordinary named call; when set, `func_name` is "" and
    /// all name-keyed dispatch must be bypassed in favor of this node.
    callee: ?*Node = null,
};

pub const GenericFuncRef = struct {
    func_name: []const u8,
    generics: []const *Type,
};

pub const BorrowExpr = struct {
    expr: *Node,
};

pub const MoveExpr = struct {
    expr: *Node,
};

pub const DerefExpr = struct {
    expr: *Node,
};

pub const CastExpr = struct {
    expr: *Node,
    ty: *Type,
};

pub const FieldExpr = struct {
    expr: *Node,
    field_name: []const u8,
};

pub const StructLiteralField = struct {
    name: []const u8,
    value: *Node,
};

pub const StructLiteral = struct {
    ty: *Type,
    fields: []const StructLiteralField,
    update_expr: ?*Node = null,
};

pub const EnumLiteralField = struct {
    name: []const u8,
    value: *Node,
};

pub const EnumLiteral = struct {
    enum_name: []const u8,
    variant_name: []const u8,
    fields: []const EnumLiteralField,
};

pub const TupleLiteral = struct {
    elements: []const *Node,
};

pub const ArrayLiteral = struct {
    elements: []const *Node,
};

pub const RepeatArrayLiteral = struct {
    value: *Node,
    len: usize,
};

pub const IndexExpr = struct {
    target: *Node,
    index: *Node,
};

pub const SliceExpr = struct {
    target: *Node,
    start: *Node,
    end: *Node,
};

pub const TryExpr = struct {
    expr: *Node,
};

// Type System representation
pub const Type = union(enum) {
    infer,
    primitive: Primitive,
    pointer: *Type,
    borrow: *Type,
    array: ArrayType,
    tuple: TupleType,
    future: *Type,
    closure: ClosureType,
    fn_ptr: FnPtrType,
    user_defined: UserDefined,
};

pub const Primitive = enum {
    // Integer primitives
    i8,
    i16,
    i32,
    i64,
    isize,
    u8,
    u16,
    u32,
    u64,
    usize,
    // Floating-point primitives
    f32,
    f64,
    // Legacy aliases kept during migration.
    integer,
    float,
    boolean,
    raw_ptr,
    void_type,
    /// C va_list handle. Only valid as the trailing parameter type of an
    /// exported extern "C" variadic definition (spelled `...` or `VaList`).
    va_list,
};

pub const UserDefined = struct {
    name: []const u8,
    generics: []const *Type,
};

pub const ArrayType = struct {
    elem: *Type,
    len: usize,
};

pub const TupleType = struct {
    elems: []const *Type,
};

pub const ClosureType = struct {
    params: []const *Type,
    ret: *Type,
};

pub const FnPtrType = struct {
    abi: ?[]const u8 = null,
    params: []const *Type,
    ret: *Type,
    /// Extern variadic batch: trailing `...` in the parameter list; only
    /// legal when `abi` names the C ABI.
    is_variadic: bool = false,
};
