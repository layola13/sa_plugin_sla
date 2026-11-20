# Sla Compiler Architecture Document: Y-Shaped Design and Shared Lowering Layer

> This is the English counterpart of the Chinese document [Sla 编译器架构文档：Y 型设计与共享降低层](./architecture_cn.md).

> **Document version**: v0.1 / 2026-07-01
> **Status**: Based on the implementation in `src/plugin.zig`, `src/lowering_rules.zig`, `sla_std/std_surface.sla_meta`, `src/sab_codegen.zig`, and `src/codegen.zig`
> **Related**: [`std_surface_metadata_cn.md`](./std_surface_metadata_cn.md)

---

## 1. Architecture Overview: The Y-Shaped Pipeline

The Sla compiler uses a **Y-shaped architecture**, a key architectural decision that ensures frontend logic is not duplicated by the backend emitters.

```
                    .sla 源文件
                         │
                         ▼
             ┌───────────────────────┐
             │   共享前端 (Shared Front-end Trunk)    │
             │                       │
             │  read → source_expand │
             │  → parse → @import    │
             │  → test_filter →      │
             │  monomorphize →       │
             │  load_contracts →     │
             │  type_check →         │
             │  primary_decl_filter  │
             │                       │
             │  (runSlaFrontend)      │
             └───────────────────────┘
                         │
                         ▼
             ┌───────────────────────┐
             │  共享降低规则层 (Shared Lowering Rules)  │
             │                       │
             │  lowering_rules.zig:  │
             │  • StaticCallPlan      │
             │  • CallArgMaterializationPlan  │
             │  • ImportedMacroCallPlan      │
             │  • OptionClosureCallPlan      │
             │  • SmartPointer helpers       │
             │  • ABI layout rules           │
             │  • RefCellBorrowPlan          │
             │                       │
             │  sla_std/std_surface.sla_meta: │
             │  • 元数据驱动的 std surface     │
             │  • 不包含 Zig 编译器分支        │
             └───────────────────────┘
                      ╱    ╲
                     ╱      ╲
                    ▼        ▼
         ┌────────────┐  ┌────────────┐
         │ SA 文本发射器│  │ SAB 结构化 │
         │ (codegen.zig)│  │ 发射器     │
         │             │  │(sab_codegen│
         │ 输出 .sa    │  │ .zig)      │
         │ 文本文件    │  │            │
         │             │  │ 输出 .sab  │
         │             │  │ 二进制文件  │
         └────────────┘  └────────────┘
```

### 1.1 Why Y-Shaped?

| Problem | Non-Y-shaped approach | Y-shaped approach |
|---------|-----------------------|-------------------|
| SA text and SAB share the same 70% of the pipeline | Write parsing/type checking twice | `runSlaFrontend()` shares 100% of the frontend |
| Call argument logic (auto-borrow, copy strategy) is duplicated in both emitters | SAB branches on its own | `CallArgMaterializationPlan` provides a unified description |
| std library lowering is inconsistent between the two backends | Each uses `if type == Vec` | `std_surface.sla_meta` is data-driven |
| New language features implemented only in SAB | Feature inconsistency | The shared rules layer forces both backends to implement them |

**Core principle**: do not implement high-level semantics only in `sab_codegen.zig`. New direct-SAB work must extend the shared lowering rules or the std surface metadata, then let the SA-text and SAB emitters converge through a shared contract.

---

## 2. Shared Frontend (`runSlaFrontend`)

`runSlaFrontend` in `src/plugin.zig` is the shared trunk of the Y-shaped pipeline:

```
runSlaFrontend(allocator, file, mono, tc, options, stderr, profile)
```

### Pipeline Stages and Their Typical Timing Characteristics

| Stage | Function | Description | Typical time |
|-------|----------|-------------|--------------|
| Source read | `readFileAlloc` | Read the .sla source file | <10ms |
| Source expansion | `source_expand.expand` | Expand `@expand_tuple` template macros | <5ms |
| Parsing | `Parser.initWithDir.parseProgram` | Lexical/syntax analysis | 10-100ms |
| @import expansion | `expandSlaImports` | Recursively expand .sla submodules imported via SLA @import | 50-500ms |
| Test filtering | `pruneTestsByFilter` | Prune @test declarations according to `--filter` | <1ms |
| Monomorphization | `monomorphize` | Generic specialization | 10-200ms |
| Contract loading | `loadImportedContracts` | Load `.sai`/`.sal` contracts + register imported macros | 20-200ms |
| Type checking | `checkProgram` | Type-safety checking | 10-200ms |
| Primary declaration filtering | `primary_decl_filter` | Keep only primary declarations (not monomorphization intermediates) | <1ms |

### Constraints

- `mono` and `tc` are caller-owned: the caller must `init`/`deinit` them (and keep them alive during its tail code generation, because the tail code reads information from them)
- New frontend stages must be added to `runSlaFrontend`, not to an individual tail
- All stages support timing via the `SLA_PROFILE` environment variable

---

## 3. Shared Lowering Rules Layer (`lowering_rules.zig`)

`src/lowering_rules.zig` is the **core shared module** of the Y-shaped architecture. It contains rules/plans consumed by both emitters, ensuring SA text and SAB remain semantically consistent.

### 3.1 Call Plans

#### `StaticCallPlan`
- `target_symbol: []const u8` — the resolved function symbol
- `arg_count: usize` — number of arguments
- `argPrefix(arg)` — returns `&`/`^`/null (borrow/move prefix)

Built by `planStaticCall(tc, expr, call)` and `planResolvedStaticCall(tc, expr, call)`.

#### `CallArgMaterializationPlan`

Describes how each argument is materialized:
```zig
pub const CallArgMaterializationKind = enum {
    array_to_slice_borrow,  // 数组到切片的隐式借用
    dyn_borrow,             // dyn trait 胖指针物化
    auto_borrow,            // 自动借用（接收者或参数）
    copy_struct_value,      // 结构体值拷贝
    value,                  // 普通值传递
};
```

Each plan carries `release_after_call: bool`, determining whether a release is needed after the call.

Built by `planCallArgMaterialization(arg, input)`.

#### `ImportedMacroCallPlan`

Describes an imported SA `[MACRO]` call:
- `macro_name` — macro name
- `import_path` — import path
- `arity` — total argument count
- `leading_outputs` — number of leading output arguments (such as `out`, `nonnull_ptr`)
- `expression_output` — whether there is an expression output (i.e. the macro can be used as an expression)
- `borrowed_arg_mask` — which arguments are borrowed directly via `&%param`
- `callArgNeedsAddressableSlot(index)` — whether that argument needs an addressable stack slot

Built by `planImportedMacroCall(tc, call)`.

### 3.2 ABI Layout Rules

All layout rules are shared and are not matched against any specific emitter:

```zig
pub fn abiTypeSize(ty) usize           // 类型大小
pub fn structAbiSize(decl) usize       // 结构体 ABI 大小
pub fn structFieldLayout(decl, name)   // 字段偏移/大小
pub fn tupleFieldLayout(tuple, index)  // 元组字段布局
pub fn arrayElementLayout(arr, index)  // 数组元素布局
pub fn inlineArrayStride(elem_ty)      // 内联数组步长（非指针槽）
```

**Key ABI rule**: fixed arrays inside a struct are stored in pointer-sized (8-byte) slots, while the array value itself retains its inline element layout.

### 3.3 Smart Pointer Type Recognition

```zig
pub fn smartPointerType(ty) -> ?SmartPointerType  // 识别 Box/Rc/Arc/RefCell
pub fn boxInnerType(ty)     // Box<T> 的 T
pub fn rcInnerType(ty)      // Rc<T> 的 T
pub fn arcInnerType(ty)     // Arc<T> 的 T
pub fn refCellInnerType(ty) // RefCell<T> 的 T
pub fn smartPointerDerefType(ty) // 可解引用的智能指针
```

### 3.4 Other Shared Helper Functions

| Function | Purpose |
|----------|---------|
| `deriveNameMatches` / `structHasDerive` | Derive name comparison |
| `isVoidType` | Whether a type is void |
| `callArgPrefix` | Get the `&`/`^` prefix |
| `prefixedIdentifierCallArg` | Extract a prefixed identifier argument |
| `callArgNeedsRelease` / `exprResultNeedsRelease` | Whether a release is needed |
| `rootIdentifier` | Root identifier of a chained expression |
| `assignmentMovesIdentifier` | Whether an assignment triggers a move |
| `shouldAutoBorrowResolvedArg` / `shouldAutoBorrowReceiverArg` | Auto-borrow conditions |
| `planOptionClosureCall` | Option closure method classification |
| `planRefCellBorrowCall` | RefCell borrow/borrow_mut classification |
| `mangleMethodName` / `mangleTraitMethodName` | Method name mangling |
| `dynMethodSlot` / `vtableName` | VTable layout |
| `optionInnerType` | Extract the T from Option<T> |

---

## 4. Metadata-Driven Std Surface

See the separate [`std_surface_metadata_cn.md`](./std_surface_metadata_cn.md) document.

**Key principles**:
- `sla_std/std_surface.sla_meta` is data, not compiler logic
- The SAB backend reads these rules generically
- Lowering of any standard library type (Vec, Option, Result, Cell, Rc, Arc, Box, RefCell, Slice) is defined in metadata, not in Zig branches
- New types only need a rule row added to `.sla_meta`; no compiler changes are required

---

## 5. Differences Between the Two Emitters

### SA Text Emitter (`codegen.zig`)
- Flattens the typed/specialized SLA AST into SA assembly text
- Outputs `.sa` files (readable and debuggable)
- It is a standalone text mainline for `sa sla build`, not a backup or fallback path for SAB

### SAB Structured Emitter (`sab_codegen.zig`)
- Emits structured SAB bytes directly (binary format)
- direct AST→SAB is the only emission path; unsupported features return `UnsupportedSabDirectFeature` with a loud error, and there is no compatibility path falling back to SA text (SAB downgrade to text is prohibited; for the governance position, see the sala repository's *SAB Format Whitepaper (Specification)* §4.2)

### Historical Fallback Path (Removed)

The old design fell back to `AST → codegen (SA text) → flattener → SAB encoder` (SA-compatible fallback) when the direct path did not support a feature, and this could be disabled with `SLA_SAB_NO_FALLBACK=1`. Measured bottlenecks on that path were flatten 4.04s + encode 5.22s (the direct path took only 24-257ms); it was removed entirely on 2026-09-28 along with the governance decision (commit `e96e6b39`). `SLA_SAB_NO_FALLBACK` is no longer read by the source, and erroring out on a direct failure is unconditional behavior.

---

## 6. Caching Architecture

The SAB path has three cache layers, all within a single compilation instance:

### Layer 1: `sa_std` Root Cache
- Each SAB compilation instance caches the resolved `sa_std` root path once
- Avoids repeating the filesystem root-probing sequence

### Layer 2: Decoded std Import Module Cache
- Multiple standard-surface rules from the same `sa_std` import path reuse the decoded SAB module
- Avoids repeating the SCI flatten/encode/decode sequence

### Layer 3: Identifier Macro Template Cache
- Macro fragments whose arguments are all identifiers (such as `Option::is_some`)
- Generate a placeholder template once → subsequent calls clone the decoded structured instructions
- Direct arguments (numeric values, type names) still follow the normal path

### Write-Time Cache Comparison
```zig
fn writeSabFile(allocator, path, sab_bytes, stderr) -> bool
```
Before writing a SAB file, compare the byte content: if it is identical, skip the write, so as to keep the SA incremental cache stable.

---

## 7. Managed Cache Paths

SAB managed artifacts live in `.sla-cache/sab/`:

```
.sla-cache/sab/
├── {stem}-{source_hash}.sab           # 普通编译
├── {stem}-{source_hash}-{variant}.sab  # 测试（带变体）
└── ...
```

### Path Naming Rules

| Scenario | Path | Key |
|----------|------|-----|
| Normal compilation | `{stem}-{Wyhash(file)}.sab` | Source file path |
| Tests (all) | `{stem}-{Wyhash(file + "test-all")}.sab` | Source file path + constant |
| Tests (with filter) | `{stem}-{Wyhash(file + "test-filter" + filter)}.sab` | Source file path + filter string |

### Cache Isolation

- Filtered test builds use a filter-scoped path and do not overwrite normal build / workspace SAB artifacts
- User-visible SAB files are written only on request: `--out`, `--sab-out`, or `--emit-sab`

---

## 8. Complete CLI Pipeline Diagrams

### `sa sla build <file>`
```
read → source_expand → parse → @import → monomorphize → contracts → typecheck
  → rewriteImports → codegen.generate → .sa 文件
```

### `sa sla build-exe <file>`
```
read → source_expand → parse → @import → monomorphize → contracts → typecheck
  → sab_codegen.generate → .sab（不支持的特性响亮报错，无回退）
  → sa build-exe <sab>
```

### `sa sla test <file>`
```
read → source_expand → parse → @import → test_filter → monomorphize → contracts
  → typecheck → reachable-decl-filter
  → sab_codegen.generate → .sla-cache/sab/...sab（不支持的特性响亮报错，无回退）
  → sa test <sab>
```

---

## 9. Key Architectural Constraints

1. **Do not implement high-level semantics only in `sab_codegen.zig`.** New direct-SAB work must extend the shared lowering rules or the std surface metadata.

2. **Direct SAB must stay direct.** Do not implement `.sla → .sa text → .sab` as a normal path.

3. **The Y-shaped frontend trunk must be the single source of truth.** Put new frontend stages in `runSlaFrontend`.

4. **Metadata over compiler branches.** Use the `sla_std/std_surface.sla_meta` data file instead of adding `if type == Vec/Rc/Set` branches in Zig.

5. **No `Vec`/`thread`/`ECS` compiler branches.** Such library semantics belong in standard-library macros, metadata, and surface rules.
