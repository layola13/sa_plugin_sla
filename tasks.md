# Sla Compiler Implementation Tasks

This document tracks the tasks and implementation progress of the Sla compiler plugin (`sa_plugin_sla`).

---

## Task List

### 1. Lexer & Parser Updates
- [x] **Postfix `?` Operator Support**
  - [x] Add `?` token tag to `src/lexer.zig`.
  - [x] Update `lexer.zig` scanner to scan postfix `?` token.
  - [x] Update `src/parser.zig` to parse postfix `?` operator.
- [x] **Generic Struct Literal Support**
  - [x] Parse `Type<T> { field: value }` without adding any new keyword.
  - [x] Keep source cleanup implicit; no `drop` keyword or `drop()` function is introduced.

### 2. Type Checker & Symbol Resolver (Semantic Analyzer)
- [x] **Scope Builder & Symbol Table**
  - [x] Implement nested block scope stack.
  - [x] Track local variable declarations, parameter bindings, and constant values.
- [x] **Type Resolver**
  - [x] Parse and resolve primitive types (`int`, `float`, `bool`, `void`, `ptr`).
  - [x] Bind user-defined structs.
  - [x] Register signatures from FFI contract parser (`.sai`/`.sal`).
- [x] **Borrow Checker & Ownership Validator**
  - [x] Track variable ownership states (`Active` vs `Consumed`).
  - [x] Check move semantics (`^` transfer) and reject use-after-move.
  - [x] Validate borrow rules (`&` reference) and forbid mutable/immutable aliasing conflicts.

### 3. Monomorphization Engine
- [x] **Generic Collection & Instantiation**
  - [x] Traverse the AST to gather all generic struct instantiations and generic function calls.
  - [x] Map generic type parameters (like `T`) to concrete types (like `int`).
  - [x] Generate specialized non-generic structs and functions (e.g. `Option_int_Layout`, `unwrap_or_int`).

### 4. AST to SA Lowerer (Code Generation)
- [x] **Control Flow Flattener**
  - [x] Lower `if/else` conditional expressions into flat, conditional jumps with automated register cleanups before merge targets (preventing `PhiStateConflict`).
  - [x] Lower `switch` pattern matching expressions to flat conditional equality ladders.
- [x] **Hygienic Macro Expander**
  - [x] Perform compile-time Alpha-conversion (renaming local macro variables to globally unique names).
  - [x] Lower `macro` definitions and calls directly to SA's `[MACRO]` / `EXPAND` preprocessor statements.
- [x] **Scope Lifetime Auto-Cleanup Generator**
  - [x] Track active resources at block exits.
  - [x] Automatically inject SA `!reg` cleanup before scope endings so user `.sla` code does not need explicit releases.
- [x] **Loop Allocation Hoister**
  - [x] Detect `stack_alloc` statements inside `for` loops.
  - [x] Hoist allocations outside and before the loop label, reusing memory inside the loop body.
- [x] **Postfix `?` Unwrapper**
  - [x] Lower `expr?` into a conditional error check, injecting automated local variable cleanups and an early `return Err(^err)` on error branch.
- [x] **Struct Literal Lowering**
  - [x] Lower Sla struct literals to flat SA `alloc N` plus `store base+offset` instructions.
  - [x] Keep struct layouts as compile-time Sla metadata instead of emitting forbidden `#struct { ... }` brace syntax into `.sa`.

### 5. Integration & CLI Build Command
- [x] **Code Output Writer**
  - [x] Output compiled `.sa` files; Sla-owned struct layouts stay as compile-time metadata.
  - [x] Connect Lexer -> Parser -> Type Checker -> Monomorphizer -> Codegen -> Output in `src/plugin.zig`.
- [x] **Direct SAB Output Mainline**
  - [x] Add `src/sab_codegen.zig` as a direct SLA AST/type-checker to SAB backend, separate from `.sa` text codegen.
  - [x] Keep `sla -> .sa` and `sla -> .sab` as two independent mainlines; SAB generation does not call `compileSlaToSaString` or the SA text flattener.
  - [x] Confirm the SA compiler dependency from `https://github.com/layola13/sci/` is documented and installed before plugin development/verification.
  - [x] Confirm SA host `.sab` input support is used by `sa sla build-exe` and `sa sla sab workspace` via managed `.sla-cache/sab/...` paths.
  - [x] Add `sa sla sab build` / `sa slab build` support with default managed output under `.sla-cache/sab/`.
  - [x] Support optional visible SAB artifacts through `--out/-o` for `sab build`.
  - [x] Add `sa sla sab workspace` / `sa slab workspace` support with workspace package resolution, managed `.sla-cache/sab/` input for `sa build-exe`, and optional `--sab-out` / `--emit-sab` artifacts.
  - [x] Preserve `sa sla sab disasm` as a debug-only reader for SAB files.
  - [x] Make `sa sla test` default to `--test-backend auto`, writing managed SAB under `.sla-cache/sab/` and invoking `sa test` on SAB by default; the legacy `.test.sa` path is now only used by explicit `--test-backend sa`.
  - [x] Add `--test-backend sab` for explicit SAB artifact verification with no legacy `.sa` backend fallback, and `--test-backend sa` for explicit legacy `.sa` text tests.
  - [x] Add an in-memory SA-compatible SAB encoder fallback inside the SAB mainline so SA features not yet covered by direct AST-to-SAB codegen still produce `.sab` output without writing `.sa` text.
  - [x] Confirm SCI SAB v4 metadata support preserves structured operands, atomic operand text, native register names, package identity, upstream locations, and verified function register ids needed by SA backends without storing per-instruction raw `.sa` text.
  - [x] Add SCI regression coverage for v4 no-raw-text SAB decode, all `InstKind` / `OpKind` / operand tags, structured call parsing, and LLVM lowering of localized const vtable slots.
  - [x] Add direct SAB lowering for language-level function pointer values, including vtable const declarations, borrowed function values, parameter passing, generic function specializations, and `call_indirect`.
  - [ ] Optimize SLA-to-SAB generation time; current SA backend compile from `.sab` is faster than raw `.sa`, but `sa sla sab build` still spends extra time in SA-compatible flatten/verify/encode and cache writes.
  - [x] Cache the resolved `sa_std` root inside each direct SAB codegen instance so repeated std macro fragments do not repeat filesystem root probing.
  - [x] Cache decoded std import modules inside each direct SAB codegen instance so dependency preloading for multiple rules from the same `sa_std` import path does not repeat full SCI flatten/encode/decode work.
  - [x] Cache reusable identifier-only std macro templates inside each direct SAB codegen instance so repeated Option/Result-style macro fragments reuse decoded structured SAB bodies with placeholder substitution.
  - [x] Add focused tests for direct SAB output, managed cache behavior, SAB magic, decoded instructions, and no generated `.sa` side output.
  - [x] Add direct-only regression tests (`allow_fallback = false`) so new direct SAB features cannot silently pass through the SA-compatible fallback path.
  - [x] Add direct SAB lowering for plain struct literals, field access, struct returns, resolved call symbols, and multi-argument function calls.
  - [x] Add a dev/debug no-fallback gate (`SLA_SAB_NO_FALLBACK=1`) so direct SAB gaps fail loudly instead of hiding behind the compatibility encoder.
  - [x] Add direct SAB lowering for ordinary closure bindings and closure calls, including captured outer locals and one/two-parameter inline closure bodies.
  - [x] Add direct SAB lowering for Phase 1 scalar `var` slots, identifier assignment, stack-slot load/store, and basic `while` loops.
  - [x] Fix direct SAB branch-condition cleanup so temporary conditions are released on each branch while local/parameter conditions remain active.
  - [x] Add direct SAB lowering for tuple literals, tuple field access, and tuple destructuring, including direct-only regression coverage.
  - [x] Add direct SAB lowering for fixed array literals, repeat literals, and literal index reads/writes for focused scalar arrays, including direct-only regression coverage.
  - [x] Add direct SAB lowering for dynamic fixed-array index reads/writes and basic numeric range `for` loops, including direct-only regression coverage and no-fallback coverage for `tests/test_unit_arrays.sla`.
  - [x] Add direct SAB lowering for scalar value-producing `if` expressions, typed `if` bindings, nested branch assignments, and f32/f64 arithmetic/comparison op selection.
  - [x] Add parser and direct SAB lowering for boolean `&&` / `||` expressions, including dev-plugin no-fallback verification.
  - [x] Add direct SAB lowering for primitive numeric `as` casts, including structured conversion op operands and dev-plugin no-fallback verification.
  - [x] Add direct SAB lowering for scalar borrow/deref and non-void tail-expression returns, including direct-only regression coverage.
  - [x] Extend direct SAB borrow lowering to addressable field/deref/index sources, covering postfix-under-prefix precedence such as `&item.value` and `&*value` without fallback.
  - [x] Add direct SAB lowering for move-prefixed call arguments, including type-checker single-consumption handling and dev-plugin no-fallback verification.
  - [x] Add direct SAB inline expansion for focused user `macro` calls with hygienic macro-local renaming and caller-scope argument substitution.
  - [x] Extend direct SAB user macro expansion through nested control flow, ordinary/nested macro calls, casts, aggregate literals, tuple destructuring, index access/assignment, and block-scoped hygienic shadowing.
  - [x] Add direct SAB `stack_alloc()` lowering and raw stack-allocation lifetime tracking.
  - [x] Move the first std surface lowering path into generic import metadata / macro-fragment lowering so direct SAB can consume std macros without hardcoding ordinary library logic in Zig.
  - [x] Extend the std surface metadata format beyond the current associated/method/index macro bridge, still without adding compiler branches for `Vec`, `thread`, ECS, or other library names.
  - [x] Add generic fallible std surface macro metadata with explicit ok/output slots and panic-on-false lowering, covering `Vec.remove` without a `Vec.remove` compiler branch.
  - [x] Add generic std surface constructor metadata and result-valued method metadata, covering focused `Option` `Some`/`None` construction plus `is_some`/`is_none` without `Option` compiler branches.
  - [x] Preserve const-bearing std macro fragments in direct SAB lowering, including structured `panic_msg` operands and focused `Option.unwrap()` coverage without `Option` compiler branches.
  - [x] Add focused direct SAB metadata coverage for `Option.unwrap_or`, including no-fallback Some/None branch regression coverage without `Option` compiler branches.
  - [x] Add focused direct SAB metadata coverage for `Result` `Ok`/`Err` construction plus `is_ok`/`is_err`/`unwrap`/`unwrap_or`, including no-fallback regression coverage without `Result` compiler branches.
  - [x] Start the Y-shaped shared lowering-rules path instead of growing independent SA-text and SAB semantic branches.
    - Progress: `src/lowering_rules.zig` now owns shared derive-name matching, struct derive lookup, ordinary static-call target resolution, and call-argument prefix rules used by both `codegen.zig` and `sab_codegen.zig`.
    - Progress: `lowering_rules.StaticCallPlan` now feeds resolved/static call target selection in both emitters, and `prefixedIdentifierCallArg` owns the shared `&name` / `^name` spelling rule for SA text call arguments.
    - Progress: release classification and parameter-aware auto-borrow predicates now live in shared lowering rules, with the SA text emitter delegating to them.
    - Progress: `CallArgMaterializationPlan` now represents array-to-slice borrow, auto-borrow, copy-struct value, ordinary value, and release decisions for resolved static-call arguments, and the SA text resolved-call path consumes it.
    - Progress: resolved static-call dyn borrow arguments now materialize through the shared plan by creating a fat pointer, passing `&fat_reg`, and releasing the fat pointer after the call.
    - Progress: legacy `genCallArgForParam` now delegates copy/value/release decisions to the shared materialization plan.
    - Progress: ordinary function/extern expression-call fallback now consumes the shared materialization helper for array-to-slice borrow, dyn fat-pointer borrow, receiver-style auto-borrow, copy/value, generated-identifier, and release decisions.
    - Progress: remaining SA text legacy method/statement call branches now consume the shared materialization helper, with statement-receiver borrow passthrough captured as a shared predicate.
    - Progress: direct SAB ordinary static calls now consume the shared materialization plan for value arguments, parameter-aware auto-borrow, generated identifier classification, and temporary release selection while leaving unsupported array/dyn/copy SAB materializations explicit.
    - Progress estimate: the first shared-rules extraction, static-call plan, call-materialization predicate, resolved-call materialization-plan, resolved-call dyn borrow, legacy helper adoption, ordinary function/extern expression-call adoption, remaining SA text legacy method/statement adoption, and SAB ordinary static-call adoption slices are 100%; the broader Y/shared-lowering track is approximately 36%.
    - Constraint: do not implement high-level language/library semantics only in `sab_codegen.zig`; future direct SAB work should extend shared rules/plans or std surface metadata so SA text and SAB emitters converge through the shared contract.
  - [x] Fix thread-closure SAB call lowering so captured-argument calls keep a pure call target symbol instead of generating illegal `@func(arg)` call text; reproduce with `/home/vscode/projects/sla_ecs/lib/parallel.sla`.
    - Note: the original fallback `parallel.sla` ForbiddenSyntax repro is unblocked in the updated SCI host by accepting fallback-generated single-operand structured `panic_msg` in SAB v4 decode/verify.
    - Progress: direct no-fallback lowers the focused escaped thread closure case `thread::spawn(^|| f(value))` where `f` is a captured function-pointer callee, using generated vtable/spawn-wrapper/worker entries and structured `call_indirect` inside the worker.
    - Progress: the full `SLA_SAB_NO_FALLBACK=1 ... /home/vscode/projects/sla_ecs/lib/parallel.sla` path now passes after expanding std-dependency preloading and moving typed `Vec<T>` index reads to std surface metadata.
    - Progress estimate: 100% for the reported illegal call-target blocker.
    - Verified with `SLA_SAB_NO_FALLBACK=1 SLA_PROFILE=1 timeout 180s ./zig-out/bin/sla-local-cli sla test /home/vscode/projects/sla_ecs/lib/parallel.sla --test-backend sab --jobs 1 --trace-panic`.
  - [x] Replace the temporary direct `Vec<T>` index ABI lowering with typed std surface metadata/macro lowering once `sa_std` exposes typed element-load slice/vec macros.
    - Progress: `sla_std/std_surface.sla_meta` uses `VEC_GET_TYPED_{elem_ty}`, direct SAB carries `StdSurfaceArgKind.elem_ty`, `elementLoadType`, and `stdSurfaceMacroName`, and concrete typed Vec/Slice macros provide the element-width-specific loads.
    - Progress estimate: 100%; `genIndex` now uses the generic std surface rule for Vec indexing instead of a direct Vec ABI branch.
  - [ ] Add generic exported closure/function-object entry lowering before enabling no-fallback thread-spawn style cases; do not copy the legacy text backend's `thread`-specific lowering into `sab_codegen.zig`.
    - Progress: first direct entry model is in place for zero-arg escaped thread closures, including capture collection, slot materialization, vtable const emission, worker emission, and FFI spawn wrapper emission. General exported closure/function-object lowering beyond this focused consumer remains open.
  - [ ] Remove the remaining in-memory SA-compatible fallback from the normal SAB path by replacing std/macro/closure gaps with generic direct SAB lowering or a generic SAB macro representation, not library-name special cases.
    - Progress estimate: approximately 72% overall direct SAB fallback removal; next priority is a shared call/materialization plan contract so both emitters reuse lowering decisions.
  - [ ] Expand the shared static-call plan into a full call/materialization plan, including parameter-aware auto-borrow, array-to-slice borrow, dyn fat-pointer borrow, temp release policy, and result destination contract shared by SA text and SAB emitters.
    - Progress: shared release policy, auto-borrow predicates, resolved static-call argument materialization, resolved static-call dyn fat-pointer borrow materialization, SA text legacy call array/dyn/materialization adoption, and SAB ordinary static-call value/auto-borrow consumption are in place; remaining pieces are explicit result destination planning, SAB macro-call consumption of the richer plan, and direct SAB materialization for array/dyn/copy kinds.
- [x] **SLA CLI Project Helpers**
  - [x] Add `sa sla init [path]` to scaffold a minimal SLA binary project without overwriting existing files.
  - [x] Add `sa sla skills [--json]` to list plugin capabilities and generate Codex/Claude agent skill files in text mode.
  - [x] Include `sla init` and `sla skills` in plugin skill descriptors and `sa sla help` / per-command help output.
  - [x] Verify host-dispatched `SA_PLUGIN_DEV=1 sa sla skills --json` returns JSON, not text output.
  - [x] Add focused command tests for skills JSON, agent skill generation, and init overwrite protection.
- [x] **SA std imports**
  - [x] Parse top-level `@import "..."` declarations without adding new keywords.
  - [x] Preserve direct `sa_std/...` imports in generated SA.
  - [x] Load imported `.sai` and `.sal` contracts before type checking so std externs resolve in Sla.
  - [x] Resolve `sa_std/...` contracts from `SA_STD_DIR` or `$HOME/projects/sci/sa_std` during Sla type checking.

### 6. Edge Cases & Validation
- [x] **Internal Function Calls**
  - [x] Correctly compile internal Sla calls to native SA `@call` instructions instead of macro expansions.
- [x] **Recursive Loop Allocation Hoisting**
  - [x] Traverses nested loops and conditional branches inside loops recursively to hoist all stack allocations.
- [x] **Hygienic Macro Variable Renaming**
  - [x] Tracks all declared macro-local variables and maps references to their unique mangled names during codegen.
- [x] **Block vs Return Cleanup Resolution**
  - [x] Excludes returned variables from early return cleanup lists, and prevents block-level exit cleanups from overriding return statement cleanup actions.

### 7. Unit Tests & Build Automation
- [x] **Integrated build test Step**
  - [x] Added `zig build test` target in `build.zig` to compile and run all unit tests automatically.
- [x] **Monomorphizer Unit Test**
  - [x] Implemented in `src/monomorphizer.zig` to verify specialization of generic types.
- [x] **Codegen Unit Test**
  - [x] Implemented in `src/codegen.zig` to verify translation of binary expressions and return statements to SA.

### 8. Sla Unit Test Framework (`@test`)
- [x] **Lexer: `@` token + comparison operators**
  - [x] `at` token tag for `@` symbol (no new keyword).
  - [x] `==`, `!=`, `<=`, `>=` two-char token tags added to lexer.
- [x] **AST: `TestDecl` node**
  - [x] `TestDecl` struct in `src/ast.zig`: `name`, `is_ignored`, `should_panic`, `body`.
  - [x] `test_decl: TestDecl` variant added to `Node` union.
- [x] **Parser: `@test` declaration parsing**
  - [x] Parses `@test [ignored] [should_panic] "name"() { ... }` syntax.
  - [x] No new keywords consumed — `ignored` and `should_panic` are identifiers.
  - [x] New comparison ops (`==`, `!=`, `<=`, `>=`) parsed in `parseInfixExpr`.
- [x] **Type Checker: `checkTest`**
  - [x] Type checks test body as void-returning, no-parameter block.
  - [x] `panic()` recognized as built-in void intrinsic.
  - [x] `if` condition accepts integer comparisons (0/1) in addition to booleans.
- [x] **Monomorphizer: `test_decl` traversal**
  - [x] Specializes generic calls inside test bodies.
- [x] **Codegen: `genTestDecl`**
  - [x] Emits `@test [ignored] [should_panic] "name"():` SA header.
  - [x] Unique entry labels per test (`L_TEST_ENTRY_N`).
  - [x] `panic(code)` lowered to SA `panic(code)` syntax.
  - [x] Loop allocation hoisting works inside test bodies.
- [x] **CLI: `sa sla test <file.sla> [options]`**
  - [x] Defaults to `--test-backend auto`, compiling `.sla` to managed SAB under `.sla-cache/sab/` and spawning `sa test <file.sab>`.
  - [x] Supports `--test-backend sab` for explicit SAB output and `--test-backend sa` for the legacy `.sla` -> `.test.sa` temp file path.
  - [x] Strips plugin-only `--test-backend` before forwarding remaining args to `sa test`.
  - [x] Applies `--filter` pruning before monomorphization/type checking on both SAB and SA test paths to keep focused tests small.
  - [x] Skill entry added: `sla test <file> [--test-backend auto|sab|sa] [sa-test-options...]`.
- [x] **Example test files**
  - [x] `tests/test_unit_basic.sla` — add/factorial/counter/ignored tests.
  - [x] `tests/test_unit_panic.sla` — `should_panic` and `ignored+should_panic`.
  - [x] `tests/test_unit_generics.sla` — `Option<T>` generics inside `@test`.
