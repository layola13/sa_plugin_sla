# SLA/SA Compilation Optimization and Modular Compilation Design Document

> This is the English counterpart of the Chinese document [SLA/SA 编译优化与模块化编译设计文档](./compilation_optimization_cn.md).

## 1. Background and Current Status

While refactoring Lua 5.5 in the SLA assembly language, because the Lua virtual machine (such as `lvm.sla`) and parser (such as `lparser.sla`) contain a large number of constant array initializations (for example, instruction buffers and static tables of length 16384), early versions of the SA compiler encountered severe compilation-speed bottlenecks (compilation times exceeding 5 minutes, even causing the terminal to hang/timeout).

To address these compilation performance bottlenecks, we optimized the compiler core and the compilation architecture.

---

## 2. Implemented Compiler Core Optimization: Large Array Initialization Optimization (Array-Filling Optimization)

### 2.1 Bottleneck Cause Analysis

In the LLVM code generation module of the `sci` compiler (`src/emit_llvm_llvmc.zig`), for large constant arrays (such as byte arrays initialized to all zeros), the compiler originally generated initialization instructions element by element or produced a huge LLVM constant tree. This caused LLVM to consume enormous memory and CPU time during constant folding and instruction selection.

### 2.2 Solution

We introduced a dedicated optimization for `.repeat` repeated constants in the `sci` compiler's LLVM constant generation:
- Added a `.repeat` branch to the constant representation; when large-scale repeated default values are detected (such as a `u8` array of all `0`s), it is represented as a single repeated block.
- In the `fillConstBytes` stage, directly use Zig's high-performance `@memset` to fill the target byte stream:
  ```zig
  .repeat => |literal| @memset(out, literal.repeat_byte orelse 0),
  ```
- This emits efficient LLVM aggregate constants directly, avoiding the instruction overhead of element-by-element generation.

### 2.3 Optimization Results

- The clean-refactor compile time for `lvm.test.sa`, which contains large instruction arrays, dropped from **>5 minutes** to **~4.6 seconds**.
- Compilation of `lparser.test.sa`, which contains complex AST and Lexer state, dropped to **~6.6 seconds**.
- Resolved the hangs in unit tests and incremental compilation.

---

## 3. Next-Step Optimization Design: Modular Separate Compilation (Distributed Compilation)

Although the core optimization greatly shortened compilation time, because the SLA compiler currently uses an "all-expansion merge" mode (All-in-One) for `@import`, the final generated single `.sa` file has too many lines (for example, a single expanded `lua_sla` is close to 7000 lines, while `lparser.sa` reaches 1.72 MB, containing more than 46000 SA instructions). This places enormous compilation pressure on the SA compiler and on the backend verifier (Referee).

### 3.1 Core Design Approach

Do not expand and merge all `.sla` code into one giant `.sa`. Instead, generate a corresponding `.sa` file for each module following the original `.sla` module distribution, then use `@import` statements for modular references. This way `main.sa` will be very small, and each module can be compiled and cached independently.

### 3.2 Detailed Design Steps

#### A. Type Checking and Monomorphization Phase (Maintaining a Global View)

To support generic specialization and type-safety verification, the SLA compiler still needs complete dependency type information in the frontend:
- When compiling the main module `a.sla`, the Type Checker still parses its dependency `b.sla`, but only loads the structs and function signatures (as well as exported macro definitions) from `b.sla` into the symbol table; its function bodies do not participate in the type checking of `a.sla`.
- If cross-module generic function calls are involved (such as a generic `fn foo<T>()` defined in `b.sla` being called as `foo<int>()` in `a.sla`), the main module's `Monomorphizer` generates the corresponding instantiated version (such as `foo_int`) after type checking, and attaches it to the main module's generation tree as a specialized function.

#### B. Code Generation Phase (Modular Output)

- When outputting SA code, Codegen generates SA assembly only for functions and structs defined within the main module (`a.sla`), as well as for generic functions specialized within it.
- Convert `@import "b.sla"` into a reference pointing to its generated `.sa` file, for example `@import "b.sa"`.
- No longer copy the function bodies and data structure code from `b.sla` into `a.sa`.

#### C. Compilation and Linking Phase (Leveraging SA's Native @import Mechanism)

- By emitting `@import "b.sa"`, directly reuse the SA compiler's native cross-module import and linker functionality.
- When running `sa build a.sa`, the SA compiler automatically locates and links `b.sa`, with the SA native toolchain handling address binding of cross-file symbols.

---

## 4. Optimization Progress and Deliverables

1. **CLI Startup and File-Loading FFI Integration**:
   - Fixed the register redefinition and `uge` comparison syntax errors in `sa_lua/src/args_helper.sa`, and passed `sa build` static type verification.
   - Successfully integrated `args_helper.sa`'s command-line argument retrieval `get_cli_arg_1` and file-reading `read_file_to_string` interfaces into `lua.sla` via an `extern` block.
   - The compiled executable `lua_sla_bin` can now correctly parse command-line arguments and load real `.lua` scripts (such as `tests/unit_tests.lua`).

2. **Unit Tests and Timeout Protection**:
   - Upgraded the `run_lua_tests.sh` script, correcting its test execution path to `./lua_sla_bin`.
   - Introduced a `timeout 30` protection mechanism in the test commands, ensuring each individual unit test and performance test runs for no more than 30 seconds and the total run stays under 5 minutes, preventing infinite loops from hanging the terminal.
   - Running `./run_lua_tests.sh` passes all script-loading tests perfectly.
