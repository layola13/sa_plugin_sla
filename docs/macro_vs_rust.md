# Sla Macros vs Rust Macros: Compatibility and Conversion Assessment

> This is the English counterpart of the Chinese document [Sla 宏 vs Rust 宏：兼容性与转换评估](./macro_vs_rust_cn.md).

> **Document version**: v0.1-draft / 2026-06-15
> **Status**: Assessment report + improvement recommendations
> **Goal**: Honestly assess the capability gap between the two macro systems and provide feasible solutions for Bevy porting scenarios
> **Related documents**:
> - [`sla_language_specification_cn.md`](./sla_language_specification_cn.md) Sla language specification
> - `sci/docs/faq.md` SA philosophy boundaries
> - [`sa_plugins/sa_plugin_3dengines/docs/sla_migration_stepbystep_cn.md`](../../sa_plugin_3dengines/docs/sla_migration_stepbystep_cn.md) concrete Bevy refactoring steps

> **2026-06-23 architecture correction**: The suggestion in this document's early draft to hard-code ECS derives such as `Component` / `Resource` / `Event` / `Bundle` into the Sla compiler is void. `sa_plugin_sla` must remain language-agnostic; ECS/Bevy semantics belong to the `sla_ecs` library, project-level macros, generators, or future general derive/macro extension points. The compiler may add language capabilities such as `@expand_tuple`, general attribute parsing, and general value-semantics derives, but it must not contain engine keywords or game logic.

---

## 1. The Actual Structure of the Two Macro Systems

### 1.1 Sla's Current Macros (Tested from `parser.zig` + `ast.zig` + `codegen.zig`)

**Syntax** (from the spec + testing):

```sla
macro swap(a, b) {
    let temp = ^a;
    a = ^b;
    b = ^temp;
}
```

**AST structure** (`ast.zig:116`):

```zig
pub const MacroDecl = struct {
    name: []const u8,
    params: []const []const u8,    // 仅 identifier 数组，无类型/无 pattern
    body: []const *Node,
};
```

**Parser implementation** (`parser.zig:581-610`):

- The `macro` keyword + an identifier name
- Parameter list: only `identifier (, identifier)*`, with no type annotations
- Function body: a standard Sla block

**Codegen implementation** (`codegen.zig:90-92, 2313-2330`):

- Clear the local map upon entering a macro definition
- α-conversion: rename locals inside the macro to `<macro_name>_<local_name>_uniq_<N>`
- Lower to SA's `[MACRO] name %a, %b ... [END_MACRO]` + `EXPAND name x, y` at the call site

**Feature set**:

| Feature | Status |
|---------|--------|
| Function-like call syntax `swap(a, b)` | ✅ |
| Arguments = pure identifiers | ✅ (no type annotations, no patterns) |
| Hygienic macros (automatic α-conversion) | ✅ codegen renames using `<macro>_<local>_uniq_<N>` |
| Single arm (no multi-pattern support) | — Not supported |
| Pattern matching / fragment specifiers | ❌ |
| Variadic arguments (repetition) | ❌ |
| Attribute macros / derive macros | ❌ |
| Procedural macros / TokenStream API | ❌ |
| Type context | ❌ (only text-level identifier substitution) |
| Multiple call-syntax forms | ❌ (only `name(args)`) |
| Recursive macros | Not explicitly tested |

**Underlying mapping**: Sla `macro` → SA `[MACRO]` / `EXPAND` text macro lowers 1:1. Hygiene is handled by frontend α-conversion; the underlying SA remains non-hygienic text substitution.

### 1.2 Rust Macros (Two Independent Systems)

**System A: `macro_rules!` declarative macros**

```rust
macro_rules! swap {
    ($a:expr, $b:expr) => {
        let temp = $a;
        $a = $b;
        $b = temp;
    };
    // 可多个 arm
    ($a:ident; $b:ident) => { ... };
}
```

Feature set:
- Multiple arms + pattern matching
- **Fragment specifiers**: `expr` / `ty` / `ident` / `pat` / `stmt` / `tt` / `path` / `meta` / `lifetime` / `vis` / `literal` / `block` / `item`
- **Variadic repetition**: `$($x:expr),*` / `$($x),+`
- Partial hygiene (with known holes)
- Type-context aware (`$x:ty` actually matches a type)

**System B: Procedural Macros**

```rust
#[derive(Component)]
struct Position { x: f32, y: f32, z: f32 }

#[my_attribute(some_arg)]
fn foo() { ... }

let v = my_macro!(arbitrary tokens);
```

Three forms:
- Function-like: `my_macro!(...)`
- Derive: `#[derive(MyTrait)]`
- Attribute: `#[my_attr]`

Implementation mechanism: a **separate `proc-macro = true` crate** that takes `TokenStream` input, returns `TokenStream` output, and manipulates them with **arbitrary Rust code** (syn / quote are the de facto standard libraries).

---

## 2. Capability Comparison Matrix

| Capability | Sla `macro` | Rust `macro_rules!` | Rust proc-macro |
|------------|-------------|---------------------|-----------------|
| Call form `name(args)` | ✅ | ✅ (`name!()`) | ✅ (`name!()`) |
| Call form `#[derive(X)]` | ❌ | ❌ | ✅ |
| Call form `#[attr]` | ❌ | ❌ | ✅ |
| Argument is an identifier | ✅ | ✅ (`:ident`) | ✅ |
| Argument is an expression | ❌ (identifier substitution only) | ✅ (`:expr`) | ✅ |
| Argument is a type | ❌ | ✅ (`:ty`) | ✅ |
| Argument is a token tree | ❌ | ✅ (`:tt`) | ✅ |
| Variadic arguments | ❌ | ✅ (`$()*`) | ✅ |
| Multi-arm pattern matching | ❌ | ✅ | ✅ (hand-written matching) |
| Automatic hygiene | ✅ | ✅ (partial) | Manual span control |
| Generate `impl` blocks | Indirect (write impl in the macro body) | ✅ | ✅ |
| Parse struct fields and generate trait impls | ❌ | Difficult | ✅ (core use case) |
| Compile-time type reflection | ❌ | ❌ | ✅ (limited) |
| Cross-crate visibility | ✅ (import) | ✅ | ✅ (standalone crate) |
| Philosophy aligns with SA | ✅ | ⚠️ | ❌ (violates "zero AST") |

---

## 3. Conversion Difficulty Classification

### ✅ Easy (Sla Can Already Cover Directly)

| Rust pattern | Sla equivalent |
|--------------|----------------|
| `macro_rules! swap { ($a:ident, $b:ident) => { ... } }`, single arm with pure identifiers | `macro swap(a, b) { ... }` corresponds directly |
| `macro_rules! debug { () => { ... } }`, no-argument marker | `macro debug() { ... }` |
| Simple text expansion (no type context) | Direct conversion |

**Estimated coverage**: purely declarative simple macros account for about **20-30%** of Rust projects.

### ⚠️ Medium (Manual Rewriting Feasible)

| Rust pattern | Sla handling |
|--------------|--------------|
| `macro_rules! foo { ($x:expr) => { ... } }` taking an expr | Rewrite: the caller first does `let tmp = expr;` then calls `foo(tmp)` passing an identifier |
| `macro_rules! foo { ($t:ty) => { ... } }` taking a type | Rewrite: call manually once per concrete type, or replace with Sla generics |
| Multiple arms dispatching by type | Rewrite: split into several differently named macros, or use traits in Sla |
| `macro_rules! init_field { ($f:ident: $t:ty = $v:expr) => { ... } }` | Rewrite: split into several identifier arguments + have the caller evaluate first |
| Simple variadic `[$($x),+]` list initialization | Rewrite: expand N times manually or use an array literal |

**Estimate**: the portion of Rust projects that can be manually rewritten is about **30-40%**.

### 🔴 Hard (Requires Sla Compiler Extensions)

| Rust pattern | Why it is hard |
|--------------|----------------|
| `#[derive(Debug)]` / `#[derive(Clone)]` | Requires reading struct field metadata to generate methods; Sla macros have no such capability |
| **`#[derive(Component)]`, the core of Bevy ECS** | Same as above, plus registering component id / layout / vtable |
| `#[derive(Serialize, Deserialize)]` Serde | Requires recursively traversing types |
| `#[derive(Bundle)]` | Requires expansion into batch-insert logic for multiple Components |
| `#[command]` / `#[get("/api")]` attribute macros | Requires an attribute macro system that Sla does not support at all |
| `macro_rules! impl_for_tuples { (1 2 3 4 5 6 7 8) => { ... } }` tuple implementations | Requires recursion + type arguments |
| Any proc macro depending on `syn` / `quote` | Requires Sla to provide a TokenStream API (conflicts with SA philosophy) |

**Estimate**: about **30-50%** of Rust projects **require Sla compiler extensions to convert**.

### ❌ Impossible (Rejected at the Design Level)

| Rust pattern | Why |
|--------------|-----|
| Arbitrary Rust code as a proc macro implementation | Violates SA's "zero AST, zero implicit logic" philosophy |
| Arbitrary compile-time computation (const eval) | Already rejected by SA |
| Rewriting another crate's AST across crates | The SA pkg model is zero-trust and forbids this |

---

## 4. Concrete Impact on Bevy Porting Scenarios

### 4.1 What Macros Bevy Actually Uses (Tested on `bevy_ecs`)

| Bevy macro | Type | Directly supported by Sla? |
|------------|------|----------------------------|
| `#[derive(Component)]` | proc derive | ❌ |
| `#[derive(Bundle)]` | proc derive | ❌ |
| `#[derive(Resource)]` | proc derive | ❌ |
| `#[derive(States)]` | proc derive | ❌ |
| `#[derive(Event)]` | proc derive | ❌ |
| `#[derive(SystemParam)]` | proc derive | ❌ |
| `world.spawn((Pos, Vel))` | Ordinary function | ✅ |
| `Query<&Pos, With<Cam>>` | Ordinary generics | ✅ (if Sla generics are strong enough) |
| `bevy::prelude::*` | Import only | ✅ |

**Conclusion**: **90%+ of Bevy ECS's conciseness comes from derive macros**. Sla scores zero in this cell.

### 4.2 What ECS Without Derives Looks Like

**Original Rust** (4 lines):

```rust
#[derive(Component)]
struct Position { x: f32, y: f32, z: f32 }
```

**Sla version without macros** (15-20 lines):

```sla
struct Position { x: f32, y: f32, z: f32 }

const COMPONENT_ID_POSITION: u32 = 1;
const COMPONENT_SIZE_POSITION: u64 = 12;
const COMPONENT_ALIGN_POSITION: u64 = 4;

impl Component for Position {
    fn component_id() -> u32 { return COMPONENT_ID_POSITION; }
    fn size() -> u64 { return COMPONENT_SIZE_POSITION; }
    fn align() -> u64 { return COMPONENT_ALIGN_POSITION; }
    fn write_to(self: &Position, dst: ptr) {
        store dst+0, self.x as f32;
        store dst+4, self.y as f32;
        store dst+8, self.z as f32;
    }
    fn read_from(src: ptr) -> Position {
        return Position {
            x: load src+0 as f32,
            y: load src+4 as f32,
            z: load src+8 as f32
        };
    }
}
```

50 Components in a game = **750-1000 lines of boilerplate**. This is an unacceptable developer experience; **the biggest bottleneck in ECS porting is not Sla itself, but the absence of derive macros**.

---

## 5. Three Solutions (in Recommended ROI Order)

### ⭐⭐⭐⭐⭐ Path 1 (Recommended): Sla Compiler Built-in `@derive(...)` Annotation

**Idea**: instead of letting users write derive macros (which violates SA philosophy), have the Sla compiler **build in a small set of `@derive` keywords** and automatically generate impls during the AST rewriting stage.

```sla
@derive(Component)
struct Position { x: f32, y: f32, z: f32 }
```

When the Sla compiler sees `@derive(Component)`:
1. Read struct fields → compute size / align / layout
2. Automatically generate `impl Component for Position { ... }`
3. Register the component id table

**Built-in allowlist** (only these in v0.1):
- `@derive(Component)`
- `@derive(Bundle)`
- `@derive(Resource)`
- `@derive(Event)`
- `@derive(Copy)` (trivially copyable)
- `@derive(Default)` (all-zero init)

**Key constraints**:
- It is **special compiler syntax**, not a user-writable macro
- User-defined forms such as `@derive(MyCustomTrait)` are not accepted
- The Sla compiler hard-codes the expansion logic for each derive internally
- **Not interoperable** with Rust proc-macros, but **just as concise to write**

**Effort**: ~200-300 lines of Zig per derive's expansion logic, ~2-3 weeks for 6 derives.

**ROI**: unlocks 90% of the Bevy-style programming experience. **This is the decisive investment for whether ECS can be used**.

### ⭐⭐ Path 2: Conversion Tool `sa migrate rust-macro`

Provide a semi-automatic Rust → Sla macro converter:

```bash
sa migrate rust-macro src/lib.rs --out lib.sla
```

Tool capabilities:
- Recognize simple single-arm `macro_rules!` → convert to Sla `macro`
- Recognize `#[derive(Whitelist)]` → convert to Sla `@derive(...)` (requires Path 1 first)
- Anything that cannot be converted → write to `MIGRATION_TODO.md`, requiring manual rewriting

**Scope**: combining the "easy" and "medium" tiers, the tool can cover **50-70%** of Rust macros.

**Effort**: 3-4 weeks (write the converter + test coverage matrix).

**ROI**: speeds up "reference Rust code → write the Sla equivalent" by 3-5×.

### ⭐⭐ Path 3: Upgrade Sla `macro` to `macro_rules!` Equivalence

Make Sla macros support:
- Multiple arms
- Fragment specifiers (`:expr` / `:ty` / `:ident`)
- Variadic repetition (`$()*`)
- token-tree matching

**Problems**:
- Requires introducing a full macro pattern sublanguage into Sla (thousands of lines of parser + matcher)
- Conflicts with the positioning of "Sla as SA's LLM-friendly high-level frontend" (patterns are hard to learn)
- Still does not solve the `#[derive]` problem (that is an attribute macro)
- Conflicts with Sla's "12 keywords" minimalism philosophy (`macro_rules!` brings its own vocabulary)

**ROI**: extremely low. Not recommended.

### ❌ Path 4 (Do Not Do): proc macro Support

Let Sla accept arbitrary Sla code as a macro implementation, executed at compile time.

**Why not**:
- Violates SA's "zero implicit" philosophy
- Makes the build process non-reproducible (macro behavior depends on the host machine)
- Collapses the security model (a macro running arbitrary code = arbitrary syscalls)
- Conflicts with SA pkg's "zero permissions by default"

---

## 6. Combined Strategy: The Actually Feasible Path

### 6.1 Three-Stage Progression

| Stage | What to do | Weeks |
|-------|------------|-------|
| **Stage A** | Add the two simplest derives, `@derive(Copy)` / `@derive(Default)`, to the Sla compiler | 1 week |
| **Stage B** | Add `@derive(Component)` / `@derive(Bundle)` / `@derive(Resource)` to the Sla compiler — the ECS trio | 2-3 weeks |
| **Stage C** | Conversion tool `sa migrate rust-macro` — semi-automatic Rust → Sla | 3-4 weeks |

**After completion**: Bevy-style ECS programs in Sla are roughly as concise as in Rust. It can support a real game progressing from a rotating cube → multi-entity → dozens of Components.

### 6.2 What Not to Do

| Not doing | Explanation |
|-----------|-------------|
| `#[derive(Serialize)]` Serde | Adding built-in `@derive(Json)` support to Sla is enough; no Serde compatibility introduced |
| `#[derive(Debug)]` | Adding a built-in `@debug_print` function to Sla is enough |
| Arbitrary user-defined derives | No opening for these; write an impl by hand if special behavior is needed |
| Attribute macros `#[get("/api")]` | Use an ordinary builder pattern for http routing: `router.get("/api", handler)` |
| Arbitrary proc-macros | Never |

---

## 7. Quick Reference: Rust Macro → Sla Conversion Difficulty

| Rust syntax | Sla equivalent | Difficulty |
|-------------|----------------|------------|
| `macro_rules! one_arm { ($x:ident) => { ... } }` | `macro one_arm(x) { ... }` | ⭐ |
| `macro_rules! foo { ($x:expr) => { ... } }` | Caller first does `let t = expr;` then `foo(t)` | ⭐⭐ |
| `macro_rules! foo { ($($x:expr),*) => { ... } }` | Switch to an array `[a, b, c]` or a loop | ⭐⭐⭐ |
| `println!("x = {}", x)` | `println("x = ", x)` or sa_std fmt (**no `!` introduced**) | ⭐⭐ |
| `vec![1, 2, 3]` | `[1, 2, 3]` array literal | ⭐ |
| `#[derive(Debug)]` | Sla built-in `@derive(Debug)` | ⭐⭐ (requires Path 1) |
| `#[derive(Component)]` | Sla built-in `@derive(Component)` | ⭐⭐ (requires Path 1) |
| `#[derive(Serialize)]` | Hand-written `to_json` method | ⭐⭐⭐⭐ |
| `#[tokio::main]` | Not convertible; rewrite | ⭐⭐⭐⭐⭐ |
| Any `proc-macro` crate | Not convertible | Never |
| `quote! { ... }` metaprogramming | Not convertible | Never |

---

## 8. Final Recommendations for Bevy Porting Scenarios

**50% of Bevy's conciseness comes from proc-macro derives**. Sla will never support proc-macros, but it **can** rely on a small number of compiler built-in `@derive`s to support 80%.

**Priorities**:
1. **Immediately assess** the effort of adding `@derive(Component)` / `@derive(Bundle)` / `@derive(Resource)` to the Sla compiler
2. If it can be done in ≤ 3 weeks → **strongly recommended**, it is the only feasible path for Bevy porting
3. If > 3 weeks → evaluate whether it is worthwhile; hand-written impls + a code generation script (`sa3d_codegen.py`) can be used as a stopgap

**Things not to do**:
1. ❌ Do not add the `macro_rules!` pattern sublanguage to Sla
2. ❌ Do not attempt proc-macros
3. ❌ Do not try to translate all of Bevy's macros verbatim (`bevy_reflect` in particular is extremely complex)
4. ❌ Do not create derives for Serde compatibility; use sa_std JSON

---

## 9. Coordination with the Existing Sla Roadmap

### 9.1 Parts Affecting `sla_language_specification_cn.md`

Chapters 10-11 of the current specification, "Sla Hygienic Macro Design", already describe the existing macro form. Recommended additions:

- Chapter X: "`@derive(...)` compiler built-in annotations" — explicitly stating that these are not user macros, but special compiler syntax
- Keep the keyword list at 12 (`@derive` is an `@`-prefixed annotation and adds no keyword)
- Add an appendix listing the 6-derive allowlist supported in v0.1

### 9.2 Parts Affecting [sla_migration_stepbystep_cn.md](../../sa_plugin_3dengines/docs/sla_migration_stepbystep_cn.md)

Phase 0's "Sla compiler probe list" should add `@derive`:

```
Probe 8: 编译器内建 @derive
@derive(Copy)
struct V3 { x: f32, y: f32, z: f32 }
fn use_it() {
    let a = V3 { x: 1.0, y: 2.0, z: 3.0 };
    let b = a;   // Copy semantics, no move
}
```

Only after passing this Probe can the ECS stage (Phase 6A) begin.

### 9.3 Parts Affecting `sa_plugin_pkg/docs/sla_pkg_lang_field_cn.md`

The audit pipeline for `lang = sla` packages needs to recognize `@derive(...)`:

- The audit should not count derive-generated trait impls toward user code size
- Audit reports should distinguish "user-written" vs "derive-expanded" code
- When back-mapping via source maps, errors inside a trait impl should map back to the `@derive` line number

---

## 10. One-Sentence Final Conclusion

**Sla's current `macro` is a "hygienic function-like identifier macro"**, essentially equivalent to the simplest single-arm subset of Rust's `macro_rules!` (about 20-30% coverage). In addition, the compiler provides a limited source-level arity expansion entry point, `@expand_tuple(min, max, T) { ... }`, for generating fixed-range tuple/arity declarations. **Rust's derive macros and proc-macros will never have a user-writable equivalent in Sla** — this is a hard constraint of SA philosophy.

`@expand_tuple` supports a narrow set of template capabilities: `$N` denotes the current arity, `$TYPES` / `$TYPE_PARAMS` denote `T0, T1, ...`, `$I` / `$T` denote the index and type name of the current `@each` or `@join` item, `$ORD` denotes ordinal field names such as `first`, `second`, `third`, `@each(T) { ... }` repeats a template block by arity, and `@join(T, ", ") { ... }` joins template blocks with a separator. It suits batch generation of `AnyOf2..AnyOfN`, tuple impls, combinator structs, and structurally identical functions as in Bevy/Sla ECS; it does not support token-tree matching, multi-arm patterns, recursive macros, or arbitrary compile-time code execution.

**The realistic path for Bevy porting**: rely on **general Sla macro/expansion/derive infrastructure + `sla_ecs` project-level generation rules** to support the conciseness of ECS / Bundle / Resource / Event. The compiler can only provide language-neutral capabilities such as `@expand_tuple`, general attribute retention, value-semantics `@derive(copy, eq, ord, hash, debug)`, future hygienic macros, or a general source generator; names and semantics such as `Component`, `Resource`, `Event`, and `Relationship` must remain in `sla_ecs`.

**Effort**: prioritize expanding general macro/expansion capabilities, then migrate the hand-written arity families in `sla_ecs`. Wherever mechanical expansions such as `AnyOf5`, `AnyOf6`, `Any5`, and `Any6` must be hand-written, first add the compiler macro capability, then generate them from library-side templates.

---

## Appendix A: Source Locations Referenced in the Assessment

| File | Lines | Purpose |
|------|-------|---------|
| `sa_plugin_sla/src/parser.zig` | 581-610 | `parseMacroDecl` tested syntax |
| `sa_plugin_sla/src/ast.zig` | 116 | `MacroDecl` structure |
| `sa_plugin_sla/src/codegen.zig` | 90-92 | α-conversion naming rules |
| `sa_plugin_sla/src/codegen.zig` | 2313-2330 | `genMacroDecl` lowering to SA `[MACRO]` |
| `sa_plugin_sla/src/source_expand.zig` | — | `@expand_tuple` limited-arity source expansion |
| `sa_plugin_sla/docs/sla_language_specification_cn.md` | §10-11 | Hygienic macro design |
| `sa_plugin_sla/tests/test_edge_cases.sla` | — | Macro test cases |
| `sa_plugin_sla/tests/test_unit_expand_tuple_macro.sla` | — | `@expand_tuple` generics/arity end-to-end test |
| `sci/docs/faq.md` | Type system section | Why there are no traits / compile-time reflection |
| `bevy_local/crates/bevy_ecs/macros/` | — | Reference for Bevy's derive implementation |

## Appendix B: v0.1 Recommended Language-Neutral `@derive(...)` Allowlist

| derive | Generated content | Complexity | Weeks |
|--------|-------------------|------------|-------|
| `@derive(copy)` | Mark a plain value type as copyable | Implemented | — |
| `@derive(eq)` | Generate field equality comparison | Implemented | — |
| `@derive(ord)` | Generate field lexicographic comparison | Implemented | — |
| `@derive(hash)` | Generate field hash combination | Implemented | — |
| `@derive(debug)` | Generate a basic debug string | Implemented | — |
| `@derive(default)` | Language-neutral default value generation; must not assume ECS semantics | To be assessed | — |

ECS derive names such as `Component`, `Bundle`, `Resource`, `Event`, `Message`, and `Relationship` may only serve as project-level annotations or future general macro inputs, interpreted and expanded by `sla_ecs`; they must not enter the Zig allowlist of `sa_plugin_sla`.

## Appendix C: Impact of Not Introducing the `!` Suffix in Sla

Refer to sections §C/§D of the "Sla → Rust Surface Compatibility Assessment" in [`sa_plugin_sla/README.md`](../README.md):

Because Sla **does not introduce** the `ident!` macro suffix in the short term (it visually conflicts with SA's `!` release primitive), all Rust macro calls of the form `println!(...)` / `vec!(...)` / `assert!(...)` must be written as **function calls** in Sla:

```rust
// Rust
println!("x = {}", x);
let v = vec![1, 2, 3];
assert!(x > 0);
```

```sla
// Sla
println("x = ", x);             // 普通函数
let v = [1, 2, 3];              // 数组字面量
assert(x > 0);                  // 普通函数
```

The conversion tool (Path 2) should automatically strip the `!` and rewrite.
