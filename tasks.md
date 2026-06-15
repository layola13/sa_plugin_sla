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
  - [x] Compiles `.sla` → `.test.sa` temp file.
  - [x] Spawns `sa test <file.test.sa>` subprocess forwarding all extra args.
  - [x] Skill entry added: `sla test <file> [sa-test-options...]`.
- [x] **Example test files**
  - [x] `tests/test_unit_basic.sla` — add/factorial/counter/ignored tests.
  - [x] `tests/test_unit_panic.sla` — `should_panic` and `ignored+should_panic`.
  - [x] `tests/test_unit_generics.sla` — `Option<T>` generics inside `@test`.
