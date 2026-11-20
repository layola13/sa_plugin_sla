# Struct Update (`..base`) Direct SAB Implementation Assessment and Improvement Plan

> This is the English counterpart of the Chinese document [Struct Update (`..base`) 直接 SAB 实现评估与改进方案](./struct_update_sab_review_cn.md).

Assessed object: `genStructLiteral` in `src/sab_codegen.zig` (the `update_expr` branch has currently been added, around lines 5933-5973),
with reference to the SA-text reference implementation `genStructLiteralInto` in `src/codegen.zig` (around lines 7582-7686).

Target fixture: `tests/test_unit_struct_update.sla` (Phase 5, aggregate update/copy/drop semantics).

## Current Status

Added 2026-07-02: the subsequent Phase 5 follow-up has been completed. `StructLiteralFieldTransfer` has been added to `src/lowering_rules.zig`; both SA-text and direct SAB consume the same direct/deep-copy/move field-transfer strategy, and direct SAB has removed the explicit narrowing for safe pointer-backed update fields. A new `tests/test_unit_struct_update_pointer_backed.sla` covers move preservation of an untouched `Vec<i32>` field under `..base`; dev-mode direct SAB no-fallback and SA-text parity both pass; the full host no-fallback sweep is 72/72. The original assessment below is retained as historical background.

- `tests/test_unit_struct_update.sla` passes in dev mode:
  - `SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_struct_update.sla --test-backend sab --jobs 1 --trace-panic` → 2/2 passed.
  - `SA_PLUGIN_DEV=1 sa sla test tests/test_unit_struct_update.sla --test-backend sa --jobs 1 --trace-panic` → 2/2 passed.
- `zig build --summary all` passes.
- SAB now consumes the shared field plan via `lowering_rules.planStructLiteralField` (two sources, `.explicit` / `.update`), which conforms to the Y-shaped architecture requirement and is the right direction.

Conclusion: **the scalar scenarios of the current fixture already pass correctly**, but the implementation has semantic divergence from SA-text and potential ownership/aliasing defects, and the release/ownership strategy is still emitter-local, not converged into shared rules. The following are the points needing correction by other threads, in priority order.

## Issue 1 (Correctness/Aliasing, Highest Priority): The Update Path Shallow-Copies and Then Releases Untouched Pointer-Typed Fields

The current `.update` branch:

```zig
.update => {
    const src = update_reg orelse return Error.UnsupportedSabDirectFeature;
    const loaded = try self.intern(try self.newTmp());
    try self.emitLoad(loaded, src, layout.offset, prim);
    try self.emitStore(dst, layout.offset, loaded, prim);
    if (!self.isLocalReg(loaded)) try self.emitRelease(loaded);
},
```

For pointer-typed fields (`Vec`, `String`, `Box`, nested structs, etc., `prim == .ptr`) there are two overlapping defects:

1. **Shallow-copy aliasing**: what `load` produces is a pointer; after `store` into `dst`, that field of `dst` and of the source `base` point to the same heap memory. When either side is later auto-released at scope end, the other is left dangling / double-freed.
2. **Immediate release after copy**: `loaded` is always a fresh tmp, so `isLocalReg(loaded)` is always false and `emitRelease(loaded)` runs **unconditionally**. This releases the very pointer `dst` just stored, directly leaving `dst`'s field dangling.

All fields of the current fixture are `i32` scalars, and releasing scalar registers is lazy/harmless, which masks this problem. Any pointer-typed untouched field would crash.

Comparison with SA-text (`genStructLiteralInto`, lines 7605-7609):

```zig
const loaded_reg = try self.newTmp();
// load ... store ...
if (callArgNeedsRelease(update_expr)) try self.emitRelease(loaded_reg);
```

SA-text releases the loaded field only when the **update source expression itself is a temporary** (`callArgNeedsRelease(update_expr)` is true); when `old_item` in `..old_item` is a local/parameter identifier it does not release. SAB's unconditional release diverges from this.

### Recommended Fix

- Align the release condition with SA-text: change `if (!self.isLocalReg(loaded)) try self.emitRelease(loaded);` to release only when `lowering_rules.callArgNeedsRelease(update_expr.?)` is true.
- For untouched pointer-typed fields (`prim == .ptr`), shallow-copy semantics are inherently unsafe. Until a shared deep-copy/move plan exists, it is recommended to **explicitly narrow the supported surface**: when the `.update` branch encounters a field whose `layout.ty` is pointer-typed (struct / array / Vec / String / Box, i.e. non-Copy scalars), return `Error.UnsupportedSabDirectFeature`, so the gap fails explicitly instead of silently producing aliasing IR. This conforms to the tasks.md principle of "do not turn move symbols into silent unsupported cases" — record the to-do with an explicit fixture.
- Once Phase 5's shared aggregate update/copy/drop plan lands, pointer-typed fields should use deep copy or explicit move semantics (see Issue 3).

## Issue 2 (Correctness/Arguments, Medium Priority): The `.explicit` Branch Lacks copy-struct Deep Copy

SAB's `.explicit` branch:

```zig
.explicit => {
    const value = plan.value orelse return Error.UnsupportedSabDirectFeature;
    const value_reg = try self.genExpr(value);
    try self.emitStore(dst, layout.offset, value_reg, prim);
    try self.releaseExprResultIfNeeded(value, value_reg);
},
```

SA-text has an additional branch for explicit fields (lines 7675-7679): when `value` is an `identifier` and the field type is a copy-struct (`typeIsCopyStruct`), it performs a `genCopyValueInto` deep copy before storing. SAB lacks this step and will shallow-copy the pointer of a copy-struct local directly into `dst`, diverging from SA-text and reintroducing aliasing.

### Recommended Fix

- Reuse the existing `genCopyValue` in the `.explicit` branch (SAB already has this function, around line 5975): when `value.* == .identifier and self.typeIsCopyStruct(field.ty)`, after `genExpr` obtains the source pointer, call `genCopyValue` for a deep copy, then `emitStore` the copied result.
- Need access to the field's AST type `decl_field.ty` (`plan` currently carries only `layout`; `decl_field.ty` can be used directly, since the loop variable is `decl_field`).

## Issue 3 (Architecture/Y Convergence, Medium Priority): Ownership/Release Strategy for Update Fields Is Still Emitter-Local

The architectural boundary required by `tasks.md`: the semantic decisions for struct update/copy/drop belong in the shared aggregate layout/update rules in `src/lowering_rules.zig` or in typecheck metadata; SAB only emits structured load/store from the plan and does not invent aggregate-update semantics on its own.

Current situation: the field's **layout and source classification** are already shared (`planStructLiteralField` provides `.explicit`/`.update` and `layout`), but the ownership strategy — **whether each field is deep-copied, whether it is released, and how pointer-typed fields are handled** — is written separately and inconsistently in SA-text and SAB. This is exactly the situation described in tasks.md: "if only the direct SAB tail is fixed while lowering decisions remain outside `lowering_rules.zig`, it is recorded as a partial bug fix and the Y/shared task stays open."

### Recommended Fix

Add ownership-decision fields to `StructLiteralFieldPlan` in `lowering_rules.zig` so both emitters consume the same contract, for example:

- `needs_copy: bool` — whether this field needs a deep copy (copy-struct whose source is an identifier).
- `field_ty: *const ast.Type` — the field's AST type (for the emitter to determine pointer-typed / copy).
- `release_loaded: bool` for the update-source field — whether to release the loaded field (equivalent to SA-text's `callArgNeedsRelease(update_expr)`).
- `is_pointer_backed: bool`, or directly expose an `updateFieldPolicy(...)`, making "shallow copy vs deep copy vs unsupported" a shared decision.

Then change both SA-text's `genStructLiteralInto` and SAB's `genStructLiteral` to read these decisions from the plan, removing their respective inlined `typeIsCopyStruct` / `callArgNeedsRelease` decision branches. Only then can this slice be recorded as Y/shared 100% rather than a partial bug fix.

## Issue 4 (Boundary, Low Priority): union / ManuallyDrop Fields

- SAB directly rejects unions at the entry point `if (decl.is_opaque or decl.is_union) return Error.UnsupportedSabDirectFeature;` — a safe behavior (explicitly unsupported), requiring no immediate action.
- SA-text has dedicated branches for unions and `ManuallyDrop` fields (lines 7614-7647, 7662-7674). If a later fixture needs struct-update combined with union/ManuallyDrop, this should be expressed in the shared plan rather than copying SA-text's branches into SAB. There is currently no fixture; keeping it explicitly unsupported is fine, but a with-fixture to-do should be recorded in tasks.md.

## Recommended Verification Gates (to Be Run by Other Threads After Fixes)

- `zig fmt --check src/sab_codegen.zig src/lowering_rules.zig src/codegen.zig`
- `zig build --summary all`; `zig build test --summary all`
- `sa plugin install --dev .`; `SA_PLUGIN_DEV=1 sa sla help`
- Focus: `SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_struct_update.sla --test-backend sab --jobs 1 --trace-panic` (should be 2/2)
- SA-text parity: `SA_PLUGIN_DEV=1 sa sla test tests/test_unit_struct_update.sla --test-backend sa --jobs 1 --trace-panic` (should be 2/2)
- If explicit unsupported handling for pointer-typed untouched fields is added, create a new fixture with a `Vec`/`String`/nested-struct untouched field to verify "explicit failure" rather than silent aliasing, and register it in tasks.md as a Phase 5 to-do.
- Post-completion guard regressions: `sets`, `rc_dyn_trait`, `var_comprehensive`, assignment cleanup, `pkgjson`, RefCell struct payload, trait static dispatch, and `/home/vscode/projects/sla_ecs/lib/parallel.sla`.
- Full dev-mode no-fallback sweep (Phase 9 command), recording pass/total in `progress.md` and `tasks.md`. The current fixture passes; the expectation is 62/69 → 63/69 (needs an actual run to confirm, due to concurrent modifications).
- After touching call/store, run the disasm guard: `sa sla sab disasm <latest.sab> | rg 'call .*@[^" ]+\('` should have no matches.

## Priority Summary

1. Issue 1 (update pointer-typed field shallow copy + erroneous release): correctness defect, highest priority. Minimal fix = align SA-text's release condition + explicitly narrow untouched pointer-typed fields.
2. Issue 2 (missing explicit copy-struct deep copy): diverges from SA-text; fill in by reusing `genCopyValue`.
3. Issue 3 (converge ownership strategy into the shared `StructLiteralFieldPlan`): prerequisite for reaching Y/shared 100%.
4. Issue 4 (union/ManuallyDrop): keep explicitly unsupported; just register a to-do.

The scalar scenario can already serve as a completion regression; but until Issues 1 and 2 are fixed, this slice should not be reported as Y/shared-lowering 100% — only as the scalar subset passing.

## Next-Step Plan (After the Above Bugs Are Fixed)

The following is a recommended order for wrapping up the struct-update slice and continuing Phase 5 → Phase 9. Every step follows the definition of done in `tasks.md`: local build/test → focused dev no-fallback → SA-text parity → completion guard regressions → full sweep → `sa plugin install --dev .` / `SA_PLUGIN_DEV=1 sa sla help` → `parallel.sla` → disasm guard → docs sync → `git diff --check` → commit.

### Step 0: Wrap Up the struct-update Slice (Do First, Close the Current Slice)

- Complete the fixes per Issues 1 and 2; move ownership decisions up into `StructLiteralFieldPlan` per Issue 3.
- Run the full set of "Recommended Verification Gates". Sweep expectation 62/69 → 63/69 (needs an actual run to confirm, there are concurrent modifications).
- Update `tasks.md` / `progress.md` / `current_plan.md`:
  - In the 62/69 failure matrix, check `test_unit_struct_update.sla` from open to done.
  - Append a Completed Slice Evidence Ledger (list the extracted shared contract, the removed/delegated emitter-local branches, the fixture proving no-fallback, and the SA-text parity runs).
  - Use the standard report format: `Feature: struct update 100%; Y/shared-lowering: 79% -> ~80%; direct SAB fallback-removal: 92% -> ~93%; no-fallback sweep: 63/69; host gate: passed; commit: <hash>`.
- Commit this single verified slice. **If untouched pointer-typed fields only receive "explicit narrowing to unsupported" without deep-copy implementation**, report it as scalar-subset completion and leave a Phase 5 to-do in tasks.md with `Vec`/`String`/nested-struct fixtures, without marking Y/shared as full.

### Step 1: `test_unit_spaceship_cmp.sla` (Phase 5, Recommended Immediately After struct-update)

- Reason for choosing it next: it **shares the same set of aggregate/derived layout rules** with struct-update (`@derive(ord)`'s field-by-field lexicographic comparison of a `SortKey` reuses exactly the field layout/traversal logic just moved into the shared plan); changes are concentrated in operator/derived comparison.
- Form: `<=>` returns `Ordering`; scalar integer comparison + derived struct lexicographic comparison + `Ordering`'s `is_lt/is_eq/is_gt/reverse/then` methods (the latter from `sla_std/cmp.sla`).
- Architectural placement: `Ordering` should go through std-surface metadata + the `sla_std/cmp.sla` macro; do not write `Ordering` type-name branches in SAB; the derived `ord` field-by-field comparison should be a shared derived-comparison plan (`lowering_rules.zig`) consumed by both emitters.
- Classify first: `SLA_SAB_TRACE_UNSUPPORTED=1 SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_spaceship_cmp.sla --test-backend sab --jobs 1 --trace-panic`, record the stmt/expr type of the first `UnsupportedSabDirectFeature` before starting.

### Step 2: `test_unit_derive_semantics.sla` (Phase 5)

- Strongly related to Step 1: `@derive(copy, eq, ord, hash, debug)`. The field-by-field logic of `copy`/`eq`/`ord` reuses the shared derived layout/comparison plan established in Steps 0 and 1; `hash`/`debug` need their own derive-generation function metadata.
- Architectural placement: derived-generated `eq`/`ord`/`hash`/`debug` functions go through the shared derive plan + std-surface metadata; SAB only emits structured calls from the plan and writes no library-name branches for `hash`/`debug`.
- `copy` semantics must be unified with the `genCopyValue` deep-copy path from Step 0 Issue 2 — the same copy-struct contract.

### Step 3: `test_unit_enum_match.sla` (Phase 5, Closing the Aggregate/Enum Batch)

- Form: enums with payload (`Message::Move { x, y }` vs unit `Message::Quit`), `match` extracting payload, branch cleanup.
- Architectural placement: shared enum tag/payload layout, match extraction, branch cleanup, and value merge policy (already listed in `tasks.md` Phase 5). This is the most self-contained piece of Phase 5, so it is placed last to close out.
- Prerequisite dependency: match-branch release/merge state can reuse the already-completed branch scoping of `var_comprehensive` and the merge-release logic of `genIfValue`.

> After completing Steps 1-3, Phase 5 exits; expectation: Y/shared-lowering ~88-92%, direct SAB fallback-removal ~96%, sweep pushed from 63/69 to 66/69.

### Step 4: Phase 6 Protocol Iteration (`for_in_protocol` + `generic_for_in_protocol`)

- Do both fixtures together: non-generic and generic `for in` go through the **same** shared iterator/protocol plan (after monomorphization), covering range/array/slice/Vec forms, item-binding ownership, loop cleanup, and break/continue release state.
- Completion rule: protocol dispatch must be data/plan-driven, with no type-name branches in an individual emitter. Expected sweep → 68/69.

### Step 5: Phase 8 `test_unit_async_await.sla` (Last)

- Do only after call/std/control/import are all stable. Reuse std `Future`/task metadata + shared state-machine rules; do not write SAB-only async lowering.
- If the supported subset is limited, it is acceptable to explicitly record "unsupported surface + specific fixture to-dos", but this must be written clearly in `progress.md`.

### Step 6: Phase 9 Fallback-Removal Gate (Endgame)

- Target 69/69 no-fallback (two separate sweeps, local + host, not counted together); or every remaining fallback has an explicit with-fixture to-do.
- Full run before the endgame: `zig fmt`, `zig build --summary all`, `zig build test --summary all`, `sa plugin install --dev .`, `SA_PLUGIN_DEV=1 sa sla help`, focused host no-fallback regressions, `parallel.sla`, full local sweep, full host sweep, `git diff --check`, docs sync, per-slice commits.
- Definition of done: Y/shared-lowering 100%, tracked-corpus direct SAB fallback-removal 100%, macro/borrow/precedence targets all green, no unexpected fallback logs, `progress.md` and `tasks.md` in sync, all verified slices committed.

### Cross-Cutting Principles (Apply to Every Step)

- Commit only verification results that have passed both local and host gates for each slice; do not commit exploratory changes.
- After each fixture is completed, report the four percentages + sweep count using the standard template, and sync `progress.md` / `tasks.md` / `current_plan.md`.
- If more than 10 verified slices accumulate uncommitted, stop and recommend a batch commit.
- All new semantics go into `lowering_rules.zig` / the shared frontend/typecheck / `std_surface.sla_meta` / `sa_std`; SAB only consumes contracts — this is the shared architectural red line for every step after Phase 5.

---

## Inspection Log

> A code inspection assessment every 10 minutes (session-only scheduled task, static assessment only, no code changes).

### 2026-07-01 First Inspection (Baseline Check)

**Code status**: `genStructLiteral` has drifted from line 5933 to 5945, indicating concurrent changes. Check result: Issues 1, 2, and 3 of this document **have all been adopted and landed by concurrent threads**.

- **Issue 1 (update pointer-typed field shallow copy + erroneous release) fixed**: the `.update` branch now first checks `lowering_rules.structFieldIsPointerBacked(plan.field_ty)`; pointer-typed untouched fields explicitly return `UnsupportedSabDirectFeature`; the release condition is changed to the shared `plan.release_loaded and !isLocalReg(loaded)`, aligned with SA-text's `callArgNeedsRelease(update_expr)`. The unconditional erroneous release is eliminated.
- **Issue 2 (missing explicit copy-struct deep copy) fixed**: the `.explicit` branch adds a `value.* == .identifier and typeIsCopyStruct(plan.field_ty)` branch, doing a `genCopyValue` deep copy before store, aligned with SA-text's `genCopyValueInto`.
- **Issue 3 (ownership strategy converged into the shared plan) landed**: `StructLiteralFieldPlan` adds two fields, `field_ty: *const ast.Type` and `release_loaded: bool`; `planStructLiteralField` fills them (explicit → `release_loaded=false`; update → `release_loaded=callArgNeedsRelease(update_expr)`). A shared `structFieldIsPointerBacked` was added. `lowering_rules.zig` gained unit tests covering `field_ty`/`release_loaded`.
- **Issue 4 (union/ManuallyDrop) remains explicitly unsupported**: the entry point still has `if (decl.is_opaque or decl.is_union) return UnsupportedSabDirectFeature;`, which is safe.

**Verification gates actually run (dev mode)**:

- `zig build --summary all` passes.
- `zig build test --summary all`: **61/61 passing** (up from a baseline of 60/60, +1, the new shared-plan unit test is effective).
- `SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_struct_update.sla --test-backend sab`: **2/2 passing**.
- SA-text parity `--test-backend sa`: **2/2 passing**.
- Guard regressions: `test_unit_sets` (BTreeSet) 2/2, `parallel.sla` 1/1 passing.

**Assessment**:

1. The three core fixes are in place and correctly directed (going through the shared `StructLiteralFieldPlan`, not copying SA-text branches into SAB). The scalar scenario can serve as a completion regression.
2. **Still "scalar-subset completion"**: pointer-typed untouched fields are "explicitly narrowed to unsupported" rather than deep-copy/move implemented. Per the `tasks.md` principle, this slice should not be recorded as Y/shared 100%; a Phase 5 to-do fixture with `Vec`/`String`/nested-struct untouched fields must be left in `tasks.md`. **Recommended next step: add a negative fixture of this form to verify "explicit failure" rather than silent aliasing.**
3. **To be confirmed (not run in this round)**: whether the full dev no-fallback sweep has gone 62/69 → 63/69; `git diff --check`; whether docs (`progress.md`/`tasks.md`/`current_plan.md`) have synced this Completed Slice Evidence. These should be run by the implementing thread before the wrap-up commit.
4. **Observation point**: `structFieldIsPointerBacked` highly overlaps in semantics with another similar determination in `lowering_rules.zig` (an older grep once showed repeated branches over `.pointer/.borrow/.user_defined/.tuple/.array`); recommend merging into a single helper later to avoid drift between two places.

### Inspection Log (Addendum)

- Time point: tracking-file synchronization check.
- Measurement: full dev-mode no-fallback sweep = **63/69** (struct_update is in the passing set, no regressions), with 6 remaining failures: async_await / derive_semantics / enum_match / for_in_protocol / generic_for_in_protocol / spaceship_cmp.
- Sync actions: concurrent threads updated `progress.md` and `current_plan.md` (both 63/69, Next Slice = enum_match), but `tasks.md` was still at 62/69. The current-state references in `tasks.md` were synced from 62/69 to 63/69: recovery point, Completed-slice entry, Remaining Failure Ownership Matrix title and struct_update checkmark, Phase 5 target failures, Phase 9 drive-from target, CN historical matrix pointer, Slice 5A all updated. The historical ledger (the Set slice's 62/69, earlier historical snapshots) was left unchanged.
- New explicit to-do: a separate "pointer-backed struct-update fields" task was added to the Phase 5 section, with a negative-fixture requirement for `Vec`/`String`/nested-struct untouched fields, serving as the landing point for multiple references.
- Honesty reminder: struct_update is currently **scalar-subset completion** — pointer-typed untouched fields are explicitly narrowed via `UnsupportedSabDirectFeature`, not a complete implementation; the figures Y/shared-lowering ~80% and fallback-removal ~93% are consistently annotated with this caveat in all three files.
- `git diff --check` is clean.

## Pre-Assessment of the Next Slice: `test_unit_enum_match.sla` (Phase 5, Assessment Only, No Code Changed)

Assessment time: 2026-07-01. This section is a static pre-assessment of the next active slice, for the implementing thread's reference; I changed no code.

### The First Gap Reproduced

Command:
```
SA_PLUGIN_DEV=1 SLA_SAB_TRACE_UNSUPPORTED=1 SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_enum_match.sla --test-backend sab --jobs 1 --trace-panic
```
First failure:
```
[sab-direct] stmt match_stmt failed: UnsupportedSabDirectFeature
[sab-direct] func process_msg block failed: UnsupportedSabDirectFeature
```
That is, direct SAB has no lowering at all for `match` statements/expressions and payload-carrying `enum`s (`sab_codegen.zig` has no match/enum handling branches).

### Fixture Form

- `enum Message { Quit, Move { x: int, y: int } }` — a unit variant + a variant with named-field payload.
- `Message::Move { x: 10, y: 20 }` / `Message::Quit` — enum literal construction (`ast.EnumLiteral`).
- `match msg { Message::Quit => {...}, Message::Move { x, y } => {...} }` — a match statement, each case being a `return` (all branches terminate, so it is a void-match with no value merge).

So this fixture is the **minimal subset of enum + match**: no guards, no value-producing match, no Option/Result specialization paths.

### SA-Text Reference Implementation (Already Present, as a Y Counterpart)

`src/codegen.zig` already has a complete implementation; SAB should align with its semantics (not copy the text):

- Layout helpers (around lines 2530-2584):
  - `enumVariantIndex` — variant → tag ordinal.
  - `enumVariant` / `enumFieldLayout` — payload field layout, **payload starts at offset 8** (the first 8 bytes are the i64 tag), fields accumulate with size alignment.
  - `enumSize` — `max(8 + max_payload, 8)`, tag(8) + largest variant payload.
- enum literal construction: alloc `enumSize`, `store base+0 = tag(i64)`, `store base+offset` for each field.
- match lowering (`genMatchExpr`, lines 7781-7891):
  - `load val+0 as i64` to get the tag → `eq` with each case's tag constant → `br cond -> case_i, next` conditional-branch ladder.
  - Inside a case body, `load` payload fields into bindings according to `enumFieldLayout`.
  - No match at all falls through to `no_match_label: panic(1)`.
  - value-producing match converges via `result_slot` alloc + `genBlockTailValueStore` + merge label; this fixture is a void-match and goes through `genBlock`.
  - Branch cleanup: non-terminating cases release bindings not consumed by the body at the end; guard-failure paths release the guard and bindings.

### Recommended Y-Shared Placement

Per the `tasks.md` Phase 5 boundary (enum tag/payload layout, match extraction, branch cleanup, and value merge belong to shared rules; SAB only emits structured compare/branch from the plan), recommend:

1. **Shared layout rules into `src/lowering_rules.zig`**: extract `enumVariantIndex`, `enumVariant`, `enumFieldLayout` (the payload-base=8 offset rule), and `enumAbiSize` as shared functions consumed by both SA-text and SAB — consistent with the already-completed sharing of struct/tuple/array ABI. Note the existing SA-text `enumFieldLayout` uses `typeSize`/`alignOffset` (already `lowering_rules`' `abiTypeSize`/`alignAggregateOffset`), so migration cost is low.
2. **Shared match plan**: define an `EnumMatchPlan` (or a list of `MatchCasePlan`), recording each case's tag, payload bindings' `{offset, prim, name}`, whether it terminates, whether it is value-producing, and whether it has a guard. Both SA-text and SAB emit from this plan, avoiding SAB writing another tag/offset determination.
3. **SAB tail**: implement using the existing structured primitives — `emitLoad(tag, val, 0, .i64)` → `emitOp(.eq)` → `.br` instruction → payload `emitLoad` into binding registers → case body `genBlock`/`genScopedBlock` (reusing the already-completed branch scoping snapshot/restore, see the `var_comprehensive` slice) → no-match `emitPanicCode(1)`. Value-match uses an alloc slot + tail-store + merge (reusing the SAB-version idea of `genBlockTailValueStore`).
4. **enum literal construction**: SAB `genEnumLiteral` — alloc `enumAbiSize`, `emitStore(base,0,tag,.i64)`, `emitStore(base,offset,val,prim)` for each field, isomorphic to `genStructLiteral`.

### Step-by-Step Implementation Suggestions (for the Implementing Thread)

- First do enum literal construction + unit/payload variant layout (no match), adding a minimal fixture to verify `Message::Move{...}` can alloc/store.
- Then do void-match (the form of this fixture: all `return` branches), tag ladder + payload extraction + panic fallback.
- value-producing match and guards come as the immediately following increment (not needed by the `enum_match` fixture, but the Phase 5 completion rule requires SA-text/SAB consistency on value merge; if this slice only does void-match, an explicit value-match/guard to-do must be recorded in tasks.md).

### Recommended Verification Gates (After Implementation)

- Classification: the `SLA_SAB_TRACE_UNSUPPORTED=1` command above confirms the gap disappears item by item.
- Focus: `SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_enum_match.sla --test-backend sab --jobs 1 --trace-panic` (should be 2/2).
- SA-text parity: same fixture with `--test-backend sa` (should be 2/2).
- Completion guard regressions: `struct_update`, `sets`, `rc_dyn_trait`, `var_comprehensive`, assignment cleanup, `pkgjson`, RefCell, trait static dispatch, `/home/vscode/projects/sla_ecs/lib/parallel.sla`.
- `zig test src/lowering_rules.zig` (add unit tests if new shared enum layout/match plan is introduced), `zig build test`, full dev sweep (expected 63/69 → 64/69), `sa plugin install --dev .`, `SA_PLUGIN_DEV=1 sa sla help`, disasm guard (match produces no calls, can be skipped but recommended to run once), `git diff --check`, docs sync.

### Connection to Subsequent Slices

The shared enum layout rules established by `enum_match` will be reused by `derive_semantics` (`@derive`-generated eq/ord/hash/debug need to traverse enum/struct layouts) and `spaceship_cmp` (derived ord compares field-by-field / variant-by-variant), so it is recommended to follow the order in the document's "Next-Step Plan": `enum_match` → `derive_semantics` → `spaceship_cmp` to close out Phase 5.

### Inspection Log 2026-07-01 (Final Round, Inspection Task Stopped)

This round detected that the struct_update implementation changes have landed in the workspace (uncommitted): `src/lowering_rules.zig` +32, `src/sab_codegen.zig` +109. Line-by-line check conclusions:

- Issue 1 (update pointer-typed field shallow copy + erroneous release): **fixed**. The `.update` branch now first checks `structFieldIsPointerBacked(plan.field_ty)`; pointer-typed untouched fields explicitly return `UnsupportedSabDirectFeature` (no more aliasing load/store); scalar fields' `loaded` is released only when `plan.release_loaded and !isLocalReg(loaded)`, aligned with SA-text's `callArgNeedsRelease(update_expr)`. The erroneous release is eliminated.
- Issue 2 (missing explicit copy-struct deep copy): **fixed**. The `.explicit` branch does a `genCopyValue` deep copy for `value.* == .identifier and typeIsCopyStruct(plan.field_ty)`, consistent with SA-text's `genCopyValueInto`.
- Issue 3 (ownership converged into the shared plan): **landed**. `StructLiteralFieldPlan` adds `field_ty` and `release_loaded` (with doc comments); `planStructLiteralField` fills both fields under both sources; a shared `structFieldIsPointerBacked` was added. The unit test `shared struct literal update field plan` added assertions for `field_ty`/`release_loaded`/`structFieldIsPointerBacked`.
- Coverage: **both** emitters, `genStructLiteral` and `genMacroStructLiteral`, were converted to consume the shared plan, with macro contexts materialized via `genMacroExpr`; no branch was missed.

No new divergence, no sign of regression. This round actually ran: `zig build --summary all` passes; `zig test src/lowering_rules.zig` 9/9.

Honesty reminder (maintained): this is **scalar-subset completion** — pointer-typed untouched fields are explicitly narrowed to unsupported, not fully implemented; tasks.md has a separate Phase 5 pointer-backed struct-update to-do tracking it. All three tracking files show 63/69, Y/shared ~80%, fallback-removal ~93%, with this caveat and no exaggeration.

The scheduled inspection task (`4913a146`) has been stopped as instructed. Future inspections will be performed manually on demand.
