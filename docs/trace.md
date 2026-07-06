# sa_plugin_sla 完成度评估报告

> 评估日期: 2026-07-05
> 基于对 `tasks.md`, `progress.md`, `current_plan.md` 及源代码的对照分析

---

## 概述

`sa_plugin_sla` 是一个 SLA→SAB 编译器插件，采用 Y 形架构：共享 `lowering_rules.zig` 分叉到 `codegen.zig`（SA 文本）和 `sab_codegen.zig`（SAB）。项目文档详细、测试覆盖充分（当前 tracked unit sweep 为 103 个测试文件、256 个测试用例），但文档的自我评估**系统性地过于乐观**。

## 2026-07-06 Issue 复核更新

本文件是 2026-07-05 的审计快照，其中部分条目已经被后续切片修复。当前复核结果：

- `docs/sab_scalar_param_cleanup_issue_cn.md` 的当前 compiler/host repro surface 已验证修复：新增 `tests/test_unit_scalar_param_cleanup_direct.sla` 覆盖 table-erased-like wrapper、`_auto` wrapper、unused scalar param consumed、`temporary().method()` receiver owner cleanup；direct SAB 参数退出 cleanup 现在区分 skip/consume/release，shared call-arg materialization 会释放临时 auto-borrow receiver，SA-text associated-target 用户方法调用传入 receiver-style auto-borrow 选项。验证包括 `zig build --summary all`、`zig build test --summary all` (85/85)、local/installed focused SA/SAB、borrow-temp 25/25、RefCell payload 7/7、local strict direct-SAB sweep 108/108 files、262/262 cases、official dev install/help、installed host `system_param_table_erased.sla` check/focused SA/SAB、`parallel.sla` strict direct-SAB 1/1。仓库已补 Apache-2.0 `LICENSE`，与 `sci` 对齐。
- `docs/result_entityitem_filter_cleanup_issue_cn.md` 的当前 host repro surface 已验证修复：新增 Result/EntityItem、Box raw-pointer、void fn-pointer、primitive `scan` reassignment focused regressions；local strict direct-SAB sweep 为 107/107 files、260/260 cases；official `sa plugin install --dev .` 和 `SA_PLUGIN_DEV=1 sa sla help` 通过；installed host `/home/vscode/projects/sla_ecs/tests/test_ecs_result_facades.sla` strict direct-SAB no-fallback 与 SA-text 均为 172/172；`parallel.sla` strict direct-SAB 1/1；borrow-temp 25/25、RefCell payload 7/7；SAB call-target disasm guard 无非法匹配。历史 filter `ecs_world_try_query_single returns one` 仍选中 0 个测试，因此只记录为 stale filter，不作为修复证据。
- `docs/sab_call_target_issue_cn.md` 的 SAB call target/argument 混合问题已验证修复；`parallel.sla` strict direct-SAB no-fallback 1/1 passed，SAB disasm 中 `@sla__ecs_parallel_sum_i32_chunk` 与参数分离，非法 `@.*(` call-target grep 无匹配。
- `docs/sa_std_macro_gap_audit.md` 涉及的 rosetta `104_if_let_chains` chained `if let` direct-SAB 缺口已验证修复；本次新增共享 `planLetPattern()` 分类，direct SAB strict no-fallback 和 SA-text host parity 均为 1/1 passed。更广泛 pattern surface 仍按后续真实 fixture 继续扩展。
- RefCell 共享 runtime import scan 有一个新子切片已完成：`if let` 链的所有 `IfLetCond.value` 现在都会参与 `exprNeedsRefCellRuntime()` 判定，避免第二个及后续 `&& let` 条件里的 RefCell 构造/借用被漏扫。完整 RefCell 生命周期规划仍保持开放。
- SA-text std macro/import pre-scan 也已补齐同类 `if let` 链缺口：`src/codegen.zig` 的 Box/Vec/Option/Result/Cell/Atomic/Async/TraitObject 等预扫描族、thread-spawn helper 收集、loop-counter/hoisted-allocation 预扫描和 identifier-consumption 检查现在都会遍历所有 `IfLetCond.value`。验证包括 `zig test src/codegen.zig --test-filter "if let chain scanner visits chained values"`、`zig build test --summary all` (85/85)、official dev install/help、host strict direct-SAB RefCell/borrow-temp/parallel 回归。更广泛 shared macro expansion/call planning 仍开放。
- Phase 3 call/materialization 的 array-to-slice borrow 子缺口已完成：`tests/test_unit_array_to_slice_call.sla` 覆盖 `&[T; N] -> &[T]` 普通 planned static call，local/host SA-text 和 strict direct-SAB no-fallback 均为 1/1，local/host full no-fallback sweep 更新为 103/103 files、256/256 cases。`src/sab_codegen.zig` 现在消费共享 `CallArgMaterializationKind.array_to_slice_borrow` 并发射 stack `Slice`/`SLICE_NEW`，`src/codegen.zig` 同步修复 `&[literal]` 临时底层数组释放。更广泛 call/result materialization、macro 参数地址语义、rosetta `116_va_list_variadic` 仍开放。
- 用户宏 SA-text focused parity 已完成：`tests/test_unit_user_macro_direct.sla` host SA-text 和 strict direct-SAB no-fallback 均为 2/2。覆盖当前 focused fixture 的参数替换、嵌套宏调用、宏本地 hygiene/block shadowing、聚合/index/static-call 表达式、borrowed field/index/deref args，以及 focused `&*boxed` / `&**nested_box` 地址形式。更广泛的共享宏 expansion/substitution contract 仍开放。
- `docs/struct_update_sab_review_cn.md` 的 tracked struct-update 问题已按后续记录修复并复核：`tests/test_unit_struct_update.sla` host SA/SAB 2/2，`tests/test_unit_struct_update_pointer_backed.sla` host SA/SAB 1/1。union/ManuallyDrop 等未跟踪边界仍不是已完成面。
- `docs/sla_compiler_issues_and_lua_refactor_diagnostics_cn.md` 中的 SCI macro body 逃逸、SLA import 输出路径相对化、SCI `PackageNotResolved` double-free 均已验证修复；`sa_lua` 测试空跑仍是应用/runtime 侧开放问题。
- 全局 100% 仍未完成。Full RefCell 生命周期、pointer-backed imported-macro aggregate alias semantics、完整 shared call/arg materialization、闭包/可调用语义、完整 async state machine、generic SCI fragment naming/boundary、以及更广泛真实语料覆盖仍保持开放。

---

## 一、核心指标对比

| 指标 | 文档声称 | 实际评估 | 偏差原因 |
|------|---------|---------|---------|
| Y 形共享降级比例 | ~98% | **~60-70%** | 两个后端仍有 ~18000 行不共享的发射代码（sab_codegen.zig ~8000 行 + codegen.zig ~10000+ 行），每个后端各自拥有寄存器分配、宏 hygiene、生命周期跟踪、清理顺序等专属逻辑 |
| direct SAB 无回退覆盖率 | 100%（102 文件） | **仅限被跟踪测试集** | 102 个精心选择的测试文件远不能代表完整 SLA 语言表面；`UnsupportedSabDirectFeature` 错误路径仍大量存在于 `sab_codegen.zig` 中 |
| 异步完成度 | ~80%（sweep 计数） | **~20%** | 仅极少数预先选择的单等待/双等待形状通过，通用异步状态机多等待/控制流/恢复未实现 |
| SLA 语言总完成度 | 隐含 ~90% | **~40%** | 闭包、完整异步、完整宏展开、完整 trait 系统、更丰富泛型等尚未开始 |

---

## 二、按阶段逐一列出的未完成任务

### Phase 1: 借用、优先级和智能指针收敛

| # | 未完成任务 | 状态 | 证据位置 |
|---|-----------|------|---------|
| 1 | **完整 RefCell borrow/borrow_mut 生命周期规划**（跨作用域/分支/循环/调用参数/提前返回的冲突时 panic 和释放） | ❌ **未完成** | `tasks.md` P1 未勾选项；`current_plan.md` 明确 "Next Active Slice" |
| 2 | **可重用共享地址/投影计划**：`&field`, `&index`, `&*smart`, `&**chain`, 后缀-前缀优先级 | ⚠️ **部分完成** | 仅普通形式通过共享分类器；智能指针链式解引用和 `&**chain` 仍标记为 "out of scope" |
| 3 | **导入宏内部指针支持的聚合字段别名语义** | ❌ **未完成** | 每个导入宏切片末尾都标注 "out of scope/open" |
| 4 | **用户宏 SA 文本对等性**（用户宏在 SA 文本和 SAB 后端之间行为一致） | ✅ **focused fixture 已完成； broader shared macro convergence 仍开放** | `tests/test_unit_user_macro_direct.sla` host SA/SAB 2/2；更广泛共享 expansion/substitution contract 仍未关闭 |
| 5 | 普通 `&*borrow_or_pointer` 和普通地址分类器的共享规划 | ✅ 已完成 | |
| 6 | 智能指针地址操作共享规划 | ✅ 已完成 | |

### Phase 2: 宏展开完成（通过共享规则）

| # | 未完成任务 | 状态 | 证据位置 |
|---|-----------|------|---------|
| 7 | **确保宏展开决策存在于共享展开/降级规则中，而非仅限 SAB 的分支** | ⚠️ **部分完成** | `tasks.md` 中 P2 条目未勾选 |
| 8 | **嵌套宏调用** | ✅ **focused 用户宏路径已完成；broader 宏合同仍开放** | `tests/test_unit_user_macro_direct.sla` 覆盖 nested expansion |
| 9 | **宏本地 hygiene**（跨独立解码模块的唯一性处理） | ❌ **未完成** | `tasks.md` P2 未勾选项；`current_plan.md` 标注 "generic SCI fragment naming" 为更广泛 SCI 边界任务 |
| 10 | **调用者参数替换** | ✅ **focused 用户宏路径已完成；broader 宏合同仍开放** | SA-text inline expansion maps macro params to caller registers |
| 11 | **借用/移动前缀**（宏参数中的 `&` 和 `^`） | ⚠️ **borrowed field/index/deref focused 路径已完成；完整前缀语义仍开放** | `tests/test_unit_user_macro_direct.sla` 覆盖 borrowed address args |
| 12 | **聚合字面量**（宏参数中的 { } 字面量） | ✅ **focused 用户宏路径已完成；broader 宏合同仍开放** | SA-text macro expansion handles aggregate expressions in the focused fixture |
| 13 | **元组解构**（宏参数中的 `(a, b)`） | ❌ **未完成** | `tasks.md` P2 未勾选项 |
| 14 | **索引访问/赋值**（宏体内的 `a[i]`） | ✅ **focused 用户宏路径已完成；broader 宏合同仍开放** | `tests/test_unit_user_macro_direct.sla` 覆盖 for/index access |
| 15 | **块阴影**（宏展开中的嵌套作用域） | ✅ **focused 用户宏路径已完成；broader 宏合同仍开放** | SA-text macro-local hygiene/block shadowing verified in focused fixture |
| 16 | **宏展开的静态调用** | ✅ **focused 用户宏路径已完成；broader 宏合同仍开放** | static-call expression lowering verified in focused fixture |
| 17 | 导入宏地址表达式物化 | ✅ 已完成 | |
| 18 | 导入宏可寻址参数操作规划 | ✅ 已完成 | |
| 19 | 导入宏参数降级操作共享分类 | ✅ 已完成 | |

### Phase 3: 完整的共享调用和参数物化计划

| # | 未完成任务 | 状态 | 证据位置 |
|---|-----------|------|---------|
| 20 | **将 `CallArgMaterializationPlan` 扩展为完整调用计划**：含结果目标、参数寄存器所有权、释放策略、数组到切片借用、dyn 胖指针借用、复制结构体值、自动借用、移动/借用前缀、生成标识符分类和空结果处理 | ❌ **未完成** | `tasks.md` P3 整个条目未勾选 |
| 21 | **使 SA 文本和 SAB 使用相同的调用计划**（普通调用、宏展开调用、固有/trait 静态分发、外部调用、方法调用、闭包调用包装器） | ❌ **未完成** | `tasks.md` P3 整个条目未勾选 |

### Phase 4: 标准表面元数据泛化

| # | 未完成任务 | 状态 | 证据位置 |
|---|-----------|------|---------|
| 22 | **仅当失败测试证明需要时才添加元数据规则类型**：构造函数、方法、可失败方法、结果方法、分支宏、index/index_assign、clone/as_ptr/from_raw/get_mut、set/map 辅助函数、协议钩子 | ⚠️ **部分完成** | `tasks.md` P4 条目未勾选，但 `sla_std/std_surface.sla_meta` 已有 Rc/Box/Vec/Option/Result/Set 条目 |
| 23 | **解决跟踪的测试失败项**：`tests/test_unit_std_import.sla`, `tests/test_unit_sla_import_nested_contract.sla`, Option/Result/Cell 回归 | ❌ **未通过或未以无回退模式覆盖** | `tasks.md` P4 中提及 |
| 24 | Vec 索引赋值 | ✅ 已完成 | |
| 25 | Rc/Box 动态 trait 对象 | ✅ 已完成 | |
| 26 | Set 集合操作 | ✅ 已完成 | |

### Phase 5: 聚合、枚举、派生和运算符语义

| # | 未完成任务 | 状态 | 证据位置 |
|---|-----------|------|---------|
| 27 | **将剩余聚合布局/更新决策移动到共享规则**：完全共享枚举负载布局、匹配提取、派生相等/顺序/hash/调试元数据、复制/丢弃清理策略 | ⚠️ **部分完成** | `enum_match`, `derive_semantics`, `spaceship_cmp`, `struct_update` 已通过；但更广泛的 Complete 条件尚未满足 |
| 28 | 枚举匹配 | ✅ 已完成 | |
| 29 | <=> 宇宙飞船比较 | ✅ 已完成 | |
| 30 | for_in 协议循环 | ✅ 已完成 | |
| 31 | 派生语义学 | ✅ 已完成 | |
| 32 | 结构体更新（标量和指针支持） | ✅ 已完成 | |

### Phase 6: 协议/trait 分发

| # | 未完成任务 | 状态 | 证据位置 |
|---|-----------|------|---------|
| 33 | **完整协议分发泛化** | ❌ **未完成** | 仅 `generic_for_in_protocol` 通过，`for_in_protocol` 通过；完整 trait 方法分发和超 trait 未覆盖 |

### Phase 7: 闭包、可调用语义、完成器

| # | 未完成任务 | 状态 | 证据位置 |
|---|-----------|------|---------|
| 34 | **闭包/可调用语义** | ❌ **完全未开始** | `tasks.md` 中 P7 无任何已勾选项 |
| 35 | **完成器/完成性检查**（跨语句边界的值完成性） | ❌ **完全未开始** | `tasks.md` 中 P7 无任何已勾选项 |

### Phase 8: 异步状态机

| # | 未完成任务 | 状态 | 证据位置 |
|---|-----------|------|---------|
| 36 | **完整异步状态机调度/恢复**（通用多等待、控制流、恢复） | ❌ **极大未完成** | `tasks.md` P8 仅 "narrow defer-ready resumption" 子集通过 |
| 37 | **任意多等待控制流**（异步函数中有 3 个以上 `.await` 点） | ❌ **未完成** | 仅 2 个顺序等待通过；无限多等待未覆盖 |
| 38 | **任意控制流恢复** | ❌ **未完成** | 仅简单标量线性、分支表达式通过 |
| 39 | **非标量捕获**（Vec/Box/Rc 通过 `.await` 恢复捕获） | ❌ **未完成** | 仅 `@derive(copy)` 结构体的标量字段通过 |
| 40 | **多语句尾部**（等待后有 3 个以上绑定） | ❌ **未完成** | 仅 2 个等待后绑定通过 |
| 41 | **异步函数指针 ABI 泛化** | ❌ **未完成** | 仅就绪/挂起的基本子集通过 |
| 42 | `future::defer_ready` 任务运行时 | ✅ 已完成 | |
| 43 | 固定数组执行器运行时 | ✅ 已完成 | |
| 44 | `future::join2` 运行时 | ✅ 已完成 | |
| 45 | `future::select2` 运行时 | ✅ 已完成 | |
| 46 | Vec 支持执行器运行时 | ✅ 已完成 | |
| 47 | 标量 Poll 运行时 | ✅ 已完成 | |
| 48 | 任务状态运行时 | ✅ 已完成 | |
| 49 | 就绪未来/任务运行时 | ✅ 已完成 | |
| 50 | 挂起`.await`传播 | ✅ 已完成 | |
| 51 | 就绪/挂起未来参数`.await`传播 | ✅ 已完成 | |
| 52 | 就绪组合未来`.await`轮询一次 | ✅ 已完成 | |
| 53 | 本地未来就绪`.await`数据流 | ✅ 已完成 | |
| 54 | 本地挂起组合未来`.await`传播 | ✅ 已完成 | |
| 55 | 单个`defer_ready`等待恢复（+ 标量/分支/捕获/立即变体） | ✅ 已完成 | |
| 56 | 双等待`defer_ready`恢复 | ✅ 已完成 | |
| 57 | `defer_ready` + `join2` 等待恢复 | ✅ 已完成 | |

---

## 三、文档中反复声明为"范围外/开放"的特定项目

以下项目在**每个已完成切片的末尾**被反复声明为未完成：

```
- full RefCell borrow-handle lifecycle reuse across scopes/branches/loops/call args/early returns
- pointer-backed aggregate alias preservation inside imported macros
- user-macro SA-text transpiler parity
- fuller shared &**chain classification
- arbitrary multi-await/control-flow/captured-local async state-machine resumption
```

---

## 四、文档评估偏差分析

### 4.1 "Y 形共享 98%" 被高估

**为什么共享比例实际上远低于 98%：**

- `codegen.zig` (~10000+ 行) 包含大量 SA 文本特有的发射逻辑：SA 文本格式输出、宏展开文本、字符串格式化层
- `sab_codegen.zig` (~8000+ 行) 包含大量 SAB 特有的发射逻辑：结构化 SAB 编码、二进制布局、宏片段编码
- `lowering_rules.zig` (~3500 行) 是真正的共享层
- 共享的降级**逻辑行**约占总发射代码的 **~30%**；共享的降级**函数**约为 200 个函数，占 ~200+ 个发射相关函数
- 按**决策逻辑**（不是按行数）计，共享部分可能约 **~70%**，远低于 98%

### 4.2 "无回退 100%" 仅适用于被跟踪子集

文档反复声明 "direct SAB fallback-removal is 100% for the **tracked unit corpus**"。但：

- `UnsupportedSabDirectFeature` 错误类型在 `sab_codegen.zig` 中被广泛使用（约 50 次引用）
- 实际回退路径 `compileSlaFileToSabWithOptions` → `compileTypedSlaProgramToCompatibleSab` 仍然存在且正在使用
- 遇到任何 102 个测试文件之外的真实 SLA 代码，**极有可能触发回退**

### 4.3 语言功能覆盖面

| 功能类别 | 覆盖情况 | 评估 |
|---------|---------|------|
| 原始类型操作 | 完整 | ✅ |
| 结构体定义/方法 | 大部分完整 | ✅ |
| 元组 | 基本完成 | ✅ |
| 枚举/模式匹配 | 部分完成 | ⚠️ 基础通过，但可能存在缺失的边缘情况 |
| 泛型 | 部分完成 | ⚠️ 基础泛型通过，但更丰富的泛型场景可能缺失 |
| Trait 系统 | 部分完成 | ⚠️ 静态分发和基础动态分发通过，但完整 trait 系统可能不完整 |
| 宏（用户） | 部分完成 | ⚠️ 基础通过，但 SA 文本对等性缺失 |
| 宏（导入 SA） | 部分完成 | ⚠️ JSON/FS 导入通过，但嵌套、地址和更广泛用例缺失 |
| 借用/引用 | 部分完成 | ⚠️ 基础通过，但 RefCell 生命周期和完整别名系统缺失 |
| 闭包 | **完全缺失** | ❌ 未实现 |
| 异步/等待 | **极小** | ❌ 仅狭窄的递延就绪恢复形状 |
| 派生宏 | 部分完成 | ⚠️ 调试/hash/相等/顺序通过，但 `Default` 等缺失 |
| 运算符重载 | 部分完成 | ⚠️ 宇宙飞船通过，但更广泛的运算符元组可能缺失 |
| 智能指针 | 大部分完整 | ✅ Box/Rc/Arc/RefCell 基本通过 |

---

## 五、总结评估

### 完成的工作
- 一个功能性的 Y 形编译器架构，具有工作共享降级层
- 一个**对于 102 个测试的语言子集功能齐全的 SAB 后端**
- 广泛的类型系统覆盖（泛型、trait、枚举、结构体、元组）
- 基础借用/智能指针/RefCell 支持
- 狭窄的异步子集

### 未完成的主要工作（按严重性排序）

1. **完整异步状态机** — 仅狭窄的单等待/双等待递延就绪形状通过；通用异步/等待未实现
2. **闭包/可调用语义** — 完全未开始
3. **完整宏展开** — 嵌套宏、hygiene、参数替换、块阴影等均未完成
4. **后端之间共享降级** — 但两个后端之间仍有大量非对称发射代码
5. **RefCell 生命周期规划** — 仅基本片段共享；跨作用域/循环/分支/提前返回的生命周期未完成
6. **导入宏内部的指针支持聚合别名** — 明确标记未完成
7. **用户宏 SA 文本对等性** — 明确标记为独立范围外问题
8. **完整 trait 系统/协议分发** — 仅基础用例通过；更广泛的通用化未完成
9. **完整标准库元数据覆盖** — 许多 std 类型/方法/构造函数仍需要 `sla_meta` 条目

### 最终结论

> 该项目对其 **测试的语言子集** 是高质量、功能齐全的编译器插件，代码质量高，文档好。
>
> 但**完整的 SLA 语言规范还有大量工作要做**。文档通过报告覆盖率统计数据（如 "Y 共享 98%"、"102/102 文件通过"、"异步 ~85/85"）而**未明确说明这些仅适用于狭窄、不断扩展的受控测试集**，产生了误导。
>
> 现实：该项目在 ~40% 的完整 SLA 语言上完成，剩余 ~60% 位于 2-9 阶段，其中一些（闭包、完整异步）甚至尚未开始。
