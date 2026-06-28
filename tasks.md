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
  - [x] Add focused tests for direct SAB output, managed cache behavior, SAB magic, decoded instructions, and no generated `.sa` side output.
  - [x] Add direct-only regression tests (`allow_fallback = false`) so new direct SAB features cannot silently pass through the SA-compatible fallback path.
  - [x] Add direct SAB lowering for plain struct literals, field access, struct returns, resolved call symbols, and multi-argument function calls.
  - [x] Add a dev/debug no-fallback gate (`SLA_SAB_NO_FALLBACK=1`) so direct SAB gaps fail loudly instead of hiding behind the compatibility encoder.
  - [x] Move the first std surface lowering path into generic import metadata / macro-fragment lowering so direct SAB can consume std macros without hardcoding ordinary library logic in Zig.
  - [ ] Extend the std surface metadata format beyond the current associated/method/index macro bridge, still without adding compiler branches for `Vec`, `thread`, ECS, or other library names.
  - [ ] Add generic closure/function-object direct lowering before enabling no-fallback thread-spawn style cases; do not copy the legacy text backend's `thread`-specific lowering into `sab_codegen.zig`.
  - [ ] Remove the remaining in-memory SA-compatible fallback from the normal SAB path by replacing std/macro/closure gaps with generic direct SAB lowering or a generic SAB macro representation, not library-name special cases.
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
