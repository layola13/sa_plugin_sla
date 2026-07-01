# 完成路线图与当前进度

> **文档版本**：v0.1 / 2026-07-01
> **状态**：基于 `tasks.md`、`progress.md` 和实际代码实现
> **关联**：[`architecture_cn.md`](./architecture_cn.md)、[`testing_and_verification_cn.md`](./testing_and_verification_cn.md)

---

## 1. 当前进度摘要（截至 2026-07-01）

| 维度 | 当前值 | 目标 | 完成度 |
|------|--------|------|--------|
| No-fallback sweep | **58/69** | 69/69 | **84%** |
| Y/shared-lowering | **72%** | 100% | **72%** |
| Direct SAB fallback-removal | **88%** | 100% | **88%** |
| 总进度（加权） | ~80% | 100% | **~80%** |

### 1.1 进度指标定义

- **No-fallback sweep**：`SLA_SAB_NO_FALLBACK=1` 下 `tests/test_unit_*.sla` 通过的数量。从初始 36/64 逐步增加到 58/69（过程中新增了 5 个测试文件）。
- **Y/shared-lowering**：通过 `lowering_rules.zig` 共享规则实现的降低逻辑占比。从 28% 增长到 72%。
- **Direct SAB fallback-removal**：不走 SA 兼容回退路径的 SAB 编译覆盖率。从 72% 增长到 88%。

### 1.2 演进轨迹

每个功能增量后的三个指标演变：

```
Slice                              Y/Shared   Fallback   Sweep
初始基线                             28%        72%       36/64
Y 型前端主干提取                      45%        72%       —
数组字段 ABI 收敛                     48%        73%       38/64
Dyn-borrow plan 消费                 50%        74%       39/64
静态分发符号收敛                      52%        76%       43/64
Vec index-assign metadata            54%        78%       45/64
定长数组解构                          55%        79%       46/64
Cell bool metadata                   56%        80%       47/64
Option 闭包方法                       58%        81%       48/64
智能指针/RefCell 收敛                 66%        85%       50/64
导入宏 (Phase 2A)                   72%        88%       58/69
```

---

## 2. 剩余 11 个失败的精确定位

每个失败的测试文件都有明确的 Phase 归属：

### Phase 3：调用/赋值（3 个失败）

| 测试文件 | 失败原因 | 影响 |
|----------|---------|------|
| `assign_move_cleanup` | `UseAfterMove next` — 移动/使用状态与赋值/循环清理的协调 | Phase 3 + Phase 5 交集 |
| `var_comprehensive` | 完整的共享调用、聚合拷贝、结果目标策略 | Phase 3 + Phase 5 |
| `rc_dyn_trait` | dyn-borrow/call materialization + Rc metadata | Phase 3 + Phase 4 |

### Phase 4：Std 元数据（3 个失败）

| 测试文件 | 失败原因 |
|----------|---------|
| `sets` | Set 集合操作（std surface metadata + sa_std macros） |
| `std_import` | 标准库导入解析 |
| `sla_import_nested_contract` | 嵌套合约导入 |

### Phase 5：聚合/枚举/Derive（4 个失败）

| 测试文件 | 失败原因 |
|----------|---------|
| `enum_match` | 标签/负载布局 + match 提取 |
| `derive_semantics` | derive 生成操作符/函数调用 |
| `struct_update` | 聚合更新/拷贝/丢弃布局 |
| `spaceship_cmp` | 比较/操作符分发 |

### Phase 6：协议/迭代器（2 个失败）

| 测试文件 | 失败原因 |
|----------|---------|
| `for_in_protocol` | 非泛型协议 lowering |
| `generic_for_in_protocol` | 泛型迭代器特化 |

### Phase 8：异步（1 个失败）

| 测试文件 | 失败原因 |
|----------|---------|
| `async_await` | async state-machine/Future/task |

---

## 3. 完成路线图：Phase 1-9

### Phase 0：运营规则 ✅ 已完成

- 确保 Y 型架构不变
- 建立验证门禁标准
- 建立进度报告模板

### Phase 1：借用、优先级和智能指针收敛 ✅ 已完成

**状态**：100%
**关键成果**：
- 共享智能指针辅助函数（`smartPointerType`、`associatedRuleNeedsUnderlyingSmartPointer`）
- RefCell borrow/borrow_mut 通过共享生命周期计划
- 指针支持的索引地址元数据（`VEC_GET_MUT_PTR_U64`）
- Rc/Arc clone 通过元数据 + 共享接收者物化
- 移除了临时 SAB-only `genRcArcCloneCall` 分支

**未决项**：
- 提取完整的共享地址/投影计划（`&field`、`&index`、`&*smart`、`&**chain`）
- 将 RefCell lifecycle 完全移至共享计划

### Phase 2：宏展开完成 ✅ Phase 2A 已完成

**状态**：2A（导入宏）100%，剩余宏收敛约 70%

**2A 成果**：
- 导入的 SA 表达式输出宏通过共享 Y 路径降低
- `ImportedMacroCallPlan` 在 `lowering_rules.zig` 中
- 直接 SAB 通过通用解码的宏片段路径降低任意导入的宏

### Phase 3：完整共享调用和参数物化计划 ← 当前焦点

**目标**：所有静态/外部/方法/宏展开调用共享一个调用计划
**预期进展**：Y/shared: 72% → 76%；Fallback: 88% → 90%；Sweep: 58/69 → 61/69

| 子任务 | 优先级 |
|--------|--------|
| `CallArgMaterializationPlan` 扩展（数组→切片借用、dyn 胖指针、拷贝结构体） | P0 |
| 调用结果目标计划（void、表达式值） | P0 |
| 参数 register 所有权和释放策略 | P0 |
| 目标失败：`assign_move_cleanup`、`var_comprehensive`、`rc_dyn_trait` | P0 |

### Phase 4：Std Surface 元数据泛化

**目标**：仅当失败测试证明需要时，添加或扩展元数据规则种类
**预期进展**：Y/shared: 76% → 84%；Fallback: 90% → 94%；Sweep: 61/69 → 64/69

| 子任务 | 优先级 |
|--------|--------|
| Set 集合操作元数据 | P0 |
| 标准库导入辅助函数 | P0 |
| Rc/dyn 元数据 | P1 |
| 智能指针方法维护 | P1 |

### Phase 5：聚合、枚举、Derive 和操作符语义

**目标**：结构体更新、枚举有效载荷布局、match 提取、派生相等/排序/哈希/调试、spaceship 比较和复制/丢弃清理策略
**预期进展**：Y/shared: 84% → 92%；Fallback: 94% → 96%；Sweep: 64/69 → 68/69

### Phase 6：协议降低和迭代

**目标**：通过共享迭代器/协议计划降低基本的和泛型的 `for in` 协议
**预期进展**：Fallback: 96% → 98%；Sweep: 68/69 → 69/69

### Phase 7：导入、包和标准解析对等性

**目标**：在前端主干中保持源展开、导入展开、包元数据、嵌套合约加载、外部被调用者解析、标准根解析和测试过滤共享

### Phase 8：Async/Await 和剩余运行时形状

**目标**：在调用/标准/控制流/导入阶段稳定后处理 async/await；重用共享 Future/task 表面元数据和状态机规则

### Phase 9：回退删除门禁

**目标**：完整的 no-fallback sweep 从 58/69 到 69/69

**完成定义**：
```
Y/shared-lowering: 100%
Direct SAB fallback-removal: 100%
No-fallback sweep: 69/69 (local) + 69/69 (host)
所有宏展开和借用/优先级目标已完成
progress.md 和 tasks.md 已同步
已验证的 commits 已完成
```

---

## 4. 执行顺序

从当前状态到 69/69 的推荐执行顺序：

```
1. Slice 2B — 纯宏收敛（关闭剩余宏展开缺口）
   ↓
2. Slice 3A — 调用/结果/赋值稳定化（3 个 Phase 3 失败）
   ↓
3. Slice 4A — Std 元数据批处理（3 个 Phase 4 失败）
   ↓
4. Slice 5A — 聚合/枚举/Derive/操作符批处理（4 个 Phase 5 失败）
   ↓
5. Slice 6A — 协议降低（2 个 Phase 6 失败）
   ↓
6. Slice 7A — 导入/包对等性
   ↓
7. Slice 8A — async 支持子集
   ↓
8. Slice 9A — 最终回退删除 → 69/69
```

---

## 5. 每个 Phase 的退出标准

| Phase | Y/shared | Fallback | Sweep | 备注 |
|-------|----------|----------|-------|------|
| Phase 1 | ~66% | ~85% | 50/64 | ✅ 已完成 |
| Phase 2 | ~76% | ~90% | 61/69 | 2A 完成 |
| Phase 3 | ~76% | ~90% | 61/69 | 调用计划 |
| Phase 4 | ~84% | ~94% | 64/69 | 元数据 |
| Phase 5 | ~92% | ~96% | 68/69 | 聚合/枚举 |
| Phase 6 | ~94% | ~98% | 69/69 | 协议 |
| Phase 7 | ~97% | ~99% | 69/69 | 导入 |
| Phase 8 | ~97% | ~99.5% | 69/69 | async |
| Phase 9 | 100% | 100% | 69/69 | ✅ 最终门禁 |

---

## 6. 关键技术债务

### 嵌入式本地分支

尽管大部分语义已共享，以下内容仍存在于 SAB-only 分支中，应移至共享规则：

- **地址/投影计划**：`&field`、`&index`、`&*smart`、`&**chain` 的 `genAddressOf` 行为尚未完全共享
- **RefCell lifecycle**：borrow/borrow_mut 句柄释放部分在 SAB 中独立复制

### 性能瓶颈

```
test_unit_vec_remove_direct.sla:
  direct SAB (带宏模板缓存):  257ms    ✅ 16x 加速
  direct SAB (无缓存):       4094ms   ❌ 瓶颈

parallel_table_erased.sla:
  SA-compatible flatten:      4.04s    ❌ 回退瓶颈
  SAB encode:                 5.22s    ❌ 最大单一瓶颈
  sa test:                   13.50s    ❌ SA 后端（宿主侧）
```

**核心矛盾**：直接路径（AST→SAB）非常快（24-257ms），但遇到不支持的特性就走回退路径（flatten 4s + encode 5s）。消除回退就是消除瓶颈。

---

## 7. 相关文档索引

| 文档 | 内容 |
|------|------|
| [`architecture_cn.md`](./architecture_cn.md) | Y 型架构、共享前端、降低规则层 |
| [`std_surface_metadata_cn.md`](./std_surface_metadata_cn.md) | Std surface 元数据格式规范 |
| [`testing_and_verification_cn.md`](./testing_and_verification_cn.md) | 测试编写、9 步验证门禁 |
| `tasks.md` | 完整的任务跟踪和失败归属矩阵 |
| `progress.md` | 功能增量进度记录 |
