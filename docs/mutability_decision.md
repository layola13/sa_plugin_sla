# Sla Mutability Design Decision (Whether to Introduce `mut`)

> This is the English counterpart of the Chinese document [Sla 可变性设计决策（mut 引入与否）](./mutability_decision_cn.md).

> **Document version**: v0.2-final (corrected based on testing) / 2026-06-15
> **Status**: Technical decision finalized
> **Revision summary**: v0.1, based on "hypothetical future pain points", recommended immediately introducing `&mut T`; **v0.2 corrects this based on tested demos** — Sla's current `&self` convention covering both reads and writes works well, so **Phase 1 (now) does not change the language layer**, only documenting the convention + optional parser tolerance; **Phase 2 (before sa3d ECS begins)** is when `&mut T` / `&mut self` are introduced (because the ECS scheduler needs static read/write sets).
> **Related documents**:
> - [`sla_language_specification_cn.md`](./sla_language_specification_cn.md) Sla language specification
> - [`macro_vs_rust_cn.md`](./macro_vs_rust_cn.md) Sla macros vs Rust macros
> - [`../README.md`](../README.md) Rust surface compatibility assessment
> - [`/home/vscode/projects/sa_plugins/sa_plugin_3dengines/docs/sa3d_ecs_api_design_cn.md`](../../sa_plugin_3dengines/docs/sa3d_ecs_api_design_cn.md) sa3d ECS API (Phase 2 trigger)
> - [`/home/vscode/projects/sa_plugins/sa_plugin_3dengines/docs/sla_migration_stepbystep_cn.md`](../../sa_plugin_3dengines/docs/sla_migration_stepbystep_cn.md) sa3d implementation roadmap

---

## 0. v0.2 Revision Notes (Apology and Correction)

**Where v0.1 went wrong**:
- Based on **hypothetical future scenarios** such as Bevy ECS, library ecosystems, and LLM Agents, it concluded that failing to introduce `mut` immediately would be fatal
- Did not look at the tested code in `sa_plugin_sla/demos/rosetta/`
- Exaggerated "something that will happen someday" into "it is broken right now"

**Corrections from testing**:
- `demos/rosetta/59_method_counter/main.sla` wraps `self.0 += 1` in `&self`, **works**
- `demos/rosetta/40_impl_block_state/main.sla` wraps `self.balance = ...` in `&self`, **works**
- `demos/rosetta/07_trait_vtable/main.sla` wraps a pure read in `&self`, **works**
- All existing demos and tests **work normally** under Sla's `&self` convention covering both reads and writes — the SA Referee handles the read/write distinction after lowering

**The corrected real timeline**:
- **Phase 1 (now → before sa3d ECS begins)**: no `&mut`; explicitly document the "`&self` covers reads and writes" convention; the parser optionally accepts Rust syntax with tolerance
- **Phase 2 (before sa3d ECS Phase 6A begins)**: introduce `&mut T` + trait `&mut self` (the ECS scheduler needs static read/write sets for parallel scheduling)
- **Phase 3 (when the library ecosystem takes shape)**: upgrade the Sla borrow checker from "defer to the SA Referee" to precise error reporting at the Sla source level

---

## 1. Decision Summary (TL;DR)

| Item | Current (Phase 1) | Phase 2 (before sa3d ECS) |
|------|-------------------|---------------------------|
| **`let x = 5` binding mutability** | Mutable by default (unchanged) | Mutable by default (unchanged) |
| **`const x = 5` binding** | Immutable (unchanged) | Immutable (unchanged) |
| **`let mut x = 5` syntax** | **Not introduced** (conflicts with Sla's current behavior) | **Not introduced** |
| **`&self` in impl/trait** | **Covers reads and writes** (Sla's current convention) | Reads only; writes require `&mut self` |
| **`&mut T` borrow type** | **Not introduced** | **Introduced** |
| **trait method `&mut self`** | **Not introduced** | **Introduced** (enforced contract) |
| **function signature `&mut Vec`** | **Not introduced** | **Introduced** (recommended) |
| **Effect on lowered SA** | None | Zero impact (still lowered to SA `&`) |
| **Effect on existing Sla code** | **Zero changes** | Write-method signatures `&self → &mut self`, automated migration by tooling |
| **Rust surface compatibility** | 70% (not 95%, acceptable) | 85% |

---

## 2. Phase 1: Minimal Actions for the Current Stage

### 2.1 Do Not Do (avoid churn)

- ❌ Do not touch the parser
- ❌ Do not touch the type_checker
- ❌ Do not touch codegen
- ❌ Do not touch existing demos / tests / sa_std calls

### 2.2 Must Do (document the convention)

#### A. Add a paragraph to the borrowing section §6 of `sla_language_specification_cn.md`:

> **Mutability convention (current version)**:
> Sla's `&self` / `&T` covers both Rust's `&self`/`&T` and `&mut self`/`&mut T` — **both reads and writes are allowed**.
> No distinction is enforced at the Sla source level at compile time; after lowering, the SA Referee dynamically determines `Locked_Read` / `Locked_Mut` based on store operations.
>
> **Migrating from Rust**:
> - Rust `fn inc(&mut self)` → Sla `fn inc(&self)`
> - Rust `let mut x = 5` → Sla `let x = 5`
> - Rust `&mut x` → Sla `&x`
>
> **Future versions** (when sa3d ECS goes live) will introduce `&mut T` and `&mut self` as distinct borrow types, to support the ECS parallel scheduler and library ecosystem API contracts. An automated migration tool will be provided at that time.

#### B. Update the corresponding row in the Rust compatibility table in `sa_plugin_sla/README.md` (partially done)

#### C. Write a "Phase 2 trigger condition" as a team backlog item:

> **`mut` introduction trigger conditions**:
> 1. sa3d ECS Phase 6A begins (required)
> 2. Or: a third-party Sla library ecosystem forms with ≥ 5 independent authors
> 3. Or: LLM Agents generating Sla code at scale show a ≥ 10% borrow-related error rate
>
> Meeting any one of these triggers Phase 2, estimated at 3-4 weeks of work.

### 2.3 Optional (Rust paste-friendly)

Add an `--accept-rust-mut` flag to the parser (off by default):

| Rust syntax | Parser behavior |
|-------------|-----------------|
| `let mut x = 5` | Accept, treat as `let x = 5`, no warning |
| `&mut x` | Accept, treat as `&x`, no warning |
| `fn foo(&mut self)` | Accept, treat as `fn foo(&self)`, no warning |
| `fn foo(v: &mut Vec)` | Accept, treat as `fn foo(v: &Vec)`, no warning |

**Why the flag is off by default**: to avoid burdening the Sla mainline with the debt of "silently absorbing `mut` without actually enforcing it". Enabling the flag means the user explicitly accepts this trade-off.

**Effort**: 3-5 days. Add a `mut` token to the lexer + four absorption points in the parser. **Optional for Phase 1**.

---

## 3. Phase 2: Engineering Before sa3d ECS Begins

### 3.1 Trigger Scenario

sa3d ECS system functions need static read/write sets:

```sla
fn move_sys(q: Query2<&mut Pos, &Vel>) { ... }    // Pos 写、Vel 读
fn render_sys(q: Query1<&Pos>) { ... }            // Pos 读

// 调度器静态分析：
//   move_sys 写 Pos
//   render_sys 读 Pos
//   → 必须串行（写后读）
//
// 如果两者都是 &Pos（sla 当前约定），调度器拿不到 read/write 集，
// 只能保守全部串行 → 完全失去并行优势
```

**This is the hard trigger for Phase 2**.

### 3.2 Introductions

| Item | Form | Behavior |
|------|------|----------|
| `&mut T` borrow type | `fn push(v: &mut Vec, item: int)` | Sla borrow checker enforces exclusivity |
| trait method `&mut self` | `trait Push { fn push(&mut self, item: int); }` | Enforced contract; all impls must comply |
| Third UFCS rule | `v.push(1)` automatically rewritten to `push(&mut v, 1)` | Parallel to `&` / by-value passing |
| Precise borrow-conflict errors | Sla source-level location + clear mut/immut hints | Benefits the LLM self-repair loop |

### 3.3 Never Introduced

| Item | Reason |
|------|--------|
| `let mut x = 5` | Conflicts with Sla's `let = mutable`; silently misleading |
| Reverse Sla's `let` default | Destructive; all existing code would break |
| `mut` modifying a let binding | Same as above |
| `&mut` existing independently in lowered SA | SA philosophy unchanged; the Referee still dynamically determines reads/writes |

### 3.4 Automated Migration Tool

`sa migrate sla-add-mut` (delivered alongside Phase 2):
- Scan all `.sla` files
- Detect whether a `&self` method body contains `self.x = ...` / `self.x += ...` / `store self+...` operations
- If so → automatically change to `&mut self`
- Update trait declarations to `&mut self` accordingly
- Callers `v.method()` unchanged (absorbed by automatic UFCS rewriting)
- Effort: 1-2 weeks

### 3.5 Effort Estimate

| Task | Estimate |
|------|----------|
| Lexer: recognize the `mut` token (skip if already done in Phase 1) | 0 / 0.5 days |
| Parser: parse `&mut T` types and `&mut self` | 2 days |
| AST: `Type::RefMut(Box<Type>)` node | 1 day |
| Type checker: `&mut T` as a distinct type, third UFCS rewrite | 1 week |
| Borrow checker: dual-track mut/immut exclusivity | 1-2 weeks |
| Error messages: precise mut/immut conflict errors | 3-5 days |
| codegen: lower `&mut T` to SA `&` | 1 day |
| Automated migration tool `sa migrate sla-add-mut` | 1-2 weeks |
| Unit tests + integration tests | 1 week |
| Documentation updates (including migration guide) | 3-5 days |

**Total: 4-5 weeks for one person**.

---

## 4. Phase 3: When the Library Ecosystem Takes Shape

### 4.1 Trigger Scenario

- Multiple independent authors publish Sla packages
- Borrow errors need precise reporting at the Sla source level (users should not have to look at SA Referee register numbers)

### 4.2 Upgrade Content

- Upgrade the borrow checker from "defer to the SA Referee" to whole-function local analysis
- Error message format: `error[SLA-BC-042]: cannot borrow x as mutable because it is also borrowed as immutable at line 12`
- Cross-function borrow contract verification (based on `&mut T` signatures)

### 4.3 Effort Estimate

About 4-6 weeks. **Not in the current backlog**; revisit when triggered.

---

## 5. Testing: The Valid Range of Sla's Current `&self` Convention

| Scenario | Is the convention sufficient? | Evidence |
|----------|-------------------------------|----------|
| Single entity method call | ✅ | `demos/rosetta/59_method_counter` |
| Static trait dispatch | ✅ | `demos/rosetta/07_trait_vtable` |
| State machine pattern | ✅ | `demos/rosetta/40_impl_block_state` |
| Simple builder | ✅ | `demos/rosetta/55_builder_pattern` |
| Associated functions | ✅ | `demos/rosetta/17_associated_fn` |
| Closure capture | ✅ | `tests/test_unit_closures.sla` |
| Multiple borrow conflicts | ⚠️ Current convention is too permissive, but the SA Referee is the backstop | — |
| Parallel ECS scheduling | ❌ The scheduler cannot obtain static read/write sets | Phase 2 trigger |
| Public library API contracts | ❌ Users cannot tell from the signature whether it mutates | Phase 3 trigger |

**For all current use cases, Sla's `&self` convention is sufficient**. Real pain points appear only in Phase 2/3.

---

## 6. Compatibility Strategy When Introducing Phase 2

### 6.1 Accept Old Syntax by Default

After introducing `&mut T`, the old form `fn inc(&self) { self.x = ...; }` **remains legal** — but is treated as "undeclared mutability", with the borrow checker handling it according to the current Sla convention (conservatively permissive).

**Benefit**: existing code does not break.

### 6.2 Recommended Upgrade to the New Syntax

The `sa sla check --warn-implicit-mut` flag: scan for methods whose function body contains a store but whose signature is `&self`, and emit a warning:

```
warning [SLA-IMPLICIT-MUT]: method `inc` mutates `self` but signature is `&self`.
  Consider changing to `&mut self` for explicit contract.
  --> example.sla:42:12
```

### 6.3 Upgrade Path

```
Phase 2 启动 → sa migrate sla-add-mut → 全代码库自动升级
                    ↓
              检查 + 测试通过
                    ↓
              sa sla check --strict-mut（v0.3+）禁止隐式 mut
```

---

## 7. Key Insight: Sla's `&self` Convention Is an Extension of SA Philosophy

SA's design philosophy (faq.md § Ownership and Borrowing) says:
> Shared read vs. exclusive write is determined dynamically by the Referee within the **runtime context**, not distinguished at the syntax level.

**Sla's current `&self` convention covering reads and writes is precisely this philosophy manifested at the Sla layer**. Maintaining this convention in Phase 1 is **consistent with SA philosophy**.

The real reason for introducing `&mut` in Phase 2 is not "Sla is inconsistent with SA philosophy", but that **the ECS parallel scheduler needs static read/write sets** — this is an engineering reality, not a philosophical issue.

**So introducing `&mut` in Phase 2 is not a philosophical shift**, but adding a capability for a specific engineering scenario (ECS scheduling). At the SA level it still lowers to `&`, so the physical philosophy is unchanged.

---

## 8. Consistency Corrections with Earlier Documents

### Withdrawn / Corrected

| v0.1 statement | v0.2 correction |
|----------------|-----------------|
| "Introduce `&mut T` immediately" | "Introduce before Phase 2 sa3d ECS begins" |
| "Missing trait contracts are fatal" | "Only fatal in future ECS scenarios; no impact on current demos" |
| "Phase 1 changes parser/checker/codegen" | "Phase 1 only documents the convention + optional parser tolerance" |
| "Start immediately, 3-4 weeks for one person" | "Phase 1 effort ~0.5-1 week (docs + optional flag only); Phase 2 effort 4-5 weeks (do when triggered)" |

### Unaffected

| Part | Status |
|------|--------|
| `let` mutable by default | Unchanged |
| `const` immutable | Unchanged |
| No `let mut` syntax | Unchanged (conflicts with Sla's current behavior; never introduced) |
| `&mut T` and `&T` lowered to SA `&` | Unchanged |
| Phase 2 effort estimate of 4-5 weeks | Unchanged |

### Coordinated Document Updates

| Document | Adjustment |
|----------|------------|
| `sla_language_specification_cn.md` §6 | In Phase 1 add the "`&self` covers reads and writes" convention note; in Phase 2 add a `&mut T` section |
| `sa_plugin_sla/README.md` Rust compatibility | Change "`&mut T` introduced immediately" to "introduced in Phase 2" |
| `sa3d_ecs_api_design_cn.md` | Add a note "trait `&mut self` is introduced in sync when sa3d ECS Phase 6A begins" |
| `bevy_ecs_equivalence_analysis_cn.md` | In the "Capabilities the Sla compiler needs" list, move `&mut T` to the "Phase 2 prerequisite" item |
| `bevy_fast_sla_roadmap_cn.md` | Milestones 1-3 do not need `mut`; add `mut` before Milestone 4 (Bundle/Resource) begins |
| `sla_migration_stepbystep_cn.md` | In the Phase 0 Sla compiler probes, defer `mut`-related probes to before Phase 5/6 |

---

## 9. One-Sentence Summary (v0.2)

**Phase 1 (now)**: Sla's `&self` convention covering both reads and writes works well (confirmed by tested demos); **do not change the language layer** — only document the convention + optional parser tolerance (about 0.5-1 week).

**Phase 2 (before sa3d ECS Phase 6A begins)**: introduce `&mut T` + trait `&mut self` (the ECS scheduler needs static read/write sets for parallelism), 4-5 weeks of work, with an automated migration tool.

**Never introduced**: the `let mut x` syntax (conflicts with Sla's current `let = mutable` behavior).

**v0.1 → v0.2 revision**: corrected from "introduce `mut` immediately" to "introduce it based on engineering triggers". Honestly acknowledging that v0.1 was an overreaction based on hypothetical future pain points, corrected after testing the demos.
