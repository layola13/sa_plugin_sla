# sla_ecs 宏缺口分析与编译器改进建议

> **文档版本**：v0.1 / 2026-07-01
> **状态**：建议草案，待审批后开发
> **目标**：基于 sla_ecs 项目实际代码的使用模式，评估是否需要在 `sa_plugin_sla` 编译器层进行宏/derive 相关改进
> **前置文档**：[`macro_vs_rust_cn.md`](./macro_vs_rust_cn.md)、[`architecture_cn.md`](./architecture_cn.md)
> **分析对象**：`~/projects/sla_ecs`（302 个文件，54 个 lib 模块，42 个 examples）

---

## 1. 当前的宏使用格局

`sla_ecs` 使用了三类语言宏能力，使用频率差别极大：

| 宏能力 | slac_ecs 中使用次数 | 代码量覆盖 |
|--------|-------------------|-----------|
| **`@expand_tuple`** | **~60 次**（4 个核心文件） | 数百个结构和函数 |
| **`@derive(name)`** | **~15 次**（lib + examples） | 仅标注用途 |
| **`macro` 关键字** | **0 次** | 不适用 |

### 1.1 @expand_tuple 是核心支柱

`@expand_tuple` 是 sla_ecs 中**最重要**的宏能力，覆盖了所有变长展开场景：

| 展开种类 | 范围 | 生成的代码量 |
|----------|------|-------------|
| `TableErasedAnyOf$N` 结构体 | 2..8 | 7 个结构体 |
| `TableErasedWithAnyOf$N` 结构体 | 2..8 | 7 个结构体 |
| `TableErasedPairWithAnyOf$N` 结构体 | 2..8 | 7 个结构体 |
| `TableErasedCombination$N` 结构体 | 2..16 | 15 个结构体 |
| `table_erased_query_combinations$N` 函数 | 2..16 | 15 个函数 |
| `table_erased_query_pair_mut_combinations$N` 函数 | 2..16 | 15 个函数 |
| `table_erased_world_query_any_of$N` 函数 | 2..8 | 7 个函数 × 3 世界路径 |
| `table_erased_world_query_with_any_of$N` 函数 | 2..8 | 7 个函数 × 3 世界路径 |
| `table_erased_world_query_pair_with_any_of$N` 函数 | 2..8 | 7 个函数 × 3 世界路径 |
| System-param runner 函数（普通/observer/relationship） | 2..8 | 7 个函数 × 3 世界路径 × 3 种类 |

**注意**：`$ORD` 在 `sa_plugin_sla/src/source_expand.zig` 中已实现到 index 15（`sixteenth`），所以 (2..4) + (5..8) 的拆分是 sla_ecs 的**代码风格选择**，而非编译器限制。

### 1.2 @derive 是纯标注

`sla_ecs` 使用 `@derive(...)` 的两种情况：

**情况 A：编译器有语义展开的**
```sla
@derive(copy, eq, ord, hash, debug)
struct Entity { id: i32, gen: i32 }
```
编译器在 lowering_rules.zig 和 codegen.zig 中实现了 `copy`、`eq`（含 PartialEq）、`ord`（含 PartialOrd）的代码生成。

**情况 B：编译器无语义展开的（纯标注）**
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

编译器只记录这些 derive 名称作为注解，**不生成任何代码**。真正的 ECS metadata 来自手写 `impl` 方法。目前编译器对 `hash`、`debug`、`default` 也没有语义展开（它们在 sla_ecs 库代码中手动实现）。

### 1.3 macro 关键字未使用

SLA 的 `macro swap(a, b) { ... }` 只接受 identifier 参数，无法处理类型参数或表达式参数，因此对 sla_ecs 的代码生成无价值。这是**有意不引入更复杂宏系统**（SA 哲学：极简前端）。

---

## 2. 编译器建议改进清单

基于上述分析，以下是按优先级排列的建议。每项仅涉及 `sa_plugin_sla` 编译器层的修改，不改变 sla_ecs 的库代码（除非明确标注）。

---

### 建议 A（P0）：@derive(Component/Resource/Message/Event) 自动生成 type_id

**现状**：每个 ECS 类型需要手写 ~5 行 `impl` 代码：

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

如果开发者在 10 个组件类型上每人写一遍，slac_ecs 的 examples 中已有 ~30 处这样的手写 metadata。

**建议方案**：在编译器中为特定的 derive 名称添加展开规则，**不引入 derive 宏的可扩展系统**——只增加白名单。

```zig
// 在 codegen.zig 中新增（约 200 行 Zig 代码）
// 当编译器看到 @derive(Component) 时，自动生成：
//   impl TypeName {
//       fn component_type_id() -> i32 { return <hash>; }
//       fn component_storage_kind() -> i32 { return 0; }  // table 默认
//   }
```

**具体设计**：

1. `component_type_id()` 使用**编译期类型名称哈希**（如 murmur3 hash，确定性、跨文件一致）
2. `component_storage_kind()` 默认返回 0（table），允许用户通过额外属性覆盖（如 `@component(storage = "sparse")`）
3. `resource_type_id()`、`message_type_id()`、`event_type_id()`、`relationship_type_id()` 同理

**工程量**：约 200-300 行 Zig（parser 扩展 + codegen 展开规则 + 哈希函数）。

**收益**：
- 消除 sla_ecs 中 ~90% 的手写 metadata
- 新组件类型只需一行 `@derive(Component)` 即可工作
- 与现有架构兼容（编译器只增加白名单，不开放用户自定义 derive）

**风险**：最低。只增加编译器展开规则，不改变现有的 `@derive` 解析框架。所有 derive 名称保持语言中立（编译器不硬编码"ECS"语义，只处理名称匹配）。

---

### 建议 B（P1）：@derive(hash) 和 @derive(debug) 的语义展开

**现状**：

编译器当前已为 `@derive(copy, eq, ord)` 提供了代码生成（`lowering_rules.zig` + `codegen.zig`），但 `hash`、`debug`、`default` 仅解析为标注，无代码生成。

`sla_ecs` 中对此的 workaround：
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

**建议方案**：扩展现有的 derive 语义展开，增加字段遍历式的 `hash` 和 `debug` 生成。

```zig
// 在 codegen.zig / sab_codegen.zig 中新增
// @derive(hash) → 生成 fn hash(v: Type) -> i64 { 逐个字段 hash 组合 }
// @derive(debug) → 生成 fn debug(v: Type) -> []const u8 { 拼接字段值 }
```

**工程量**：约 150-250 行 Zig。

**收益**：
- 完善现有 derive 值语义的 6 个白名单
- 消除 slac_ecs 中 Entity 等值类型的手写 hash/debug 函数

**前提**：需要确认 `hash` 和 `debug` 函数签名是否能被编译器正确类型检查。`debug` 返回 `[]const u8` 可能涉及字符串拼接，codegen 层需要支持。

---

### 建议 C（P2）：@expand_tuple 支持单一 @expand 通用模板引擎

**现状**：`@expand_tuple` 只能处理 arity 模板（`$N` = 数字，`$T` = `T0..TN-1` 等）。不能处理其他类型的模板展开。

**slac_ecs 中未满足的需求**：system-param 组合 runner 的 300+ 手写函数。这些函数不是 arity 模板，而是**参数类型组合的笛卡尔积**。例如：

```
基础参数: Query, Commands, ResMut, MessageReader, MessageWriter
组合规则: 每个 runner 是其中 1-5 个参数的组合
世界变体: 每种组合需要 ordinary/observer/relationship 三条路径
```

**这不是 arity 模板能处理的问题。** 两个可行路径：

**路径 1（推荐）：保持现状，用脚本生成**

在 `sla_ecs/` 中放一个 `tools/generate_system_params.py` 或类似脚本，定义参数组合矩阵，生成 `system_param_table_erased.sla` 等文件。

```
参数组合定义 → 生成脚本 → 生成的 lib/*.sla 文件
```

**优点**：
- 不涉及编译器改动
- 可以处理任意复杂的组合逻辑
- sla_ecs 拥有生成逻辑，不污染编译器

**缺点**：
- 需要维护生成脚本
- 生成的代码在 git 中可能较大

**路径 2（可选）：编译器增加 `@expand` 通用模板引擎**

类似 `@expand_tuple` 但更通用：
```sla
@expand(min = 2, max = 8, var = N) {
    struct Foo$N { 
        @repeat(N) { field_$I: i32 }
    }
}
```

但这需要重新设计模板变量系统和重复控制流，工程量 ~500 行 Zig，且不一定能完美覆盖 system-param 组合的所有变体。

**推荐**：不建议编译器做通用模板引擎。slac_ecs 的系统参数组合更适合用**外部脚本**或**源代码生成器**处理。

---

### 建议 D（P3）：统一 @expand_tuple 的 (2..4) + (5..8) 为 (2..8)

**现状**：`$ORD` 已支持到 index 15（sixteenth），但 slac_ecs 中手动拆分为 (2..4) 用命名参数字段 + (5..8) 用数值字段。

这**不是编译器问题**，是 sla_ecs 代码风格选择。但值得记录：

```sla
// 现状：两个范围，字段命名不一致
@expand_tuple(2, 4, T) { $ORD_value: $T }   // first_value, second_value, ...
@expand_tuple(5, 8, T) { value_$I: $T }      // value_0, value_1, ...

// 可统一为：
@expand_tuple(2, 8, T) { $ORD_value: $T }    // 一行即可
```

**建议**：如果决定统一，请在 `lib/world_table_erased.sla` 中将 `@expand_tuple` 的范围从拆分的 (2..4) + (5..8) 合并为 (2..8)。这是一个**sla_ecs 库代码重构**，不需要编译器改动。

---

## 3. 各建议汇总表

| 编号 | 建议 | 优先级 | 编译器改动量 | 预期收益 | 风险 |
|------|------|--------|-------------|---------|------|
| **A** | `@derive(Component/Resource/Message/Event)` 自动生成 type_id | **P0** | ~250 行 Zig | 消除 ~90% 的 ECS 手写 metadata | 低 |
| **B** | `@derive(hash/debug)` 语义展开 | **P1** | ~200 行 Zig | 完善 derive 白名单，消除手写 helper | 低 |
| **C** | 系统参数组合生成（外部脚本） | **P2** | 0 行（脚本 + 生成的文件） | 消除 300+ 手写组合 runner | 极低 |
| **D** | 统一 `@expand_tuple` 的 (2..4) + (5..8) | **P3** | 0 行（仅库重构） | API 一致性 | 极低 |
| — | `macro` 关键字扩展 | **不做** | — | — | 与 SA 哲学冲突 |
| — | 用户自定义 derive | **不做** | — | — | 与 SA 哲学冲突 |
| — | `macro_rules!` 多 arm 模式宏 | **不做** | — | — | 与 SA 哲学冲突 |

---

## 4. 建议 A 的详细设计

建议 A 是唯一真正需要在编译器层投入的 P0 改进。以下是设计草案。

### 4.1 添加的 derive 白名单

| derive 名称 | 生成的函数 | 生成策略 |
|------------|-----------|---------|
| `@derive(Component)` | `component_type_id()`、`component_storage_kind()` | type_id = 确定性哈希 |
| `@derive(Resource)` | `resource_type_id()` | type_id = 确定性哈希 |
| `@derive(Message)` | `message_type_id()` | type_id = 确定性哈希 |
| `@derive(Event)` | `event_type_id()` | type_id = 确定性哈希 |
| `@derive(Relationship)` | `relationship_type_id()` | type_id = 确定性哈希 |

### 4.2 type_id 哈希策略

使用编译期类型名称的确定性哈希（如 FNV-1a 或 xxHash），保证：

1. **跨文件一致性**：同一名称在不同文件中得到相同 type_id
2. **低碰撞概率**：32 位或 64 位哈希，对 ECS 场景（通常 < 1000 类型）足够
3. **稳定**：不依赖文件路径、编译时间等不可靠输入

```zig
fn deriveTypeId(comptime name: []const u8) i32 {
    return @truncate(fnv1a(name, .i32));
}
```

### 4.3 不需要改动的部分

- 现有的 `@derive` 解析框架（`parser.zig`）—— 保持不变
- 现有的 `@derive(copy, eq, ord)` 语义展开（`codegen.zig`）—— 保持不变
- sla_ecs 的库代码—— 只增量修改，不破坏现有 `impl` 方法

### 4.4 文件改动清单

| 文件 | 改动 | 预计行数 |
|------|------|---------|
| `src/ast.zig` | 如果有需要，增加 DeriveSemantic 枚举 | +10 |
| `src/codegen.zig` | 新增 `generateImplMethodsFromDerives` 函数 | +120 |
| `src/sab_codegen.zig` | 为 SAB 路径实现相同的 derive 展开 | +80 |
| `src/type_checker.zig` | 类型检查时收集 derive 标注 | +30 |
| 测试文件 | `test_unit_derive_component.sla` 扩展 | +30 |

**总计**：约 250 行 Zig。

---

## 5. 与现有架构的一致性

### 与 `architecture_cn.md` 一致

现有的 Y 型架构（共享前端 → lowering rules → 双发射器）完全支持新增的 derive 展开规则：

```
SLA AST (含 @derive 标注)
  → 共享前端 (type_checker 识别 derive 名称)
    → lowering_rules.zig (已有的 deriveNameMatches 扩展)
      → codegen.zig / sab_codegen.zig (新增 derive 展开)
        → SA text / SAB 输出
```

新增的 derive 展开在 lowering_rules 层之后、emission 之前注入 `impl` 方法，与现有 `@derive(copy, eq, ord)` 的路径完全一致。

### 与 `macro_vs_rust_cn.md` 一致

本文不引入用户可写的多 arm 宏、片段类型或 proc-macro。增加的 derive 白名单是**编译器内部展开规则**，不是用户可扩展的宏系统。这与 `macro_vs_rust_cn.md` §8（"不要尝试 proc-macro"）和附录 B（"编译器白名单"）的结论一致。

---

## 6. 审批后开发步骤

如果审批通过，建议的开发顺序：

```
Step 1: 实现 @derive(Component/Resource/Message/Event) 的 type_id 哈希生成
Step 2: 扩展 test_unit_derive_component.sla 验证新展开
Step 3: 重构 sla_ecs/ 中的 examples 逐步切换到编译器生成的 type_id
Step 4: 实现 @derive(hash) 和 @derive(debug) 语义展开
Step 5: 创建 tools/generate_system_params.py（可选）
```

每个步骤独立可交付，不互相依赖。
