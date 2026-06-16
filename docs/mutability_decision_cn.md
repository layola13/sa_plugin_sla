# Sla 可变性设计决策（mut 引入与否）

> **文档版本**：v0.2-定稿（实测纠错） / 2026-06-15
> **状态**：技术决策定稿
> **修订摘要**：v0.1 基于"假想未来痛点"建议立即引入 `&mut T`；**v0.2 基于实测 demo 纠错**——sla 当前 `&self` 同时覆盖读写约定运行良好，**Phase 1 (现在) 不动语言层**，仅文档化约定 + parser 可选容错；**Phase 2 (sa3d ECS 启动前)** 才引入 `&mut T` / `&mut self`（因 ECS 调度器需要静态 read/write 集）。
> **关联文档**：
> - [`sla_language_specification_cn.md`](./sla_language_specification_cn.md) Sla 语言规范
> - [`macro_vs_rust_cn.md`](./macro_vs_rust_cn.md) Sla 宏 vs Rust 宏
> - [`../README.md`](../README.md) Rust 表层兼容性评估
> - [`/home/vscode/projects/sa_plugins/sa_plugin_3dengines/docs/sa3d_ecs_api_design_cn.md`](../../sa_plugin_3dengines/docs/sa3d_ecs_api_design_cn.md) sa3d ECS API（Phase 2 触发点）
> - [`/home/vscode/projects/sa_plugins/sa_plugin_3dengines/docs/sla_migration_stepbystep_cn.md`](../../sa_plugin_3dengines/docs/sla_migration_stepbystep_cn.md) sa3d 实施路线

---

## 0. v0.2 修订说明（道歉与纠错）

**v0.1 错在哪**：
- 基于 Bevy ECS / 库生态 / LLM Agent 等**假想未来场景**得出"立即引入 mut 是致命的"
- 没去看 `sa_plugin_sla/demos/rosetta/` 里的实测代码
- 把"未来某天会发生"夸大成"现在就崩"

**实测纠正**：
- `demos/rosetta/59_method_counter/main.sla` 用 `&self` 包 `self.0 += 1`，**跑通**
- `demos/rosetta/40_impl_block_state/main.sla` 用 `&self` 包 `self.balance = ...`，**跑通**
- `demos/rosetta/07_trait_vtable/main.sla` 用 `&self` 包纯读，**跑通**
- 所有现有 demo 与 tests 在 sla `&self` 兼读写的约定下**正常工作**——SA Referee 在 lowering 后承担读写区分

**修订后的真实节奏**：
- **Phase 1（现在 → sa3d ECS 启动前）**：不引入 `&mut`；明确文档化"`&self` 涵盖读写"约定；parser 可选容错接受 Rust 写法
- **Phase 2（sa3d ECS Phase 6A 启动前）**：引入 `&mut T` + trait `&mut self`（ECS 调度器需要静态 read/write 集做并行调度）
- **Phase 3（库生态形成时）**：sla 借用检查器从"defer 给 SA Referee"升级到 sla 源码层精确报错

---

## 1. 决策摘要（TL;DR）

| 项 | 当前 (Phase 1) | Phase 2 (sa3d ECS 之前) |
|---|---|---|
| **`let x = 5` 绑定可变性** | 默认可变（不变） | 默认可变（不变） |
| **`const x = 5` 绑定** | 不可变（不变） | 不可变（不变） |
| **`let mut x = 5` 语法** | **不引入**（与 sla 现状冲突） | **不引入** |
| **`&self` 在 impl/trait** | **涵盖读写**（sla 当前约定） | 仅读；写需 `&mut self` |
| **`&mut T` 借用类型** | **不引入** | **引入** |
| **trait 方法 `&mut self`** | **不引入** | **引入**（强制契约） |
| **函数签名 `&mut Vec`** | **不引入** | **引入**（推荐） |
| **lowered SA 影响** | 不变 | 零影响（仍降级为 SA `&`） |
| **现有 sla 代码影响** | **零改动** | 写型方法签名 `&self → &mut self`，工具自动化迁移 |
| **Rust 表层兼容性** | 70%（不达 95%，可接受） | 85% |

---

## 2. Phase 1：当前阶段的最小行动

### 2.1 不做（避免折腾）

- ❌ 不动 parser
- ❌ 不动 type_checker
- ❌ 不动 codegen
- ❌ 不动现有 demo / tests / sa_std 调用

### 2.2 必做（文档化约定）

#### A. 在 `sla_language_specification_cn.md` §6 借用部分加一段：

> **可变性约定（当前版本）**：
> Sla 的 `&self` / `&T` 同时覆盖 Rust 的 `&self`/`&T` 与 `&mut self`/`&mut T`——**读写均允许**。
> 编译期不在 sla 源码层强制区分；SA Referee 在 lowering 后根据 store 操作动态判定 `Locked_Read` / `Locked_Mut`。
>
> **从 Rust 迁移**：
> - Rust `fn inc(&mut self)` → Sla `fn inc(&self)`
> - Rust `let mut x = 5` → Sla `let x = 5`
> - Rust `&mut x` → Sla `&x`
>
> **未来版本**（sa3d ECS 上线时）将引入 `&mut T` 与 `&mut self` 作为独立借用类型，用于支持 ECS 并行调度器与库生态 API 契约。届时会提供自动化迁移工具。

#### B. 在 `sa_plugin_sla/README.md` Rust 兼容性表更新对应行（已部分完成）

#### C. 写一条"Phase 2 触发条件"作为团队 backlog 项：

> **mut 引入触发条件**：
> 1. sa3d ECS Phase 6A 启动（必需）
> 2. 或：第三方 sla 库生态形成 ≥ 5 个独立作者
> 3. 或：LLM Agent 大规模生成 sla 代码出现 ≥ 10% 的借用相关错误率
>
> 满足任一即触发 Phase 2 工程量约 3-4 周。

### 2.3 可选（Rust 粘贴友好）

parser 加 `--accept-rust-mut` flag（默认 off）：

| Rust 写法 | parser 行为 |
|----------|------------|
| `let mut x = 5` | 接受，当作 `let x = 5` 处理，无警告 |
| `&mut x` | 接受，当作 `&x` 处理，无警告 |
| `fn foo(&mut self)` | 接受，当作 `fn foo(&self)` 处理，无警告 |
| `fn foo(v: &mut Vec)` | 接受，当作 `fn foo(v: &Vec)` 处理，无警告 |

**为什么 flag 默认关**：避免让 sla 主线背"沉默吸收 mut 但实际不强制"的债。开 flag 是用户显式接受这个 trade-off。

**工程量**：3-5 天。lexer 加 `mut` token + parser 加四处吸收。**Phase 1 可选项**。

---

## 3. Phase 2：sa3d ECS 启动前的工程

### 3.1 触发场景

sa3d ECS 的 system 函数需要静态 read/write 集：

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

**这是 Phase 2 的硬触发**。

### 3.2 引入

| 项 | 形式 | 行为 |
|---|------|------|
| `&mut T` 借用类型 | `fn push(v: &mut Vec, item: int)` | sla 借用检查器执行独占性 |
| trait 方法 `&mut self` | `trait Push { fn push(&mut self, item: int); }` | 强制契约，所有 impl 必须遵守 |
| UFCS 第三类规则 | `v.push(1)` 自动改写 `push(&mut v, 1)` | 与 `&` / 值传递并列 |
| 借用冲突精确报错 | sla 源码层定位 + 明确 mut/immut 提示 | LLM 自修复闭环受益 |

### 3.3 不引入（永远）

| 项 | 原因 |
|---|------|
| `let mut x = 5` | 与 sla `let = 可变` 冲突，沉默误导 |
| 反转 sla `let` 默认 | 破坏性，所有现有代码失效 |
| `mut` 修饰 let 绑定 | 同上 |
| `&mut` 在 lowered SA 中独立存在 | SA 哲学不变，Referee 仍动态判读写 |

### 3.4 自动化迁移工具

`sa migrate sla-add-mut`（Phase 2 同期产出）：
- 扫描所有 `.sla` 文件
- 检测 `&self` 方法 body 内是否有 `self.x = ...` / `self.x += ...` / `store self+...` 操作
- 有 → 自动改成 `&mut self`
- trait 声明同步改 `&mut self`
- 调用方 `v.method()` 不变（UFCS 自动改写吸收）
- 工程量 1-2 周

### 3.5 工程量

| 任务 | 估时 |
|------|------|
| Lexer：识别 `mut` token（如 Phase 1 已做，跳过） | 0 / 0.5 天 |
| Parser：`&mut T` 类型解析、`&mut self` 解析 | 2 天 |
| AST：`Type::RefMut(Box<Type>)` 节点 | 1 天 |
| 类型检查器：`&mut T` 独立类型，UFCS 第三类改写 | 1 周 |
| 借用检查器：mut/immut 双轨独占性 | 1-2 周 |
| 错误信息：mut/immut 冲突精确报错 | 3-5 天 |
| codegen：`&mut T` lowered 为 SA `&` | 1 天 |
| 自动化迁移工具 `sa migrate sla-add-mut` | 1-2 周 |
| 单元测试 + 集成测试 | 1 周 |
| 文档更新（含迁移指南） | 3-5 天 |

**总计：4-5 周一人**。

---

## 4. Phase 3：库生态形成时

### 4.1 触发场景

- 多个独立作者发布 sla 包
- 借用错误需要在 sla 源码层精确报告（不能让用户去看 SA Referee 寄存器号）

### 4.2 升级内容

- 借用检查器从"defer 给 SA Referee"升级到全函数局部分析
- 错误信息格式：`error[SLA-BC-042]: cannot borrow x as mutable because it is also borrowed as immutable at line 12`
- 跨函数借用契约校验（基于 `&mut T` 签名）

### 4.3 工程量

约 4-6 周。**不在当前 backlog**，触发再说。

---

## 5. 实测：当前 sla `&self` 约定的有效范围

| 场景 | 约定够用？ | 证据 |
|------|---------|------|
| 单 entity 方法调用 | ✅ | `demos/rosetta/59_method_counter` |
| trait 静态分发 | ✅ | `demos/rosetta/07_trait_vtable` |
| 状态机模式 | ✅ | `demos/rosetta/40_impl_block_state` |
| 简单 builder | ✅ | `demos/rosetta/55_builder_pattern` |
| 关联函数 | ✅ | `demos/rosetta/17_associated_fn` |
| 闭包捕获 | ✅ | `tests/test_unit_closures.sla` |
| 多借用冲突 | ⚠️ 当前约定允许过松，但 SA Referee 兜底 | — |
| 并行 ECS 调度 | ❌ 调度器拿不到静态 read/write 集 | Phase 2 触发 |
| 公开库 API 契约 | ❌ 用户看签名不知道是否会改 | Phase 3 触发 |

**当前所有用例 sla `&self` 约定够用**。Phase 2/3 才有真实痛点。

---

## 6. Phase 2 引入时的兼容性策略

### 6.1 默认接受旧写法

引入 `&mut T` 后，旧写法 `fn inc(&self) { self.x = ...; }` **仍然合法**——但视为"未声明可变性"，借用检查器按当前 sla 约定（保守允许）处理。

**好处**：现有代码不破。

### 6.2 推荐升级到新写法

`sa sla check --warn-implicit-mut` flag：扫描函数 body 内有 store 但签名是 `&self` 的方法，发警告：

```
warning [SLA-IMPLICIT-MUT]: method `inc` mutates `self` but signature is `&self`.
  Consider changing to `&mut self` for explicit contract.
  --> example.sla:42:12
```

### 6.3 升级路径

```
Phase 2 启动 → sa migrate sla-add-mut → 全代码库自动升级
                    ↓
              检查 + 测试通过
                    ↓
              sa sla check --strict-mut（v0.3+）禁止隐式 mut
```

---

## 7. 关键洞察：sla `&self` 约定是 SA 哲学的延伸

SA 设计哲学（faq.md §所有权与借用）说：
> 共享读 vs 独占写由 Referee 在**运行时上下文**内动态决定，不在语法层区分。

**sla 当前的 `&self` 涵盖读写约定，正是这条哲学在 sla 层的体现**。Phase 1 维持这个约定是**与 SA 哲学一致**的。

Phase 2 引入 `&mut` 的真实理由不是"sla 与 SA 哲学不一致"，而是**ECS 并行调度器需要静态 read/write 集**——这是工程现实，不是哲学问题。

**所以 Phase 2 引入 `&mut` 不是哲学转向**，而是为特定工程场景（ECS 调度）补能力。SA 层面 lowered 仍是 `&`，物理哲学不变。

---

## 8. 与之前文档的一致性修正

### 已撤回 / 修正

| v0.1 说法 | v0.2 修正 |
|----------|---------|
| "立即引入 `&mut T`" | "Phase 2 sa3d ECS 启动前引入" |
| "trait 契约缺失致命" | "未来 ECS 场景才致命；当前 demo 无影响" |
| "Phase 1 改 parser/checker/codegen" | "Phase 1 仅文档化约定 + 可选 parser 容错" |
| "3-4 周一人立即开工" | "Phase 1 工程量约 0.5-1 周（仅文档 + 可选 flag）；Phase 2 工程量 4-5 周（触发时再做）" |

### 不受影响

| 部分 | 状态 |
|------|------|
| `let` 默认可变 | 不变 |
| `const` 不可变 | 不变 |
| 不引入 `let mut` 写法 | 不变（与 sla 现状冲突，永久不引入）|
| `&mut T` 与 `&T` lowered 为 SA `&` | 不变 |
| Phase 2 工程量估计 4-5 周 | 不变 |

### 联动文档调整

| 文档 | 调整 |
|------|------|
| `sla_language_specification_cn.md` §6 | Phase 1 加"`&self` 涵盖读写"约定说明；Phase 2 时再加 `&mut T` 章节 |
| `sa_plugin_sla/README.md` Rust 兼容性 | 把"`&mut T` 立即引入"改成"Phase 2 引入" |
| `sa3d_ecs_api_design_cn.md` | 加注释"trait `&mut self` 在 sa3d ECS Phase 6A 启动时同步引入" |
| `bevy_ecs_equivalence_analysis_cn.md` | "Sla 编译器需要的能力"列表把 `&mut T` 移到"Phase 2 前置"项 |
| `bevy_fast_sla_roadmap_cn.md` | Milestone 1-3 不需要 mut；Milestone 4（Bundle/Resource）启动前补 mut |
| `sla_migration_stepbystep_cn.md` | Phase 0 sla 编译器 probe 中 mut 相关 probe 推迟到 Phase 5/6 之前 |

---

## 9. 一句话总结（v0.2）

**Phase 1（现在）**：sla `&self` 同时覆盖读写约定运行良好（实测 demo 证实），**不动语言层**，只文档化约定 + 可选 parser 容错（约 0.5-1 周）。

**Phase 2（sa3d ECS Phase 6A 启动前）**：引入 `&mut T` + trait `&mut self`（ECS 调度器需要静态 read/write 集做并行），4-5 周工程量，配套自动化迁移工具。

**永久不引入**：`let mut x` 写法（与 sla `let = 可变` 现状冲突）。

**v0.1 → v0.2 修订**：从"立即引入 mut"修正为"按工程触发引入"。诚实地承认 v0.1 是基于假想未来痛点的过度反应，实测 demo 后纠正。
