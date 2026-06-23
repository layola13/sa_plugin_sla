# Sla 宏 vs Rust 宏：兼容性与转换评估

> **文档版本**：v0.1-草案 / 2026-06-15
> **状态**：评估报告 + 改进建议
> **目标**：诚实评估两套宏系统的能力差距，给出 Bevy 移植场景下可行的解决路径
> **关联文档**：
> - [`sla_language_specification_cn.md`](./sla_language_specification_cn.md) Sla 语言规范
> - `sci/docs/faq.md` SA 哲学边界
> - [`sa_plugins/sa_plugin_3dengines/docs/sla_migration_stepbystep_cn.md`](../../sa_plugin_3dengines/docs/sla_migration_stepbystep_cn.md) Bevy 重构具体步骤

> **2026-06-23 架构更正**：本文早期草案中关于把 `Component` / `Resource` / `Event` / `Bundle` 等 ECS derive 硬编码进 Sla 编译器的建议已作废。`sa_plugin_sla` 必须保持语言通用；ECS/Bevy 语义归 `sla_ecs` 库、项目级宏、生成器或未来通用 derive/macro 扩展点所有。编译器可以增加 `@expand_tuple`、通用属性解析、通用值语义 derive 等语言能力，但不能包含引擎关键字或游戏逻辑。

---

## 1. 两套宏系统的实际结构

### 1.1 Sla 当前宏（实测 `parser.zig` + `ast.zig` + `codegen.zig`）

**语法**（来自 spec + 实测）：

```sla
macro swap(a, b) {
    let temp = ^a;
    a = ^b;
    b = ^temp;
}
```

**AST 结构**（`ast.zig:116`）：

```zig
pub const MacroDecl = struct {
    name: []const u8,
    params: []const []const u8,    // 仅 identifier 数组，无类型/无 pattern
    body: []const *Node,
};
```

**Parser 实现**（`parser.zig:581-610`）：

- 关键字 `macro` + identifier 名称
- 参数列表：仅 `identifier (, identifier)*`，无类型标注
- 函数体：标准 sla block

**Codegen 实现**（`codegen.zig:90-92, 2313-2330`）：

- 进入宏定义时清空 local map
- α-conversion：宏内 local 重命名为 `<macro_name>_<local_name>_uniq_<N>`
- 降级到 SA 的 `[MACRO] name %a, %b ... [END_MACRO]` + 调用处 `EXPAND name x, y`

**特性集**：

| 特性 | 状态 |
|------|------|
| 函数式调用语法 `swap(a, b)` | ✅ |
| 参数 = 纯标识符 | ✅（无类型标注，无 pattern） |
| 卫生宏（自动 α-conversion） | ✅ codegen 用 `<macro>_<local>_uniq_<N>` 重命名 |
| 单一 arm（不支持多模式） | — 不支持 |
| 模式匹配 / 片段类型 | ❌ |
| 变长参数（repetition） | ❌ |
| 属性宏 / derive 宏 | ❌ |
| 过程宏 / TokenStream API | ❌ |
| 类型上下文 | ❌（只是文本级 identifier 替换） |
| 调用语法的多形态 | ❌（只能 `name(args)`） |
| 递归宏 | 未明确测试 |

**底层映射**：sla `macro` → SA `[MACRO]` / `EXPAND` 文本宏 1:1 降级。卫生性靠前端 α-conversion 解决；底层 SA 仍是非卫生文本替换。

### 1.2 Rust 宏（两套独立系统）

**系统 A：`macro_rules!` 声明式宏**

```rust
macro_rules! swap {
    ($a:expr, $b:expr) => {
        let temp = $a;
        $a = $b;
        $b = temp;
    };
    // 可多个 arm
    ($a:ident; $b:ident) => { ... };
}
```

特性集：
- 多 arm + 模式匹配
- **片段类型**：`expr` / `ty` / `ident` / `pat` / `stmt` / `tt` / `path` / `meta` / `lifetime` / `vis` / `literal` / `block` / `item`
- **变长重复**：`$($x:expr),*` / `$($x),+`
- 部分卫生（有已知漏洞）
- 类型上下文感知（`$x:ty` 真的匹配类型）

**系统 B：过程宏（Procedural Macros）**

```rust
#[derive(Component)]
struct Position { x: f32, y: f32, z: f32 }

#[my_attribute(some_arg)]
fn foo() { ... }

let v = my_macro!(arbitrary tokens);
```

三种形态：
- 函数式：`my_macro!(...)`
- Derive：`#[derive(MyTrait)]`
- 属性：`#[my_attr]`

实现机制：**单独的 `proc-macro = true` crate**，接收 `TokenStream` 输入，返回 `TokenStream` 输出，用**任意 Rust 代码**操控（syn / quote 是事实标准库）。

---

## 2. 能力对比矩阵

| 能力 | Sla `macro` | Rust `macro_rules!` | Rust proc-macro |
|------|------------|---------------------|----------------|
| 调用样式 `name(args)` | ✅ | ✅（`name!()`） | ✅（`name!()`） |
| 调用样式 `#[derive(X)]` | ❌ | ❌ | ✅ |
| 调用样式 `#[attr]` | ❌ | ❌ | ✅ |
| 参数是 identifier | ✅ | ✅（`:ident`） | ✅ |
| 参数是 expression | ❌（仅 identifier 替换） | ✅（`:expr`） | ✅ |
| 参数是 type | ❌ | ✅（`:ty`） | ✅ |
| 参数是 token tree | ❌ | ✅（`:tt`） | ✅ |
| 变长参数 | ❌ | ✅（`$()*`） | ✅ |
| 多 arm 模式匹配 | ❌ | ✅ | ✅（手写匹配） |
| 自动卫生 | ✅ | ✅（部分） | 手动控制 span |
| 生成 `impl` 块 | 间接（在 macro body 里写 impl） | ✅ | ✅ |
| 解析 struct 字段并生成 trait impl | ❌ | 困难 | ✅（核心场景） |
| 编译期类型反射 | ❌ | ❌ | ✅（受限） |
| 跨 crate 可见 | ✅（import） | ✅ | ✅（独立 crate） |
| 设计哲学符合 SA | ✅ | ⚠️ | ❌（违背"零 AST"） |

---

## 3. 转换难度分类

### ✅ 易（Sla 已能直接覆盖）

| Rust 模式 | Sla 等价 |
|-----------|---------|
| `macro_rules! swap { ($a:ident, $b:ident) => { ... } }` 单 arm 纯 identifier | `macro swap(a, b) { ... }` 直接对应 |
| `macro_rules! debug { () => { ... } }` 无参 marker | `macro debug() { ... }` |
| 简单文本展开（无类型上下文） | 直接转 |

**估计覆盖**：Rust 项目中纯 declarative 简单宏约 **20-30%**。

### ⚠️ 中等（手写改造可行）

| Rust 模式 | Sla 处理 |
|-----------|---------|
| `macro_rules! foo { ($x:expr) => { ... } }` 接 expr | 改写：调用方先 `let tmp = expr;` 再 `foo(tmp)` 传 identifier |
| `macro_rules! foo { ($t:ty) => { ... } }` 接 type | 改写：对每个具体类型手动调一次，或用 sla 泛型替代 |
| 多 arm 用类型分派 | 改写：拆成多个不同名宏，或在 sla 用 trait 替代 |
| `macro_rules! init_field { ($f:ident: $t:ty = $v:expr) => { ... } }` | 改写：拆成几个 identifier 参数 + 调用方先求值 |
| 简单 variadic `[$($x),+]` 列表初始化 | 改写：手动展开 N 次或用数组字面量 |

**估计**：Rust 项目中可手动改造的部分约 **30-40%**。

### 🔴 难（需要 Sla 编译器扩展）

| Rust 模式 | 为什么难 |
|-----------|---------|
| `#[derive(Debug)]` / `#[derive(Clone)]` | 需要读 struct 字段元数据生成方法；Sla 宏无此能力 |
| **`#[derive(Component)]` Bevy ECS 核心** | 同上，且要注册 component id / layout / vtable |
| `#[derive(Serialize, Deserialize)]` Serde | 需要递归遍历类型 |
| `#[derive(Bundle)]` | 需要展开成多 Component 的批量插入逻辑 |
| `#[command]` / `#[get("/api")]` 属性宏 | 需要 Sla 完全不支持的 attribute macro 体系 |
| `macro_rules! impl_for_tuples { (1 2 3 4 5 6 7 8) => { ... } }` 元组实现 | 需要递归 + 类型参数 |
| 任何依赖 `syn` / `quote` 的 proc macro | 需要 Sla 提供 TokenStream API（与 SA 哲学冲突） |

**估计**：Rust 项目中**需要 Sla 编译器扩展才能转**的约 **30-50%**。

### ❌ 不可能（设计层面拒绝）

| Rust 模式 | 为什么 |
|-----------|---------|
| 任意 Rust 代码作为 proc macro 实现 | 违背 SA "零 AST、零隐式逻辑"哲学 |
| 编译期任意计算（const eval） | SA 已经拒绝 |
| 跨 crate 改写其他 crate 的 AST | SA pkg 模型零信任，禁止 |

---

## 4. 对 Bevy 移植场景的具体打击面

### 4.1 Bevy 真正用了什么宏（实测 `bevy_ecs`）

| Bevy 宏 | 类型 | Sla 直接支持？ |
|---------|------|--------------|
| `#[derive(Component)]` | proc derive | ❌ |
| `#[derive(Bundle)]` | proc derive | ❌ |
| `#[derive(Resource)]` | proc derive | ❌ |
| `#[derive(States)]` | proc derive | ❌ |
| `#[derive(Event)]` | proc derive | ❌ |
| `#[derive(SystemParam)]` | proc derive | ❌ |
| `world.spawn((Pos, Vel))` | 普通函数 | ✅ |
| `Query<&Pos, With<Cam>>` | 普通泛型 | ✅（如果 sla 泛型够强） |
| `bevy::prelude::*` | 仅 import | ✅ |

**结论**：Bevy ECS **90%+ 的简洁性来自 derive 宏**。Sla 在这一格直接归零。

### 4.2 没有 derive 的 ECS 看起来什么样

**Rust 原版**（4 行）：

```rust
#[derive(Component)]
struct Position { x: f32, y: f32, z: f32 }
```

**Sla 无宏版**（15-20 行）：

```sla
struct Position { x: f32, y: f32, z: f32 }

const COMPONENT_ID_POSITION: u32 = 1;
const COMPONENT_SIZE_POSITION: u64 = 12;
const COMPONENT_ALIGN_POSITION: u64 = 4;

impl Component for Position {
    fn component_id() -> u32 { return COMPONENT_ID_POSITION; }
    fn size() -> u64 { return COMPONENT_SIZE_POSITION; }
    fn align() -> u64 { return COMPONENT_ALIGN_POSITION; }
    fn write_to(self: &Position, dst: ptr) {
        store dst+0, self.x as f32;
        store dst+4, self.y as f32;
        store dst+8, self.z as f32;
    }
    fn read_from(src: ptr) -> Position {
        return Position {
            x: load src+0 as f32,
            y: load src+4 as f32,
            z: load src+8 as f32
        };
    }
}
```

游戏里 50 个 Component = **750-1000 行样板**。这是不可接受的开发体验，**ECS 移植的最大瓶颈不在 sla 本身，而在 derive 宏缺失**。

---

## 5. 三条解决路径（按 ROI 推荐顺序）

### ⭐⭐⭐⭐⭐ Path 1（推荐）：Sla 编译器内建 `@derive(...)` 注解

**思路**：不让用户写 derive 宏（违背 SA 哲学），而是让 Sla 编译器**内建一小撮 `@derive` 关键字**，在 AST 改写阶段自动生成 impl。

```sla
@derive(Component)
struct Position { x: f32, y: f32, z: f32 }
```

Sla 编译器看到 `@derive(Component)`：
1. 读 struct 字段 → 计算 size / align / layout
2. 自动生成 `impl Component for Position { ... }`
3. 注册 component id 表

**内建白名单**（v0.1 仅这些）：
- `@derive(Component)`
- `@derive(Bundle)`
- `@derive(Resource)`
- `@derive(Event)`
- `@derive(Copy)`（trivially copyable）
- `@derive(Default)`（all-zero init）

**关键约束**：
- 只是**编译器特殊语法**，不是用户可写的宏
- 不接受 `@derive(MyCustomTrait)` 这种用户自定义
- Sla 编译器内部 hard-code 每个 derive 的展开逻辑
- 与 Rust 的 proc-macro **不可互译**，但**写起来一样简洁**

**工程量**：每个 derive 的展开逻辑 ~200-300 行 Zig，6 个 derive ~ 2-3 周。

**ROI**：解锁 Bevy-style 编程体验 90%。**这是 ECS 能不能用的决定性投资**。

### ⭐⭐⭐ Path 2：转换工具 `sa migrate rust-macro`

提供半自动 Rust → Sla 宏转换器：

```bash
sa migrate rust-macro src/lib.rs --out lib.sla
```

工具能力：
- 识别简单 `macro_rules!` 单 arm → 转 Sla `macro`
- 识别 `#[derive(Whitelist)]` → 转 Sla `@derive(...)`（需先做 Path 1）
- 任何不能转的 → 写到 `MIGRATION_TODO.md`，要求人工改写

**适用范围**：把"易"和"中等"两档加起来，工具能覆盖 **50-70%** 的 Rust 宏。

**工程量**：3-4 周（写转换器 + 测试覆盖矩阵）。

**ROI**：让"参考 Rust 代码 → 写 Sla 等价物"加速 3-5×。

### ⭐⭐ Path 3：把 Sla `macro` 升级到 `macro_rules!` 等价

让 Sla 宏支持：
- 多 arm
- 片段类型（`:expr` / `:ty` / `:ident`）
- 变长重复（`$()*`）
- token-tree 匹配

**问题**：
- 需要在 Sla 引入完整的 macro pattern 子语言（数千行 parser + matcher）
- 与"Sla 是 SA 的 LLM-友好高级前端"定位冲突（patterns 难学）
- 仍然解决不了 `#[derive]` 问题（那是属性宏）
- 与 Sla "12 关键字"极简哲学冲突（macro_rules! 自带一套词汇）

**ROI**：极低。不建议做。

### ❌ Path 4（不要做）：proc macro 支持

让 Sla 接受任意 Sla 代码作为 macro 实现，编译期执行。

**为什么不**：
- 违背 SA "零隐式"哲学
- 让构建过程不可复现（macro 行为依赖宿主机）
- 安全模型崩塌（macro 跑任意代码 = 任意 syscall）
- 与 SA pkg "零权限默认"冲突

---

## 6. 组合策略：实际可行的路径

### 6.1 三阶段渐进

| 阶段 | 做什么 | 周数 |
|------|--------|------|
| **Stage A** | Sla 编译器加 `@derive(Copy)` / `@derive(Default)` 两个最简单的 | 1 周 |
| **Stage B** | Sla 编译器加 `@derive(Component)` / `@derive(Bundle)` / `@derive(Resource)` —— ECS 三件套 | 2-3 周 |
| **Stage C** | 转换工具 `sa migrate rust-macro` —— 半自动 Rust → Sla | 3-4 周 |

**完成后**：Bevy-style ECS 程序在 Sla 上的写法与 Rust 大致同等简洁。能跑通 rotating cube → multi-entity → 几十 Component 的真实游戏。

### 6.2 不做的部分

| 不做 | 说明 |
|------|------|
| `#[derive(Serialize)]` Serde | Sla 加 `@derive(Json)` 内建支持就够，不引入 Serde 兼容 |
| `#[derive(Debug)]` | Sla 加 `@debug_print` 内建函数即可 |
| 任意用户自定义 derive | 不开口子；想要特殊行为就手写 impl |
| 属性宏 `#[get("/api")]` | http 路由用普通 builder pattern：`router.get("/api", handler)` |
| 任意 proc-macro | 永远不做 |

---

## 7. Rust 宏 → Sla 转换难度速查表

| Rust 写法 | Sla 等价 | 难度 |
|-----------|---------|------|
| `macro_rules! one_arm { ($x:ident) => { ... } }` | `macro one_arm(x) { ... }` | ⭐ |
| `macro_rules! foo { ($x:expr) => { ... } }` | 调用方先 `let t = expr;` 再 `foo(t)` | ⭐⭐ |
| `macro_rules! foo { ($($x:expr),*) => { ... } }` | 改用数组 `[a, b, c]` 或循环 | ⭐⭐⭐ |
| `println!("x = {}", x)` | `println("x = ", x)` 或 sa_std fmt（**不引入 `!`**） | ⭐⭐ |
| `vec![1, 2, 3]` | `[1, 2, 3]` 数组字面量 | ⭐ |
| `#[derive(Debug)]` | Sla `@derive(Debug)` 内建 | ⭐⭐（需 Path 1） |
| `#[derive(Component)]` | Sla `@derive(Component)` 内建 | ⭐⭐（需 Path 1） |
| `#[derive(Serialize)]` | 手写 `to_json` 方法 | ⭐⭐⭐⭐ |
| `#[tokio::main]` | 不可转，重写 | ⭐⭐⭐⭐⭐ |
| 任意 `proc-macro` crate | 不可转 | 永远不可 |
| `quote! { ... }` 元编程 | 不可转 | 永远不可 |

---

## 8. 对 Bevy 移植场景的最终建议

**Bevy 的 50% 简洁性来自 proc-macro derive**。Sla 永远不会支持 proc-macro，但**可以**靠 Sla 编译器内建少量 `@derive` 撑起 80%。

**优先做的事**：
1. **立刻评估** Sla 编译器加 `@derive(Component)` / `@derive(Bundle)` / `@derive(Resource)` 的工程量
2. 如果 ≤ 3 周可做 → **强烈推荐做**，是 Bevy 移植的唯一可行路径
3. 如果 > 3 周 → 评估是否值得；可以先用手写 impl + 代码生成脚本（`sa3d_codegen.py`）兜底

**别做的事**：
1. ❌ 不要给 Sla 加 `macro_rules!` 那套 pattern 子语言
2. ❌ 不要尝试 proc-macro
3. ❌ 不要试图原样翻译 Bevy 的所有宏（`bevy_reflect` 那套尤其复杂）
4. ❌ 不要为 Serde 兼容做 derive；用 sa_std JSON

---

## 9. 与已有 sla 路线图的协同

### 9.1 影响 `sla_language_specification_cn.md` 的部分

当前规范第 10-11 章"Sla 卫生宏设计"已经描述了现有 macro 形态。建议补充：

- 第 X 章："`@derive(...)` 编译器内建注解"——明确这不是用户宏，是编译器特殊语法
- 关键字列表保持 12 个不变（`@derive` 是 `@` 前缀注解，不增加关键字）
- 附录列出 v0.1 支持的 6 个 derive 白名单

### 9.2 影响 [sla_migration_stepbystep_cn.md](../../sa_plugin_3dengines/docs/sla_migration_stepbystep_cn.md) 的部分

Phase 0 的"sla 编译器 probe 清单"应该把 `@derive` 加入：

```
Probe 8: 编译器内建 @derive
@derive(Copy)
struct V3 { x: f32, y: f32, z: f32 }
fn use_it() {
    let a = V3 { x: 1.0, y: 2.0, z: 3.0 };
    let b = a;   // Copy semantics, no move
}
```

通过这个 Probe 才能进入 ECS 阶段（Phase 6A）。

### 9.3 影响 `sa_plugin_pkg/docs/sla_pkg_lang_field_cn.md` 的部分

`lang = sla` 包的 audit 流水线需要识别 `@derive(...)`：

- audit 不应把 derive 生成的 trait impl 算入用户代码体积
- audit 报告应区分"用户写的"vs"derive 展开的"
- source map 反推时，trait impl 内的错误应映射回 `@derive` 行号

---

## 10. 一句话最终结论

**Sla 当前的 `macro` 是"卫生化的函数式 identifier 宏"**，本质上等价于 Rust `macro_rules!` 的最简单单 arm 子集（约 20-30% 覆盖率）。此外，编译器提供一个受限的源码级 arity 展开入口 `@expand_tuple(min, max, T) { ... }`，用于生成固定范围的 tuple/arity 声明。**Rust 的 derive 宏与 proc-macro 在 Sla 里永远没有用户可写的等价物**——这是 SA 哲学的硬约束。

`@expand_tuple` 支持的模板能力很窄：`$N` 表示当前 arity，`$TYPES` / `$TYPE_PARAMS` 表示 `T0, T1, ...`，`$I` / `$T` 表示当前 `@each` 或 `@join` 项的索引和类型名，`$ORD` 表示 `first`、`second`、`third` 等序数字段名，`@each(T) { ... }` 按 arity 重复模板块，`@join(T, ", ") { ... }` 按分隔符拼接模板块。它适合 Bevy/Sla ECS 这种 `AnyOf2..AnyOfN`、tuple impl、组合结构体和同形函数批量生成，不支持 token-tree 匹配、多 arm 模式、递归宏或任意编译期代码执行。

**对 Bevy 移植的现实路径**：靠 **通用 Sla 宏/展开/derive 基础设施 + `sla_ecs` 项目级生成规则**撑起 ECS / Bundle / Resource / Event 的简洁性。编译器只能提供语言中立能力，例如 `@expand_tuple`、通用属性保留、值语义 `@derive(copy, eq, ord, hash, debug)`、未来 hygienic macro 或通用 source generator；`Component`、`Resource`、`Event`、`Relationship` 等名字和语义必须留在 `sla_ecs`。

**工程量**：优先扩充通用宏/展开能力，再迁移 `sla_ecs` 中的手写 arity family。凡是需要手写 `AnyOf5`、`AnyOf6`、`Any5`、`Any6` 这类机械展开的地方，应先补编译器宏能力，再由库侧模板生成。

---

## 附录 A：评估时参考的源码位置

| 文件 | 行 | 用途 |
|------|---|------|
| `sa_plugin_sla/src/parser.zig` | 581-610 | `parseMacroDecl` 实测语法 |
| `sa_plugin_sla/src/ast.zig` | 116 | `MacroDecl` 结构 |
| `sa_plugin_sla/src/codegen.zig` | 90-92 | α-conversion 命名规则 |
| `sa_plugin_sla/src/codegen.zig` | 2313-2330 | `genMacroDecl` 降级到 SA `[MACRO]` |
| `sa_plugin_sla/src/source_expand.zig` | — | `@expand_tuple` 受限 arity 源码展开 |
| `sa_plugin_sla/docs/sla_language_specification_cn.md` | §10-11 | 卫生宏设计 |
| `sa_plugin_sla/tests/test_edge_cases.sla` | — | macro 测试样例 |
| `sa_plugin_sla/tests/test_unit_expand_tuple_macro.sla` | — | `@expand_tuple` 泛型/arity 端到端测试 |
| `sci/docs/faq.md` | 类型系统类 | 为什么没有 trait / 编译期反射 |
| `bevy_local/crates/bevy_ecs/macros/` | — | Bevy 的 derive 实现参考 |

## 附录 B：v0.1 推荐的语言通用 `@derive(...)` 白名单

| derive | 生成内容 | 复杂度 | 周数 |
|--------|---------|--------|------|
| `@derive(copy)` | 标记 plain value 类型可复制 | 已实现 | — |
| `@derive(eq)` | 生成字段相等比较 | 已实现 | — |
| `@derive(ord)` | 生成字段字典序比较 | 已实现 | — |
| `@derive(hash)` | 生成字段哈希组合 | 已实现 | — |
| `@derive(debug)` | 生成基础 debug 字符串 | 已实现 | — |
| `@derive(default)` | 语言通用默认值生成，不能假设 ECS 语义 | 待评估 | — |

ECS derive 名称如 `Component`、`Bundle`、`Resource`、`Event`、`Message`、`Relationship` 只能作为项目级注解或未来通用宏输入，由 `sla_ecs` 解释和展开，不能进入 `sa_plugin_sla` 的 Zig 白名单。

## 附录 C：Sla 不引入 `!` 后缀的影响

参考 [`sa_plugin_sla/README.md`](../README.md) 的"Sla → Rust 表层兼容性评估"第 §C/§D 节：

由于 Sla 短期内**不引入** `ident!` 宏后缀（与 SA 的 `!` 释放原语视觉冲突），所有 Rust 形如 `println!(...)` / `vec!(...)` / `assert!(...)` 的宏调用，在 Sla 都要写成**函数调用**：

```rust
// Rust
println!("x = {}", x);
let v = vec![1, 2, 3];
assert!(x > 0);
```

```sla
// Sla
println("x = ", x);             // 普通函数
let v = [1, 2, 3];              // 数组字面量
assert(x > 0);                  // 普通函数
```

转换工具（Path 2）应自动剥 `!` 重写。
