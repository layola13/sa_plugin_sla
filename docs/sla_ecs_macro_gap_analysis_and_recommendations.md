# sla_ecs Macro Gap Analysis and Compiler Improvement Recommendations

> This is the English counterpart of the Chinese document [sla_ecs 宏缺口分析与编译器改进建议](./sla_ecs_macro_gap_analysis_and_recommendations_cn.md).

> **Document version**: v0.1 / 2026-07-01
> **Status**: Proposed draft, pending approval before development
> **Goal**: Based on the usage patterns in the actual code of the sla_ecs project, assess whether macro/derive-related improvements are needed at the `sa_plugin_sla` compiler layer
> **Prerequisite documents**: [`macro_vs_rust_cn.md`](./macro_vs_rust_cn.md), [`architecture_cn.md`](./architecture_cn.md)
> **Analysis subject**: `~/projects/sla_ecs` (302 files, 54 lib modules, 42 examples)

---

## 1. The Current Macro Usage Landscape

`sla_ecs` uses three categories of language macro capability, with vastly different usage frequencies:

| Macro capability | Uses in slac_ecs | Code coverage |
|------------------|------------------|---------------|
| **`@expand_tuple`** | **~60 uses** (4 core files) | Hundreds of structs and functions |
| **`@derive(name)`** | **~15 uses** (lib + examples) | Annotation purposes only |
| **`macro` keyword** | **0 uses** | Not applicable |

### 1.1 @expand_tuple Is the Core Pillar

`@expand_tuple` is the **most important** macro capability in sla_ecs, covering all variable-arity expansion scenarios:

| Expansion kind | Range | Amount of code generated |
|----------------|-------|--------------------------|
| `TableErasedAnyOf$N` structs | 2..8 | 7 structs |
| `TableErasedWithAnyOf$N` structs | 2..8 | 7 structs |
| `TableErasedPairWithAnyOf$N` structs | 2..8 | 7 structs |
| `TableErasedCombination$N` structs | 2..16 | 15 structs |
| `table_erased_query_combinations$N` functions | 2..16 | 15 functions |
| `table_erased_query_pair_mut_combinations$N` functions | 2..16 | 15 functions |
| `table_erased_world_query_any_of$N` functions | 2..8 | 7 functions × 3 world paths |
| `table_erased_world_query_with_any_of$N` functions | 2..8 | 7 functions × 3 world paths |
| `table_erased_world_query_pair_with_any_of$N` functions | 2..8 | 7 functions × 3 world paths |
| System-param runner functions (ordinary/observer/relationship) | 2..8 | 7 functions × 3 world paths × 3 kinds |

**Note**: `$ORD` is implemented up to index 15 (`sixteenth`) in `sa_plugin_sla/src/source_expand.zig`, so the (2..4) + (5..8) split is a **code-style choice** of sla_ecs, not a compiler limitation.

### 1.2 @derive Is Pure Annotation

`sla_ecs` uses `@derive(...)` in two situations:

**Case A: where the compiler has semantic expansion**
```sla
@derive(copy, eq, ord, hash, debug)
struct Entity { id: i32, gen: i32 }
```
The compiler implements code generation for `copy`, `eq` (including PartialEq), and `ord` (including PartialOrd) in lowering_rules.zig and codegen.zig.

**Case B: where the compiler has no semantic expansion (pure annotation)**
```sla
@derive(Component)
struct Position { x: i32, y: i32 }

@derive(Resource)
struct Time { tick: i32 }

@derive(Message)
struct Damage { amount: i32 }

@derive(Event)
struct Explode { damage: i32 }

@derive(Relationship)
struct ChildOf { parent: Entity }
```

The compiler merely records these derive names as annotations and **generates no code at all**. The real ECS metadata comes from hand-written `impl` methods. At present the compiler also has no semantic expansion for `hash`, `debug`, or `default` (they are implemented manually in the sla_ecs library code).

### 1.3 The macro Keyword Is Unused

SLA's `macro swap(a, b) { ... }` only accepts identifier arguments and cannot handle type arguments or expression arguments, so it is of no value for sla_ecs's code generation. This is a **deliberate choice not to introduce a more complex macro system** (SA philosophy: a minimal frontend).

---

## 2. Compiler Improvement Recommendation List

Based on the above analysis, the following are recommendations ordered by priority. Each involves only changes at the `sa_plugin_sla` compiler layer and does not change sla_ecs's library code (unless explicitly noted).

---

### Recommendation A (P0): @derive(Component/Resource/Message/Event) Auto-Generates type_id

**Current situation**: Every ECS type requires ~5 lines of hand-written `impl` code:

```sla
@derive(Component)
struct Position { x: i32, y: i32 }

// 目前需要手写：
impl Position {
    fn component_type_id() -> i32 { return 1001; }
    fn component_storage_kind() -> i32 { return 0; }  // 0 = table
    fn component_name() -> []const u8 { return "Position"; }
}
```

If developers write this once for each of 10 component types, there are already ~30 such hand-written metadata instances in slac_ecs's examples.

**Proposed solution**: Add expansion rules for specific derive names in the compiler, **without introducing an extensible derive-macro system** — only extend the allowlist.

```zig
// 在 codegen.zig 中新增（约 200 行 Zig 代码）
// 当编译器看到 @derive(Component) 时，自动生成：
//   impl TypeName {
//       fn component_type_id() -> i32 { return <hash>; }
//       fn component_storage_kind() -> i32 { return 0; }  // table 默认
//   }
```

**Specific design**:

1. `component_type_id()` uses a **compile-time hash of the type name** (such as murmur3 hash — deterministic and consistent across files)
2. `component_storage_kind()` returns 0 (table) by default, allowing overrides via an extra attribute (e.g. `@component(storage = "sparse")`)
3. `resource_type_id()`, `message_type_id()`, `event_type_id()`, and `relationship_type_id()` work the same way

**Effort**: about 200-300 lines of Zig (parser extension + codegen expansion rules + hash function).

**Benefits**:
- Eliminates ~90% of hand-written metadata in sla_ecs
- A new component type only needs a single line `@derive(Component)` to work
- Compatible with the existing architecture (the compiler only adds allowlist entries; user-defined derives are not opened up)

**Risk**: Lowest. Only compiler expansion rules are added; the existing `@derive` parsing framework is unchanged. All derive names remain language-neutral (the compiler does not hardcode "ECS" semantics, only name matching).

---

### Recommendation B (P1): Semantic Expansion of @derive(hash) and @derive(debug)

**Current situation**:

The compiler currently provides code generation for `@derive(copy, eq, ord)` (`lowering_rules.zig` + `codegen.zig`), but `hash`, `debug`, and `default` are only parsed as annotations, with no code generation.

The workaround for this in `sla_ecs`:
```sla
// 在 lib/entity_set.sla 中手动实现 hash
fn entity_hash(entity: Entity) -> i64 {
    return (entity.id as i64) * 31 + (entity.gen as i64) * 7;
}

// 在 debug 函数中手动实现 debug
fn debug_entity(entity: Entity) -> []const u8 {
    return debug_format("Entity({}, {})", entity.id, entity.gen);
}
```

**Proposed solution**: Extend the existing derive semantic expansion with field-traversal-style `hash` and `debug` generation.

```zig
// 在 codegen.zig / sab_codegen.zig 中新增
// @derive(hash) → 生成 fn hash(v: Type) -> i64 { 逐个字段 hash 组合 }
// @derive(debug) → 生成 fn debug(v: Type) -> []const u8 { 拼接字段值 }
```

**Effort**: about 150-250 lines of Zig.

**Benefits**:
- Completes the 6-entry allowlist of existing derive value semantics
- Eliminates hand-written hash/debug functions for value types such as Entity in slac_ecs

**Prerequisite**: Need to confirm whether the `hash` and `debug` function signatures can be correctly type-checked by the compiler. `debug` returning `[]const u8` may involve string concatenation, which the codegen layer needs to support.

---

### Recommendation C (P2): @expand_tuple Supporting a Single General-Purpose @expand Template Engine

**Current situation**: `@expand_tuple` can only handle arity templates (`$N` = number, `$T` = `T0..TN-1`, etc.). It cannot handle other kinds of template expansion.

**Unmet need in slac_ecs**: the 300+ hand-written functions for system-param combination runners. These are not arity templates, but **Cartesian products of parameter type combinations**. For example:

```
基础参数: Query, Commands, ResMut, MessageReader, MessageWriter
组合规则: 每个 runner 是其中 1-5 个参数的组合
世界变体: 每种组合需要 ordinary/observer/relationship 三条路径
```

**This is not a problem an arity template can handle.** Two viable paths:

**Path 1 (recommended): keep the status quo and use a generation script**

Place a `tools/generate_system_params.py` or similar script in `sla_ecs/`, define the parameter-combination matrix, and generate files such as `system_param_table_erased.sla`.

```
参数组合定义 → 生成脚本 → 生成的 lib/*.sla 文件
```

**Advantages**:
- No compiler changes involved
- Can handle arbitrarily complex combination logic
- sla_ecs owns the generation logic, without polluting the compiler

**Disadvantages**:
- The generation script must be maintained
- The generated code can be large in git

**Path 2 (optional): add a general-purpose `@expand` template engine to the compiler**

Similar to `@expand_tuple` but more general:
```sla
@expand(min = 2, max = 8, var = N) {
    struct Foo$N { 
        @repeat(N) { field_$I: i32 }
    }
}
```

But this requires redesigning the template variable system and repetition control flow — about ~500 lines of Zig — and may not perfectly cover all variants of system-param combinations.

**Recommendation**: Do not recommend that the compiler build a general-purpose template engine. slac_ecs's system-parameter combinations are better handled with an **external script** or a **source code generator**.

---

### Recommendation D (P3): Unify @expand_tuple's (2..4) + (5..8) into (2..8)

**Current situation**: `$ORD` already supports up to index 15 (sixteenth), but slac_ecs manually splits into (2..4) using named parameter fields and (5..8) using numeric fields.

This is **not a compiler issue**, but a sla_ecs code-style choice. Still, it is worth recording:

```sla
// 现状：两个范围，字段命名不一致
@expand_tuple(2, 4, T) { $ORD_value: $T }   // first_value, second_value, ...
@expand_tuple(5, 8, T) { value_$I: $T }      // value_0, value_1, ...

// 可统一为：
@expand_tuple(2, 8, T) { $ORD_value: $T }    // 一行即可
```

**Recommendation**: If a decision is made to unify, change the `@expand_tuple` ranges in `lib/world_table_erased.sla` from the split (2..4) + (5..8) to a single (2..8). This is an **sla_ecs library code refactor** and requires no compiler changes.

---

## 3. Summary Table of Recommendations

| # | Recommendation | Priority | Compiler change size | Expected benefit | Risk |
|---|----------------|----------|----------------------|------------------|------|
| **A** | `@derive(Component/Resource/Message/Event)` auto-generates type_id | **P0** | ~250 lines of Zig | Eliminates ~90% of hand-written ECS metadata | Low |
| **B** | `@derive(hash/debug)` semantic expansion | **P1** | ~200 lines of Zig | Completes the derive allowlist, eliminates hand-written helpers | Low |
| **C** | System-parameter combination generation (external script) | **P2** | 0 lines (script + generated files) | Eliminates 300+ hand-written combination runners | Very low |
| **D** | Unify `@expand_tuple`'s (2..4) + (5..8) | **P3** | 0 lines (library refactor only) | API consistency | Very low |
| — | `macro` keyword extension | **Do not do** | — | — | Conflicts with SA philosophy |
| — | User-defined derives | **Do not do** | — | — | Conflicts with SA philosophy |
| — | `macro_rules!` multi-arm pattern macros | **Do not do** | — | — | Conflicts with SA philosophy |

---

## 4. Detailed Design of Recommendation A

Recommendation A is the only P0 improvement that genuinely requires investment at the compiler layer. The following is the design draft.

### 4.1 Derive Allowlist to Be Added

| derive name | Generated functions | Generation strategy |
|-------------|---------------------|---------------------|
| `@derive(Component)` | `component_type_id()`, `component_storage_kind()` | type_id = deterministic hash |
| `@derive(Resource)` | `resource_type_id()` | type_id = deterministic hash |
| `@derive(Message)` | `message_type_id()` | type_id = deterministic hash |
| `@derive(Event)` | `event_type_id()` | type_id = deterministic hash |
| `@derive(Relationship)` | `relationship_type_id()` | type_id = deterministic hash |

### 4.2 type_id Hash Strategy

Use a deterministic hash of the compile-time type name (such as FNV-1a or xxHash), ensuring:

1. **Cross-file consistency**: the same name yields the same type_id in different files
2. **Low collision probability**: a 32-bit or 64-bit hash is sufficient for ECS scenarios (typically < 1000 types)
3. **Stability**: does not depend on unreliable inputs such as file paths or compile time

```zig
fn deriveTypeId(comptime name: []const u8) i32 {
    return @truncate(fnv1a(name, .i32));
}
```

### 4.3 Parts That Need No Changes

- The existing `@derive` parsing framework (`parser.zig`) — remains unchanged
- The existing `@derive(copy, eq, ord)` semantic expansion (`codegen.zig`) — remains unchanged
- sla_ecs's library code — only incremental modifications, without breaking existing `impl` methods

### 4.4 File Change List

| File | Change | Estimated lines |
|------|--------|-----------------|
| `src/ast.zig` | Add a DeriveSemantic enum if needed | +10 |
| `src/codegen.zig` | Add a `generateImplMethodsFromDerives` function | +120 |
| `src/sab_codegen.zig` | Implement the same derive expansion for the SAB path | +80 |
| `src/type_checker.zig` | Collect derive annotations during type checking | +30 |
| Test files | Extend `test_unit_derive_component.sla` | +30 |

**Total**: about 250 lines of Zig.

---

## 5. Consistency with the Existing Architecture

### Consistent with `architecture_cn.md`

The existing Y-shaped architecture (shared frontend → lowering rules → dual emitters) fully supports the new derive expansion rules:

```
SLA AST (含 @derive 标注)
  → 共享前端 (type_checker 识别 derive 名称)
    → lowering_rules.zig (已有的 deriveNameMatches 扩展)
      → codegen.zig / sab_codegen.zig (新增 derive 展开)
        → SA text / SAB 输出
```

The new derive expansion injects `impl` methods after the lowering_rules layer and before emission, exactly the same path as the existing `@derive(copy, eq, ord)`.

### Consistent with `macro_vs_rust_cn.md`

This document does not introduce user-writable multi-arm macros, fragment types, or proc-macros. The added derive allowlist is a **compiler-internal expansion rule**, not a user-extensible macro system. This is consistent with the conclusions of `macro_vs_rust_cn.md` §8 ("do not attempt proc-macro") and Appendix B ("compiler allowlist").

---

## 6. Development Steps After Approval

If approval is granted, the recommended development order:

```
Step 1: 实现 @derive(Component/Resource/Message/Event) 的 type_id 哈希生成
Step 2: 扩展 test_unit_derive_component.sla 验证新展开
Step 3: 重构 sla_ecs/ 中的 examples 逐步切换到编译器生成的 type_id
Step 4: 实现 @derive(hash) 和 @derive(debug) 语义展开
Step 5: 创建 tools/generate_system_params.py（可选）
```

Each step is independently deliverable and does not depend on the others.
