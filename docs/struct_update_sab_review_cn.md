# Struct Update (`..base`) 直接 SAB 实现评估与改进方案

评估对象：`src/sab_codegen.zig` 的 `genStructLiteral`（当前已加入 `update_expr` 分支，行号约 5933-5973），
参照 SA-text 参考实现 `src/codegen.zig` 的 `genStructLiteralInto`（行号约 7582-7686）。

目标 fixture：`tests/test_unit_struct_update.sla`（Phase 5，聚合更新/复制/drop 语义）。

## 当前状态

2026-07-02 追加：后续 Phase 5 follow-up 已完成。`StructLiteralFieldTransfer` 已加入 `src/lowering_rules.zig`，SA-text 与 direct SAB 都消费同一个 direct/deep-copy/move 字段转移策略；direct SAB 已移除安全 pointer-backed update 字段的显式收窄。新增 `tests/test_unit_struct_update_pointer_backed.sla` 覆盖 `Vec<i32>` 未触及字段在 `..base` 下移动保留，dev-mode direct SAB no-fallback 与 SA-text parity 均通过；全量 host no-fallback sweep 为 72/72。下面原评估保留为历史背景。

- `tests/test_unit_struct_update.sla` 在 dev 模式下已通过：
  - `SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_struct_update.sla --test-backend sab --jobs 1 --trace-panic` → 2/2 passed。
  - `SA_PLUGIN_DEV=1 sa sla test tests/test_unit_struct_update.sla --test-backend sa --jobs 1 --trace-panic` → 2/2 passed。
- `zig build --summary all` 通过。
- SAB 现在通过 `lowering_rules.planStructLiteralField` 消费共享的字段计划（`.explicit` / `.update` 两种 source），这一点符合 Y 型架构要求，是正确方向。

结论：**当前 fixture 的标量场景已经正确通过**，但实现存在与 SA-text 的语义分叉和潜在的所有权/别名缺陷，且释放/所有权策略仍是 emitter-local，未收敛到共享规则。以下为需要其他线程修正的点，按优先级排列。

## 问题一（正确性/别名，最高优先级）：update 路径对指针型未触及字段做浅拷贝后又释放

当前 `.update` 分支：

```zig
.update => {
    const src = update_reg orelse return Error.UnsupportedSabDirectFeature;
    const loaded = try self.intern(try self.newTmp());
    try self.emitLoad(loaded, src, layout.offset, prim);
    try self.emitStore(dst, layout.offset, loaded, prim);
    if (!self.isLocalReg(loaded)) try self.emitRelease(loaded);
},
```

对于指针型字段（`Vec`、`String`、`Box`、嵌套 struct 等，`prim == .ptr`）存在两个叠加缺陷：

1. **浅拷贝别名**：`load` 出来的是指针，`store` 进 `dst` 后 `dst` 与源 `base` 的该字段指向同一块堆内存。后续任一方在作用域结束被自动 release，都会导致另一方悬垂 / double-free。
2. **拷贝后立即释放**：`loaded` 恒为新 tmp，`isLocalReg(loaded)` 恒为 false，因此**无条件** `emitRelease(loaded)`。这会释放 `dst` 刚刚存入的那个指针，直接造成 `dst` 该字段悬垂。

当前 fixture 全部字段是 `i32` 标量，release 标量寄存器是惰性/无害的，所以掩盖了这个问题。一旦有指针型未触及字段就会崩。

对照 SA-text（`genStructLiteralInto`，行 7605-7609）：

```zig
const loaded_reg = try self.newTmp();
// load ... store ...
if (callArgNeedsRelease(update_expr)) try self.emitRelease(loaded_reg);
```

SA-text 仅当 **update 源表达式本身是临时值**（`callArgNeedsRelease(update_expr)` 为真）时才释放已加载字段；当 `..old_item` 的 `old_item` 是局部/参数标识符时不释放。SAB 的无条件释放与之分叉。

### 建议修正

- 释放条件对齐 SA-text：把 `if (!self.isLocalReg(loaded)) try self.emitRelease(loaded);` 改为仅在 `lowering_rules.callArgNeedsRelease(update_expr.?)` 为真时释放。
- 对指针型（`prim == .ptr`）未触及字段，浅拷贝语义本身不安全。在没有共享的深拷贝/移动计划之前，建议 **显式收窄支持面**：当 `.update` 分支遇到 `layout.ty` 为指针型（struct / array / Vec / String / Box 等非 Copy 标量）字段时返回 `Error.UnsupportedSabDirectFeature`，让缺口显式失败而不是静默产出别名 IR。这样符合 tasks.md「不要把移动符号变成静默不支持」的原则——用显式 fixture 记录待办。
- 待 Phase 5 的共享聚合 update/copy/drop 计划落地后，指针型字段走深拷贝或明确的移动语义（见问题三）。

## 问题二（正确性/参数，中优先级）：`.explicit` 分支缺少 copy-struct 深拷贝

SAB 的 `.explicit` 分支：

```zig
.explicit => {
    const value = plan.value orelse return Error.UnsupportedSabDirectFeature;
    const value_reg = try self.genExpr(value);
    try self.emitStore(dst, layout.offset, value_reg, prim);
    try self.releaseExprResultIfNeeded(value, value_reg);
},
```

SA-text 对显式字段有额外分支（行 7675-7679）：当 `value` 是 `identifier` 且字段类型是 copy-struct（`typeIsCopyStruct`）时，做 `genCopyValueInto` 深拷贝再存。SAB 缺这一步，会把 copy-struct 局部变量的指针直接浅拷贝进 `dst`，与 SA-text 分叉，并再次引入别名。

### 建议修正

- 在 `.explicit` 分支复用已有的 `genCopyValue`（SAB 已有该函数，行约 5975）：当 `value.* == .identifier and self.typeIsCopyStruct(field.ty)` 时，`genExpr` 得到源指针后调用 `genCopyValue` 深拷贝，再 `emitStore` 拷贝结果。
- 需要拿到该字段的 AST 类型 `decl_field.ty`（`plan` 目前只带 `layout`，可直接用 `decl_field.ty`，因为循环变量就是 `decl_field`）。

## 问题三（架构/Y 收敛，中优先级）：update 字段的所有权/释放策略仍是 emitter-local

`tasks.md` 的架构边界要求：结构体 update/copy/drop 的语义决策放在
`src/lowering_rules.zig` 的共享聚合布局/update 规则或 typecheck 元数据里，
SAB 只从计划里发结构化 load/store，不自造聚合更新语义。

现状：字段的**布局与来源分类**已共享（`planStructLiteralField` 给出 `.explicit`/`.update` 与 `layout`），
但**每个字段是否深拷贝、是否释放、指针型字段如何处理**这套所有权策略在 SA-text 和 SAB 里各写了一份且不一致。这正是 tasks.md 中「若只修直接 SAB 尾巴、却把 lowering 决策留在 `lowering_rules.zig` 之外，则记为部分 bug fix，Y/shared 任务保持 open」的情形。

### 建议修正

在 `lowering_rules.zig` 的 `StructLiteralFieldPlan` 上补充所有权决策字段，使两个 emitter 消费同一契约，例如：

- `needs_copy: bool`——该字段是否需要深拷贝（copy-struct 且来源是标识符）。
- `field_ty: *const ast.Type`——字段 AST 类型（供 emitter 判断指针型 / copy）。
- update 源字段的 `release_loaded: bool`——是否释放已加载字段（等价于 SA-text 的 `callArgNeedsRelease(update_expr)`）。
- `is_pointer_backed: bool` 或直接暴露一个 `updateFieldPolicy(...)`，让「浅拷贝 vs 深拷贝 vs 不支持」成为共享判定。

然后 SA-text 的 `genStructLiteralInto` 与 SAB 的 `genStructLiteral` 都改为从计划读取这些决策，删掉各自内联的 `typeIsCopyStruct` / `callArgNeedsRelease` 判定分叉。这样才能把该 slice 记为 Y/shared 100% 而非部分 bug fix。

## 问题四（边界，低优先级）：union / ManuallyDrop 字段

- SAB 在入口 `if (decl.is_opaque or decl.is_union) return Error.UnsupportedSabDirectFeature;` 直接拒绝 union，行为安全（显式不支持），无需立即处理。
- SA-text 对 union 及 `ManuallyDrop` 字段有专门分支（行 7614-7647、7662-7674）。若后续有 fixture 需要 struct-update 叠加 union/ManuallyDrop，应在共享计划里表达，而非在 SAB 复制 SA-text 的分支。当前无 fixture，保持显式不支持即可，但需在 tasks.md 记一条带 fixture 的待办。

## 建议的验证门（修正后其他线程需跑）

- `zig fmt --check src/sab_codegen.zig src/lowering_rules.zig src/codegen.zig`
- `zig build --summary all`；`zig build test --summary all`
- `sa plugin install --dev .`；`SA_PLUGIN_DEV=1 sa sla help`
- 焦点：`SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_struct_update.sla --test-backend sab --jobs 1 --trace-panic`（应 2/2）
- SA-text parity：`SA_PLUGIN_DEV=1 sa sla test tests/test_unit_struct_update.sla --test-backend sa --jobs 1 --trace-panic`（应 2/2）
- 若补充了指针型未触及字段的显式不支持，请新增一个带 `Vec`/`String`/嵌套 struct 未触及字段的 fixture 验证「显式失败」而非静默别名，并在 tasks.md 登记为 Phase 5 待办。
- 完成后的守卫回归：`sets`、`rc_dyn_trait`、`var_comprehensive`、assignment cleanup、`pkgjson`、RefCell struct payload、trait static dispatch，以及 `/home/vscode/projects/sla_ecs/lib/parallel.sla`。
- 全量 dev 模式 no-fallback sweep（Phase 9 命令），记录 pass/total 到 `progress.md` 与 `tasks.md`。当前 fixture 已通过，预期从 62/69 → 63/69（需实跑确认，因有并发修改）。
- 触碰 call/store 后跑 disasm 守卫：`sa sla sab disasm <latest.sab> | rg 'call .*@[^" ]+\('` 应无匹配。

## 优先级小结

1. 问题一（update 指针型字段浅拷贝+误释放）：正确性缺陷，最高优先。最小修正=对齐 SA-text 释放条件 + 指针型未触及字段显式收窄。
2. 问题二（explicit copy-struct 深拷贝缺失）：与 SA-text 分叉，复用 `genCopyValue` 补齐。
3. 问题三（所有权策略收敛到共享 `StructLiteralFieldPlan`）：达成 Y/shared 100% 的前提。
4. 问题四（union/ManuallyDrop）：保持显式不支持，登记待办即可。

标量场景已可作为完成回归；但在问题一、二修正前，不建议把该 slice 报为 Y/shared-lowering 100%，只能报为标量子集通过。

## 下一步计划（修完上述 bug 之后）

以下是把 struct-update slice 收尾、并继续推进 Phase 5 → Phase 9 的建议顺序。每一步都遵循 `tasks.md` 的完成定义：本地 build/test → 焦点 dev no-fallback → SA-text parity → 完成守卫回归 → 全量 sweep → `sa plugin install --dev .` / `SA_PLUGIN_DEV=1 sa sla help` → `parallel.sla` → disasm 守卫 → docs 同步 → `git diff --check` → 提交。

### 步骤 0：收尾 struct-update slice（先做，闭环当前 slice）

- 按问题一、二完成修正；按问题三把所有权决策上移到 `StructLiteralFieldPlan`。
- 跑「建议的验证门」全套。sweep 预期 62/69 → 63/69（需实跑确认，有并发修改）。
- 更新 `tasks.md` / `progress.md` / `current_plan.md`：
  - 在 62/69 失败矩阵里把 `test_unit_struct_update.sla` 从 open 勾成 done。
  - 追加一条 Completed Slice Evidence Ledger（列出提取的共享契约、删除/委托的 emitter-local 分支、证明 no-fallback 的 fixture、跑过的 SA-text parity）。
  - 用标准报告格式：`Feature: struct update 100%; Y/shared-lowering: 79% -> ~80%; direct SAB fallback-removal: 92% -> ~93%; no-fallback sweep: 63/69; host gate: passed; commit: <hash>`。
- 提交这一个已验证 slice。**若指针型未触及字段只做了「显式收窄不支持」而未实现深拷贝**，则报为标量子集完成，并在 tasks.md 留一条带 `Vec`/`String`/嵌套 struct fixture 的 Phase 5 待办，不把 Y/shared 记满。

### 步骤 1：`test_unit_spaceship_cmp.sla`（Phase 5，建议紧接 struct-update）

- 选它做下一个的理由：与 struct-update **共享同一批聚合/派生布局规则**（`@derive(ord)` 的 `SortKey` 逐字段字典序比较，正好复用刚上移到共享计划的字段布局/遍历逻辑），改动面集中在 operator/派生比较。
- 形态：`<=>` 返回 `Ordering`；标量整数比较 + 派生 struct 字典序比较 + `Ordering` 的 `is_lt/is_eq/is_gt/reverse/then` 方法（后者来自 `sla_std/cmp.sla`）。
- 架构落点：`Ordering` 应走 std-surface 元数据 + `sla_std/cmp.sla` 宏，不在 SAB 里写 `Ordering` 类型名分支；派生 `ord` 的逐字段比较应作为共享的派生比较计划（`lowering_rules.zig`），两个 emitter 消费。
- 先分类：`SLA_SAB_TRACE_UNSUPPORTED=1 SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_spaceship_cmp.sla --test-backend sab --jobs 1 --trace-panic`，记录第一个 `UnsupportedSabDirectFeature` 的 stmt/expr 类型再动手。

### 步骤 2：`test_unit_derive_semantics.sla`（Phase 5）

- 与步骤 1 强相关：`@derive(copy, eq, ord, hash, debug)`。`copy`/`eq`/`ord` 的逐字段逻辑正好复用步骤 0、1 建立的共享派生布局/比较计划；`hash`/`debug` 需要各自的派生生成函数元数据。
- 架构落点：派生生成的 `eq`/`ord`/`hash`/`debug` 函数走共享派生计划 + std-surface 元数据；SAB 只从计划发结构化调用，不为 `hash`/`debug` 写库名分支。
- `copy` 语义要和步骤 0 问题二的 `genCopyValue` 深拷贝路径统一——同一个 copy-struct 契约。

### 步骤 3：`test_unit_enum_match.sla`（Phase 5，收尾聚合/枚举批次）

- 形态：带 payload 的 enum（`Message::Move { x, y }` vs 单元 `Message::Quit`）、`match` 提取 payload、分支 cleanup。
- 架构落点：共享 enum tag/payload 布局、match 提取、分支 cleanup、value merge policy（`tasks.md` Phase 5 已列）。这是 Phase 5 里最独立的一块，放最后收尾。
- 依赖前置：match 分支的 release/merge 状态可复用已完成的 `var_comprehensive` 分支 scoping 与 `genIfValue` 的 merge-release 逻辑。

> 完成步骤 1-3 后 Phase 5 退出，预期 Y/shared-lowering ~88-92%、direct SAB fallback-removal ~96%，sweep 从 63/69 推到 66/69。

### 步骤 4：Phase 6 协议迭代（`for_in_protocol` + `generic_for_in_protocol`）

- 两个 fixture 一起做：非泛型与泛型 `for in` 走**同一个**共享 iterator/protocol 计划（monomorphization 之后），覆盖 range/array/slice/Vec 形态、item 绑定所有权、循环 cleanup、break/continue release 状态。
- 完成规则：协议 dispatch 必须是数据/计划驱动，不在单个 emitter 里写类型名分支。预期 sweep → 68/69。

### 步骤 5：Phase 8 `test_unit_async_await.sla`（放最后）

- 依赖 call/std/control/import 全部稳定后再做。复用 std `Future`/task 元数据 + 共享状态机规则，不写 SAB-only async lowering。
- 若支持子集有限，允许显式记为「不支持面 + 具体 fixture 待办」，但要在 `progress.md` 写清。

### 步骤 6：Phase 9 fallback 移除 gate（终局）

- 目标 69/69 no-fallback（本地 + host 两套 sweep，不混计）；或每个剩余 fallback 都有带 fixture 的显式待办。
- 终局前完整跑：`zig fmt`、`zig build --summary all`、`zig build test --summary all`、`sa plugin install --dev .`、`SA_PLUGIN_DEV=1 sa sla help`、焦点 host no-fallback 回归、`parallel.sla`、本地全量 sweep、host 全量 sweep、`git diff --check`、docs 同步、逐 slice 提交。
- 完成定义：Y/shared-lowering 100%、tracked 语料 direct SAB fallback-removal 100%、宏/borrow/precedence 目标全绿、无意外 fallback 日志、`progress.md` 与 `tasks.md` 同步、已验证 slice 全部提交。

### 贯穿原则（每一步都适用）

- 每个 slice 只提交已过本地 + host 门的验证结果；探索性改动不提交。
- 每完成一个 fixture 就按标准模板报告四个百分比 + sweep 计数，并同步 `progress.md` / `tasks.md` / `current_plan.md`。
- 累计超过 10 个已验证 slice 未提交则停下来建议批量提交。
- 新语义一律进 `lowering_rules.zig` / 共享 frontend/typecheck / `std_surface.sla_meta` / `sa_std`，SAB 只消费契约——这是 Phase 5 之后每一步共同的架构红线。

---

## 巡视记录

> 每 10 分钟一次的代码巡视评估（session-only 定时任务，仅静态评估，不改代码）。

### 2026-07-01 首轮巡视（基线核对）

**代码状态**：`genStructLiteral` 已从行 5933 漂移到 5945，说明有并发改动。核对结果：本文档问题一、二、三**均已被并发线程采纳落地**。

- **问题一（update 指针型字段浅拷贝+误释放）已修**：`.update` 分支现在先判 `lowering_rules.structFieldIsPointerBacked(plan.field_ty)`，指针型未触及字段显式返回 `UnsupportedSabDirectFeature`；释放条件改为共享的 `plan.release_loaded and !isLocalReg(loaded)`，与 SA-text 的 `callArgNeedsRelease(update_expr)` 对齐。无条件误释放已消除。
- **问题二（explicit copy-struct 深拷贝缺失）已修**：`.explicit` 分支新增 `value.* == .identifier and typeIsCopyStruct(plan.field_ty)` 分支，走 `genCopyValue` 深拷贝再 store，与 SA-text `genCopyValueInto` 对齐。
- **问题三（所有权策略收敛到共享计划）已落地**：`StructLiteralFieldPlan` 新增 `field_ty: *const ast.Type` 与 `release_loaded: bool` 两字段；`planStructLiteralField` 填充（explicit → `release_loaded=false`；update → `release_loaded=callArgNeedsRelease(update_expr)`）。新增共享 `structFieldIsPointerBacked`。`lowering_rules.zig` 补了单元测试覆盖 `field_ty`/`release_loaded`。
- **问题四（union/ManuallyDrop）保持显式不支持**：入口仍 `if (decl.is_opaque or decl.is_union) return UnsupportedSabDirectFeature;`，安全。

**验证门实跑（dev 模式）**：

- `zig build --summary all` 通过。
- `zig build test --summary all`：**61/61 通过**（较基线 60/60 +1，新增的共享计划单测已生效）。
- `SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_struct_update.sla --test-backend sab`：**2/2 通过**。
- SA-text parity `--test-backend sa`：**2/2 通过**。
- 守卫回归：`test_unit_sets`（BTreeSet）2/2、`parallel.sla` 1/1 通过。

**评估意见**：

1. 三个核心修正已到位且方向正确（走共享 `StructLiteralFieldPlan`，未在 SAB 复制 SA-text 分支）。标量场景可作为完成回归。
2. **仍属「标量子集完成」**：指针型未触及字段是「显式收窄不支持」而非深拷贝/移动实现。按 `tasks.md` 原则，不应把该 slice 记为 Y/shared 100%；需在 `tasks.md` 留一条带 `Vec`/`String`/嵌套 struct 未触及字段的 Phase 5 待办 fixture。**建议下一步补一个该形态的负向 fixture，验证「显式失败」而非静默别名。**
3. **待确认（本轮未跑）**：全量 dev no-fallback sweep 是否已 62/69 → 63/69；`git diff --check`；docs（`progress.md`/`tasks.md`/`current_plan.md`）是否已同步这条 Completed Slice Evidence。这些应在收尾提交前由实现线程补跑。
4. **观察点**：`structFieldIsPointerBacked` 与 `lowering_rules.zig` 中另一处相似判定（旧 grep 曾见 `.pointer/.borrow/.user_defined/.tuple/.array` 的重复分支）语义高度重叠，建议后续合并为单一 helper，避免两处漂移。

### 巡视记录（追加）

- 时间点：跟踪文件同步核对。
- 实测：全量 dev 模式 no-fallback sweep = **63/69**（struct_update 已进 passing set，无回归），剩余 6 个失败为 async_await / derive_semantics / enum_match / for_in_protocol / generic_for_in_protocol / spaceship_cmp。
- 同步动作：并发线程已更新 `progress.md` 与 `current_plan.md`（均为 63/69、Next Slice = enum_match），但 `tasks.md` 仍停在 62/69。已把 `tasks.md` 的当前状态引用从 62/69 同步到 63/69：recovery point、Completed-slice 条目、Remaining Failure Ownership Matrix 标题与 struct_update 勾选、Phase 5 target failures、Phase 9 drive-from 目标、CN 历史矩阵指针、Slice 5A 均已更新。历史 ledger（Set slice 的 62/69、更早的历史快照）保持原值不动。
- 新增显式待办：Phase 5 段落补入「pointer-backed struct-update fields」独立任务，带 `Vec`/`String`/嵌套 struct 未触及字段的负向 fixture 要求，作为多处引用的落点。
- 诚实度提醒：当前 struct_update 为**标量子集完成**——指针型未触及字段是显式 `UnsupportedSabDirectFeature` 收窄，不是完整实现；Y/shared-lowering 约 80%、fallback-removal 约 93% 的数字已在三份文件中一致标注该 caveat。
- `git diff --check` 干净。

## 下一个 slice 预评估：`test_unit_enum_match.sla`（Phase 5，仅评估未改代码）

评估时间：2026-07-01。本节是对下一个 active slice 的静态预评估，供实现线程参考，我未改任何代码。

### 复现的第一个缺口

命令：
```
SA_PLUGIN_DEV=1 SLA_SAB_TRACE_UNSUPPORTED=1 SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_enum_match.sla --test-backend sab --jobs 1 --trace-panic
```
首个失败：
```
[sab-direct] stmt match_stmt failed: UnsupportedSabDirectFeature
[sab-direct] func process_msg block failed: UnsupportedSabDirectFeature
```
即 direct SAB 对 `match` 语句/表达式与带 payload 的 `enum` 完全没有 lowering（`sab_codegen.zig` 无任何 match/enum 处理分支）。

### fixture 形态

- `enum Message { Quit, Move { x: int, y: int } }`——单元变体 + 带命名字段 payload 的变体。
- `Message::Move { x: 10, y: 20 }` / `Message::Quit`——enum literal 构造（`ast.EnumLiteral`）。
- `match msg { Message::Quit => {...}, Message::Move { x, y } => {...} }`——match 语句，每个 case 是 `return`（分支全 terminate，属于 void-match，无 value merge）。

因此这个 fixture 是 **enum + match 的最小子集**：无 guard、无 value-producing match、无 Option/Result 特化路径。

### SA-text 参考实现（已存在，作为 Y 对照）

`src/codegen.zig` 已有完整实现，SAB 应对齐其语义（不是复制文本）：

- 布局 helper（行约 2530-2584）：
  - `enumVariantIndex`——变体 → tag 序号。
  - `enumVariant` / `enumFieldLayout`——payload 字段布局，**payload 从 offset 8 开始**（前 8 字节是 i64 tag），字段按 size 对齐累加。
  - `enumSize`——`max(8 + max_payload, 8)`，tag(8) + 最大变体 payload。
- enum literal 构造：alloc `enumSize`，`store base+0 = tag(i64)`，逐字段 `store base+offset`。
- match lowering（`genMatchExpr`，行 7781-7891）：
  - `load val+0 as i64` 取 tag → 与每个 case 的 tag 常量 `eq` → `br cond -> case_i, next` 条件跳转阶梯。
  - case body 内按 `enumFieldLayout` 把 payload 字段 `load` 进 binding。
  - 全不匹配落到 `no_match_label: panic(1)`。
  - value-producing match 用 `result_slot` alloc + `genBlockTailValueStore` + merge label 收敛；本 fixture 是 void-match，走 `genBlock`。
  - 分支 cleanup：非 terminate 的 case 结尾释放未被 body 消费的 binding；guard 失败路径释放 guard 与 binding。

### 建议的 Y-shared 落点

按 tasks.md Phase 5 边界（enum tag/payload 布局、match 提取、分支 cleanup、value merge 归共享规则；SAB 只从计划发结构化 compare/branch），建议：

1. **共享布局规则进 `src/lowering_rules.zig`**：把 `enumVariantIndex`、`enumVariant`、`enumFieldLayout`（payload base=8 的偏移规则）、`enumAbiSize` 提取为共享函数，SA-text 与 SAB 都消费——与已完成的 struct/tuple/array ABI 共享方式一致。注意现有 SA-text `enumFieldLayout` 用 `typeSize`/`alignOffset`（已是 `lowering_rules` 的 `abiTypeSize`/`alignAggregateOffset`），迁移成本低。
2. **共享 match 计划**：定义一个 `EnumMatchPlan`（或 `MatchCasePlan` 列表），记录每个 case 的 tag、payload binding 的 `{offset, prim, name}`、是否 terminate、是否 value-producing、guard 有无。SA-text 与 SAB 都从该计划发射，避免 SAB 再写一份 tag/offset 判定。
3. **SAB 尾巴**：用已有的结构化原语实现——`emitLoad(tag, val, 0, .i64)` → `emitOp(.eq)` → `.br` 指令 → payload `emitLoad` 到 binding 寄存器 → case body `genBlock`/`genScopedBlock`（复用已完成的分支 scoping snapshot/restore，见 `var_comprehensive` slice）→ 不匹配 `emitPanicCode(1)`。value-match 用 alloc slot + tail-store + merge（复用 `genBlockTailValueStore` 的 SAB 版思路）。
4. **enum literal 构造**：SAB `genEnumLiteral`——alloc `enumAbiSize`，`emitStore(base,0,tag,.i64)`，逐字段 `emitStore(base,offset,val,prim)`，与 `genStructLiteral` 同构。

### 分步实现建议（供实现线程）

- 先做 enum literal 构造 + 单元/payload 变体布局（无 match），加最小 fixture 验证 `Message::Move{...}` 能 alloc/store。
- 再做 void-match（本 fixture 的形态：全 `return` 分支），tag 阶梯 + payload 提取 + panic 兜底。
- value-producing match 与 guard 作为紧接的增量（`enum_match` fixture 不需要，但 Phase 5 完成规则要求 SA-text/SAB 对 value merge 一致；若本 slice 只做 void-match，需在 tasks.md 记一条 value-match/guard 的显式待办）。

### 建议验证门（实现后）

- 分类：上面的 `SLA_SAB_TRACE_UNSUPPORTED=1` 命令确认缺口逐个消失。
- 焦点：`SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_enum_match.sla --test-backend sab --jobs 1 --trace-panic`（应 2/2）。
- SA-text parity：同 fixture `--test-backend sa`（应 2/2）。
- 完成守卫回归：`struct_update`、`sets`、`rc_dyn_trait`、`var_comprehensive`、assignment cleanup、`pkgjson`、RefCell、trait static dispatch、`/home/vscode/projects/sla_ecs/lib/parallel.sla`。
- `zig test src/lowering_rules.zig`（若新增共享 enum 布局/match 计划，补单元测试）、`zig build test`、全量 dev sweep（预期 63/69 → 64/69）、`sa plugin install --dev .`、`SA_PLUGIN_DEV=1 sa sla help`、disasm 守卫（match 不产生 call，可略但建议跑一次）、`git diff --check`、docs 同步。

### 与后续 slice 的衔接

`enum_match` 建立的共享 enum 布局规则会被 `derive_semantics`（`@derive` 生成的 eq/ord/hash/debug 需遍历 enum/struct 布局）与 `spaceship_cmp`（派生 ord 逐字段/逐变体比较）复用，因此建议按文档「下一步计划」的顺序：`enum_match` → `derive_semantics` → `spaceship_cmp` 收尾 Phase 5。

### 巡视记录 2026-07-01（末轮，巡视任务已停止）

本轮检出 struct_update 的实现改动已落在工作区（未提交）：`src/lowering_rules.zig` +32、`src/sab_codegen.zig` +109。逐行核对结论：

- 问题一（update 指针型字段浅拷贝+误释放）：**已修**。`.update` 分支现先判 `structFieldIsPointerBacked(plan.field_ty)`，指针型未触及字段显式返回 `UnsupportedSabDirectFeature`（不再产出别名 load/store）；标量字段的 `loaded` 仅在 `plan.release_loaded and !isLocalReg(loaded)` 时释放，对齐 SA-text 的 `callArgNeedsRelease(update_expr)`。误释放已消除。
- 问题二（explicit copy-struct 深拷贝缺失）：**已修**。`.explicit` 分支对 `value.* == .identifier and typeIsCopyStruct(plan.field_ty)` 走 `genCopyValue` 深拷贝，与 SA-text `genCopyValueInto` 一致。
- 问题三（所有权收敛到共享计划）：**已落地**。`StructLiteralFieldPlan` 新增 `field_ty` 与 `release_loaded`（带文档注释），`planStructLiteralField` 在两种 source 下都填这两个字段；新增共享 `structFieldIsPointerBacked`。单元测试 `shared struct literal update field plan` 已加 `field_ty`/`release_loaded`/`structFieldIsPointerBacked` 断言。
- 覆盖面：`genStructLiteral` 与 `genMacroStructLiteral` **两个** emitter 都改造为消费共享计划，宏上下文用 `genMacroExpr` 物化，无遗漏分支。

无新分叉，无回归迹象。本轮实跑：`zig build --summary all` 通过；`zig test src/lowering_rules.zig` 9/9。

诚实度提醒（保持）：这是**标量子集完成**——指针型未触及字段是显式收窄不支持，非完整实现；tasks.md 已有独立 Phase 5 pointer-backed struct-update 待办追踪。三份跟踪文件均为 63/69、Y/shared ~80%、fallback-removal ~93%，带此 caveat，未夸大。

定时巡视任务（`4913a146`）已按指令停止。后续巡视改为按需手动执行。
