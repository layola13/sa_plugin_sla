# Sla → Rust Surface Compatibility Assessment Report

> This is the English counterpart of the Chinese document [Sla → Rust 表层兼容性评估报告](./rust_surface_compat_report_cn.md).

> Assessment date: 2026-06-15
> Goal: To make Sla's surface syntax as close to Rust as possible without undermining SA's five-symbol contract (`= & ^ ! *`) and the Referee O(1) bitmask verification model.
>
> Note: This document is a **point-in-time** assessment snapshot; for specific phase status, refer to [`roadmap_status_cn.md`](./roadmap_status_cn.md).

## 1. Key Conceptual Corrections

**The two red lines correspond to SA design principles**

| Red line | Corresponding principle |
|----------|--------------------------|
| Do not abandon `^` | The "five-symbol contract" (design.md §1.3) + the core physical input of the affine state machine |
| Do not introduce `mut` | FAQ § Ownership and Borrowing: "shared read vs. exclusive write is determined dynamically by the Referee based on runtime context, **not distinguished at the syntax level**" |

The second point is especially critical — **the Referee already automatically distinguishes `Locked_Read` / `Locked_Mut` under the single `&` syntax**, by checking whether there is a `store` after the borrow view. Rust's `&mut` is entirely a redundant declaration; introducing it would actually violate "one fewer prefix = lower LLM error rate".

**Second key insight: Sla's `^` and Rust's `^` do not actually conflict**
- Sla `^x`: **prefix** unary = Move (`let y = ^x`)
- Rust `a ^ b`: **infix** binary = XOR

These two positions are different contexts in the parser and can coexist.

## 2. Reframing the Goal: A "Rust Surface-Compatible Subset"

The correct goal is not "to turn Sla into Rust", but rather:

> **Enable a large body of Rust code to parse as-is in Sla, with the compiler silently absorbing redundant Rust surface declarations (lifetime/pub/where) into SA's implicit behavior during lowering.**
>
> **On mutability (v0.2 revision)**: The current Phase 1 stage introduces no `mut` syntax; Sla's `&self` convention currently **covers both Rust's `&self` and `&mut self`**, with the SA Referee as the backstop after lowering (verified in practice by `demos/rosetta/59_method_counter` and others). `&mut T` and `&mut self` are deferred until just before sa3d ECS Phase 6A begins (Phase 2); `let mut` will never be introduced (it conflicts with Sla's current `let = mutable` behavior). See [`mutability_decision_cn.md`](./mutability_decision_cn.md).

This way LLMs/humans can paste Rust-style code directly, with the Sla compiler acting as a "translator + smart filter" while preserving all of SA's safety constraints.

## 3. Recommended Strategy: "Rust Style In, SA Semantics Out"

### A. Silent-Absorption Type (parsed but semantically nullified, zero cognitive load)

| Rust syntax | Sla post-parse handling | Rationale |
|-------------|-------------------------|-----------|
| `let mut x = ...` | **Never accepted** (Sla `let` is already mutable by default; `mut` is silently misleading) | Sla and Rust have opposite default mutability; see [`mutability_decision_cn.md`](./mutability_decision_cn.md) |
| `&mut T` borrow type | **Not introduced in Phase 1**; introduced in Phase 2 (before sa3d ECS) | Current `&T` covers both read and write; see [`mutability_decision_cn.md`](./mutability_decision_cn.md) §2.2 for trigger conditions |
| `fn foo(&mut self)` | **Phase 1**: currently unrecognized (must remove `mut` manually); **Phase 2**: introduced as a distinct exclusive-borrow contract | Same as above |
| `'a` / `'static` lifetime | Parse but do not carry into semantics | SA does not do cross-function borrow graphs (stated in FAQ) |
| `pub` / `pub(crate)` | Parse and discard | SA is linker-visible for everything by default (stated in FAQ) |
| `unsafe { ... }` / `unsafe fn` | Parse and discard; if raw pointers are involved, require wrapping in `@ffi_wrapper` | SA replaces block-level unsafe with `@ffi_wrapper` function-level isolation |
| `where T: Bound` | Parse; constraints are used only for trait method lookup during monomorphization | No constraint solving introduced |
| `#[derive(...)]` / `#[inline]` | Map to existing `@`/`inline` | Same semantics, different surface |

This part has zero intrusion into SA's design — it is purely frontend syntax ingestion.

### B. Direct Synonym Mapping (Rust syntax ↔ existing Sla/SA concepts)

| Rust | Sla | Notes |
|------|-----|-------|
| `use std::foo::bar` | `@import "sa_std/foo/bar.sai"` | Both tracks accepted; docs recommend Rust style |
| `extern "C" fn ...` | `@extern fn ...` | Both tracks |
| `#[test]` | `@test` | Both tracks |
| `println("...")` / `print(...)` | **Current implementation: no `!` suffix**, treated directly as an ordinary function call bridged to sa_std's `print` path | Sla already has `println`; **no `!` macro-call syntax in the short term** (see the "`!` decision" below) |
| `format(...)` / `vec(...)` / `panic(code)` / `assert(...)` | Same as above; in the short term all treated as functions / built-in intrinsics | Do not emit macro-suffix `!` |
| `i8..i64 / u8..u64 / f32 / f64 / usize / isize` | Add to the type table | `int` retained as an alias for `i64` |
| `bool` / `true` / `false` | Already present / add | |
| `as` cast | Add | Consistent with `.sa`'s `as` |
| `+= -= *= /= %= &= \|= ^= <<= >>=` | Add compound assignment | desugar to `x = x op y` |
| `&& \|\| ! << >> \| ~` (bitwise `\|`/`~`) | Add | Note `!` is still logical NOT, infix `^` = XOR |
| `_` | Add, as a destructuring/binding discard slot | Value is consumed on entering the frontend and does not enter scope |
| `..` struct update, `[a, b, ..rest]` slice destructuring | Add | Pure AST/lowering, no hidden runtime overhead |
| `loop / break / continue / 'label:` | Add (FAQ says SA has no built-ins, but the Sla frontend must support them, lowering to `jmp/br`) | Same flattener as `for/while` |
| `if let` / `while let` / `let else` | Add, desugar to `match` | |
| `match` multi-arm `\|`, guard `if`, `@` binding, `..=` range, `..` wildcard | Extend the existing match | |
| `impl Trait for T` + `trait` | Add, **static monomorphized dispatch only** (FAQ §"Why No Traits" has argued for static dispatch + vtable macros only) | No trait coherence, no GATs |
| `using module` static extension | Add, explicitly enables module-level method-style calls | Effective only within the `using` scope; ambiguity is an immediate error |
| `type Alias = A & B & { ... }` | Add, expand to a flat field layout | Pure frontend alias, no runtime wrapper introduced |
| `@overload` operator block | Add, static dispatch limited to `+ - * /` | Effective only within the `@overload` scope, takes precedence over normal arithmetic fallback |
| `Self / self / &self` | Already available; UFCS already exists and naturally covers this | Current `&self` covers both Rust `&self` and `&mut self` (both reads and writes allowed, with the SA Referee as backstop); `&mut self` introduced in Phase 2 |
| `enum Variant { A, B(T), C{x:int} }` | Add as a sum type; match destructuring lowered as `[tag\|payload]` (already sketched in the design doc) | |
| Character literal `'a'` | Add, distinguished from lifetime `'a` via lexer lookahead | |
| Numeric literal suffixes `1u32 / 1.5f64` | Add | |
| String literals → `&str` / `String` | Add; requires a fat-pointer layout in sa_std | |

### C. Important Semantic Differences That "Look Rust but Are Actually Sla" (must be documented explicitly)

| Surface | Actual semantics | Promise to developers |
|---------|-------------------|------------------------|
| `let mut x` | **Never accepted** (Sla `let` is already mutable by default) | Sla and Rust have opposite default mutability; see [`mutability_decision_cn.md`](./mutability_decision_cn.md) |
| `&T` | **Currently covers both read and write uses** (Sla convention); distinguished after `&mut T` is introduced in Phase 2 | Always lowered to SA `&`; the Referee's physical layer is unchanged |
| `Drop` trait | **Not supported** (FAQ § explicit over implicit) | `!` is still injected implicitly by the compiler; users **cannot** write `impl Drop` |
| `'a` annotation | Parse only | Cross-function borrow safety is the frontend's responsibility; no checking is performed |
| `unsafe` block | Degrades to a "statement of intent"; real pointer downcasting is still allowed only at the `@ffi_wrapper` function level | Block-level `unsafe { *raw }` → the enclosing function must be marked `@ffi_wrapper` at compile time or an error is raised |
| `panic!()` | `panic(code)` (numeric code) | The string variant goes through `panic_msg` in sa_std |
| `Send/Sync` | Parse; semantics are backed by the Referee's affine mask + cross-core verification (design.md §1.4#5) | No trait solving exposed |

### D. Refused Introductions (Guarding SA's Philosophy)

- `let mut x` syntax (permanent refusal; conflicts with Sla's current `let = mutable` behavior)
- ~~`&mut` as a distinct type~~ **Correction (v0.2)**: `&mut T` / `&mut self` **will be introduced** before Phase 2 sa3d ECS begins, for the ECS scheduler's static read/write sets; see [`mutability_decision_cn.md`](./mutability_decision_cn.md)
- `Drop` trait
- Implicit GC / unwind / panic catch
- Full NLL/Polonius lifetimes
- proc-macro / `macro_rules!` arbitrary complex expansion (retain Sla's hygienic `macro`; `println!` and similar are hard-coded)

## 4. Precise Parser Rules for `^` and `!` Under Rust Compatibility

**`^` dual-semantics split (critical; recommended to encode in parser tests)**

```
prefix  '^' expr          → Move (Sla 既有)
expr '^' expr             → XOR (Rust 风)
'^' 出现在 type 位置       → 非法
```

Discrimination rule: when a `^` token appears, check whether there is an expression ending on its left that can serve as an operand (identifier/literal/`)`/`]`). If yes → infix XOR; if no → prefix Move.

**`!` decision (short-term position)**

```
prefix '!' expr           → 逻辑非（唯一接受语义）
ident '!' (...)           → 短期内不引入。理由：与 SA 的 ! 释放原语在 lexer / 视觉上都易混淆，
                            等 SA 侧 !reg 完全收敛到编译器隐式注入、用户 .sla 中物理消除
                            "!" 出现位置之后，再评估是否打开此入口。
单独 '!' 后跟寄存器        → 仍是 SA 的释放原语，但 .sla 用户层禁止显式书写
                            （仅生成的 .sa 与 @debug 模式可见）
```

**Key clarifications**:
- Sla already has `println` as an ordinary function / built-in call, so no `!` suffix is needed.
- This is "not introduced in the short term", not "never introduced". Once SA-side `!` has completely disappeared from the `.sla` user surface and the visual-conflict risk is eliminated, Rust-style `println!` / `vec!` / `assert!` macro entry points can be re-evaluated.
- In the meantime, when the Sla parser accepts `println!("...")` in Rust source code, a **fault-tolerant downgrade** is recommended: strip the `!` immediately adjacent to the identifier as "syntax noise", rewrite it as `println("...")`, and continue parsing. This preserves the "Rust surface-compatible subset" promise without polluting Sla's own `!` semantics.

These rules change nothing in SA; they are purely the responsibility of the Sla frontend parser.

## 5. Revised Roadmap (by ROI)

**Phase 1 — Lexer/Type Table Expansion (1 week)**
1. Add tokens: `&&` `||` `<<` `>>` `|` `~` `+=` family `..=` `'` `#` `_`
2. Add `i8/i16/i32/i64/u8/u16/u32/u64/usize/isize/f32/f64/str` to the type table; `int` = `i64` alias
3. Literals: `true/false/0x/0o/0b`, character `'a'`, literal suffixes
4. Parser with precise dual semantics for `^` and three semantics for `!`

**Phase 2 — Silent-Absorption Syntax (1 week)**
- Parse `mut/pub/'a/where/unsafe/#[...]`, discarding all of it or synonymously rewriting to `@` syntax
- Dual tracks for `use` / `mod` and `@import`

**Phase 3 — Control Flow Completion (1 week)**
- `loop` / `break` / `continue` / labeled break / `as` / compound assignment / `if let` / `while let` / `let else`

**Phase 4 — match Extension + Real enums (2 weeks)**
- Multi-arm `|`, guard `if`, `@` binding, range `..=`, `..` wildcard
- Sum-type enums with payloads, lowered according to SA's tagged union layout (design.md §1.4#2)

**Phase 5 — Static trait Dispatch (2 weeks)**
- `trait` + `impl Trait for T`
- Generate only monomorphized functions + vtable macros; compare with the `DISPATCH` macro in FAQ § dynamic dispatch

**Phase 6 — Standard Library Surface**
- `println` / `print` / `format` / `panic` / `assert` as functions / built-in intrinsics **without a `!` suffix**, bridged to sa_std's existing macros (consistent with Sla's already-implemented `println` path)
- `println!(...)` in Rust source is fault-tolerantly stripped of `!` by the parser and rewritten as `println(...)`
- `Vec/Box/Rc/Arc/Option/Result/String/&str` bridged via `@extern` + `.sal`, with naming aligned to Rust
- Once SA-side `!` is completely invisible at the `.sla` user level, re-evaluate whether to open Rust-style `!` macro-call entry points

## 6. Recalibration of the Achievable "Rust Compatibility"

Pragmatic goals:
- **Phase 1 (current)**: Rust surface ≈ **70%** (`let mut x` / `&mut T` / `&mut self` all require manually removing `mut`; by convention `&self` covers reads and writes)
- **Phase 2 (before sa3d ECS begins)**: Rust surface ≈ **85%** (`&mut T` / `&mut self` introduced; `let mut` never introduced)
- Semantics ≈ Rust safe single-threaded subset − Drop trait − full lifetimes − proc-macro

Leave one page of documentation to explain the differences clearly:
1. **Reversed mutability + current `&self` covers reads and writes**: Sla `let` is mutable by default (Rust `let` is immutable by default); `let mut` is never introduced; current `&self` covers both Rust `&self/&mut self`, with the SA Referee as backstop; `&mut T` / `&mut self` introduced before Phase 2 sa3d ECS begins. See [`mutability_decision_cn.md`](./mutability_decision_cn.md)
2. `Drop` is handled by the compiler
3. Lifetimes are only annotations
4. `unsafe` is confined to the function level

When writing code, an LLM barely notices the boundary — it generates Rust style, Sla silently absorbs it, and SA receives a clean, flat ownership instruction stream.
