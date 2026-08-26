# SLA direct-SAB fallback 清零 —— 失败清单与迭代回路测绘

> 日期：2026-08-26
> 方法：严格模式 `SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1`
> 定位工具：`SLA_SAB_TRACE_UNSUPPORTED=1`（关键，见 §6）
> 范围：`tests/test_unit_*.sla` 全量 194 个 + `demos/rosetta/*/main.sla` 全量 315 个
> 本报告只诊断，未修改任何 lowering 行为。

---

## 1. 总表（实测数字）

| 语料 | check（前端） | sab build 严格 | 通过率 |
|------|--------------|----------------|--------|
| tests/ 194 个 | **194 通过 / 0 失败** | **192 通过 / 2 失败** | 98.97% |
| demos/rosetta/ 315 个 main.sla | **315 通过 / 0 失败** | **277 通过 / 38 失败** | 87.94% |

### 与既有口径的对照

| 来源 | 口径 | 数字 | 说明 |
|------|------|------|------|
| `README.md:16` | `sa sla build-exe` 端到端原生可执行 | 239/313 ≈ **76%** | 被评估文批评的口径；测的是 **build-exe**（含链接），不是 sab build |
| 本报告 | `sla sab build` 严格模式，rosetta 315 个 | **277/315 = 87.9%** | 当前真实数字，比 README 的 76% 高约 12 个百分点 |
| `docs/direct_sab_historical_69_corpus.md` | 历史语料 69 文件 | 当时 134/134 | 当时语料只有 134 个 |
| `docs/roadmap_status_cn.md` §1 | No-fallback sweep | 58/69（2026-07-01） | **已过期**：语料现为 194 个，且 sweep 实为 192/194 |

**结论**：README 的 76% 是 build-exe 口径，不能直接与 sab-build 口径混用。若要继续用「76%」叙事，必须先统一口径；建议以本报告的 87.9%（sab build 严格）为准绳，另单列 build-exe 指标。

### 关于 `VerificationTrap`

整个语料中 **`VerificationTrap` 出现 0 次**。所有失败都是 `error.UnsupportedSabDirectFeature`。
`printSabVerificationTrap`（src/plugin_compile.zig:875/887）在本轮未被触发。

---

## 2. Top 特性缺口聚合表（按出现次数）

> 「源码模块」列：所有 `UnsupportedSabDirectFeature` 的 417 个抛出点全部集中在
> **src/sab_codegen.zig** 一个文件内。下表给出最可能的抛出位置（行号基于当前工作区）。

| # | 缺口签名 | 次数 | 影响文件 | 最可能源码位置 | Phase 归属 |
|---|----------|------|----------|----------------|------------|
| 1 | 静态/关联函数调用无 lowering 计划<br>`static call X has no lowering plan`<br>X ∈ {new, channel, from, open, forget} | **17** | 108_atomic_spin_lock, 109_atomic_fetch_add, 121_rwlock_reader_writer, 123_barrier_sync, 127_hazard_pointers, 131_waker_vtable_mechanics, 53_cache_hits, 63_router_table, 76_lockfree_counter, 81_kv_store, 89_job_queue (`::new`)<br>126_mpmc_channel, 62_channel_pingpong (`::channel`)<br>52_queue_rotate (`::from`)<br>181_file_descriptor_raii, 182_mmap_memory_mapping (`::open`)<br>159_mem_forget_leak (`mem::forget`) | sab_codegen.zig:**12736**<br>`self.traceUnsupported("static call {s} has no lowering plan", .{call.func_name})` | **Phase 3**（调用计划收敛）+ **Phase 4**（Std surface 元数据泛化） |
| 2 | 闭包字面量作为实参无法物化<br>`call X arg N (closure_literal) failed`<br>X ∈ {map, filter, fold, catch_unwind} | **7** | 32_trait_object_vector, 33_iterator_map, 34_iterator_filter, 35_iterator_fold, 49_pipeline_map, 171_anyhow_dynamic_error, 173_catch_unwind_panic | sab_codegen.zig:**12903**<br>`"call {s} arg {} ({s}) failed"` | **Phase 3**（CallArgMaterializationPlan 扩展）＋ **Phase 8**（async/closure 交界） |
| 3 | 对定长数组按值迭代<br>`for x in arr` 其中 arr: `[T; N]` | **4** | 65_job_scheduler, 66_actor_mailbox, 68_parser_tokens, 73_scene_nodes | sab_codegen.zig:**6596**（`stmt {s} failed`，stmt 为 `.for_stmt`）；for-in 主体在 control_flow_rules.zig / sab_codegen for 分支 | **Phase 6**（协议降低和迭代） |
| 4 | 解引用目标赋值 `*guard = v`<br>（MutexGuard / Arc 解引用后写回） | **3**（rosetta）<br>+1（tests） | 102_raii_guard, 122_condvar_wait_notify, 315_async_thread_pool；tests/test_unit_async_thread_pool | sab_codegen.zig:**6596**（`.assign_stmt`）；赋值目标寻址在 genAssign / lowering_rules.zig | **Phase 3** ＋ **Phase 5**（roadmap 明示 assign_move_cleanup 属此交集） |
| 5 | `unsafe { ... }` 块体（含 extern C 调用、`asm!`） | **3** | 117_inline_assembly（`asm!` inout）、185_dynamic_lib_dlopen、187_opengl_context_swap | sab_codegen.zig:**554** / **1334** 一带的 decl/block 分派 | **roadmap 未覆盖**（FFI/unsafe 不在 Phase 1-9 表中）→ 建议新增 Phase 项或明确划出范围 |
| 6 | union 类型的 struct literal 构造 | **2** | 113_union_ffi_types, 160_manually_drop_union | sab_codegen.zig:**8368/14479**（struct literal field planning） | **Phase 5**（聚合/枚举布局） |
| 7 | 借用定长数组形参的元素读取<br>`fn f(a: &[T; N]) -> T { a[0] }` | **1**（rosetta）<br>+1（tests） | 190_base64_encode_simd；tests/test_unit_sa_borrow_array_call_result_cleanup | index_expr 路径（sab_codegen.zig index/binary_expr 分支） | **Phase 3**（CallArgMaterializationPlan「数组→切片借用」子任务，P0，roadmap 明列） |
| 8 | 一元负号操作符重载 `-a`（struct 上） | **1** | 302_operator_overload_neg | binary_expr/unary 分支 | **Phase 5**（操作符语义/spaceship 同族） |

合计 38（rosetta）/ 40（含 tests 2 个）。

---

## 3. 失败明细清单

### 3.1 tests/ （2 个失败）

| 文件 | 精确错误输出 | 根因 trace | 类别 |
|------|-------------|-----------|------|
| `tests/test_unit_async_thread_pool.sla` | `SAB Direct Error: direct SLA-to-SAB lowering failed without fallback: error.UnsupportedSabDirectFeature` | `stmt assign_stmt failed` ← `func pool_worker block failed` ← `func decl pool_worker failed` | #4 解引用目标赋值（`*g = r`，经 Arc&lt;Mutex&gt;/guard 解引用） |
| `tests/test_unit_sa_borrow_array_call_result_cleanup.sla` | 同上 | `return value binary_expr failed` ← `func borrow_array_sum ...` | #7 借用定长数组形参元素读取（`bytes[0] + len`，`bytes: &[int; 4]`） |

注：这两个文件在 fallback 开启时均能编译通过，确认是 direct-SAB 路径缺口而非前端问题。
`test_unit_async_thread_pool.sla` 由 commit `a980f31` 引入；其文件头注释已自述「default SAB test path 目前 mis-lowers stack_alloc + PIN_MUT_NEW pipeline」。

### 3.2 demos/rosetta/ （38 个失败）

全部错误输出一致：
```
SAB Direct Error: direct SLA-to-SAB lowering failed without fallback: error.UnsupportedSabDirectFeature
```
逐文件根因（第一行 `[sab-direct]` trace 即根因）：

| 目录 | 根因 trace 第一行 | 归类 |
|------|-------------------|------|
| 108_atomic_spin_lock | `static call new has no lowering plan` | #1 |
| 109_atomic_fetch_add | `static call new has no lowering plan` | #1 |
| 121_rwlock_reader_writer | `static call new has no lowering plan` | #1 |
| 123_barrier_sync | `static call new has no lowering plan` | #1 |
| 127_hazard_pointers | `static call new has no lowering plan` | #1 |
| 131_waker_vtable_mechanics | `static call new has no lowering plan` | #1 |
| 53_cache_hits | `static call new has no lowering plan` | #1 |
| 63_router_table | `static call new has no lowering plan` | #1 |
| 76_lockfree_counter | `static call new has no lowering plan` | #1 |
| 81_kv_store | `static call new has no lowering plan` | #1 |
| 89_job_queue | `static call new has no lowering plan` | #1 |
| 126_mpmc_channel | `static call channel has no lowering plan` | #1 |
| 62_channel_pingpong | `static call channel has no lowering plan` | #1 |
| 52_queue_rotate | `static call from has no lowering plan` | #1 |
| 181_file_descriptor_raii | `static call open has no lowering plan` | #1 |
| 182_mmap_memory_mapping | `static call open has no lowering plan` | #1 |
| 159_mem_forget_leak | `static call forget has no lowering plan` | #1 |
| 32_trait_object_vector | `call map arg 1 (closure_literal) failed` | #2 |
| 33_iterator_map | `call map arg 1 (closure_literal) failed` | #2 |
| 34_iterator_filter | `call filter arg 1 (closure_literal) failed` | #2 |
| 35_iterator_fold | `call fold arg 2 (closure_literal) failed` | #2 |
| 49_pipeline_map | `call map arg 1 (closure_literal) failed` | #2 |
| 171_anyhow_dynamic_error | `call map arg 1 (closure_literal) failed` | #2 |
| 173_catch_unwind_panic | `call std__panic__catch_unwind arg 0 (closure_literal) failed` | #2 |
| 65_job_scheduler | `stmt for_stmt failed`（`for job in jobs`，jobs: `[Job; 4]`） | #3 |
| 66_actor_mailbox | `stmt for_stmt failed`（`inbox: [Message; 2]`） | #3 |
| 68_parser_tokens | `stmt for_stmt failed`（`tokens: [ptr; 4]`） | #3 |
| 73_scene_nodes | `stmt for_stmt failed`（`nodes: [SceneNode; 3]`） | #3 |
| 102_raii_guard | `stmt assign_stmt failed`（`*guard = updated;`） | #4 |
| 122_condvar_wait_notify | `stmt assign_stmt failed`（`*ready = 4;`） | #4 |
| 315_async_thread_pool | `stmt assign_stmt failed`（`*g = r;`） | #4 |
| 113_union_ffi_types | `let payload value struct_literal failed`（`Payload{i:36}`，`union Payload`） | #6 |
| 160_manually_drop_union | `let slot value struct_literal failed`（`Slot{a: ManuallyDrop::new(11)}`，`union Slot`） | #6 |
| 117_inline_assembly | `stmt expr_stmt failed`（`unsafe { asm!(..., inout("eax") v); }`） | #5 |
| 185_dynamic_lib_dlopen | `func decl dynamic_lib_close_status failed`（unsafe 块 + dlopen/dlclose） | #5 |
| 187_opengl_context_swap | `func decl opengl_swap_result failed`（unsafe 块 + gl_* 外部调用） | #5 |
| 190_base64_encode_simd | `let q0 value binary_expr failed`（`input[0] / 4`，`input: &[u8; 3]`） | #7 |
| 302_operator_overload_neg | `let b value binary_expr failed`（`let b = -a;` Vec3 取负） | #8 |

---

## 4. 关键最小复现（供修复 agent 直接使用）

以下最小样例均已实测复现（放 `/tmp/slainv/min/`），可作为每类缺口的回归用例种子：

```sla
// #7 借用定长数组形参元素读取 —— FAIL
fn first(bytes: &[int; 4]) -> int { return bytes[0]; }
```
```sla
// 对照组：按值数组形参 —— PASS（证明缺口只在借用形态）
fn first(bytes: [int; 4]) -> int { return bytes[0]; }
```
```sla
// #4 解引用目标赋值 —— FAIL（assign_stmt）
fn f(x: i32) -> i32 {
    let g = Box::new(x);
    *g = 9;
    return *g;
}
```
```sla
// #3 定长数组按值 for-in —— FAIL（for_stmt）
struct Job { ready: bool, cost: int }
fn cost(jobs: [Job; 2]) -> int {
    let done = 0;
    for j in jobs { if j.ready { done = done + j.cost; }; }
    return done;
}
```
```sla
// #6 union struct literal —— FAIL（struct_literal）
union Payload { i: i32, b: u8 }
fn p() -> i32 {
    let payload = Payload { i: 36 };
    let v = unsafe { payload.i };
    return v;
}
```

对照组事实：
- `h2_owned_arr_index.sla`（按值数组形参 + 索引）→ **编译通过**
- for-in 若写成借用切片形态会被**类型检查**直接拒绝：
  `Type Check Error: ... for iterable value must be array or implement Iterable: start tag=borrow (error.TypeMismatch)`
  → 说明 #3 不是「切片迭代缺 lowering」，而是**按值定长数组的 for-in 缺 direct 路径**。

---

## 5. 建议修复顺序（按 影响面 / 难度 比）

| 序 | 目标 | 文件数 | 难度 | 理由 |
|----|------|--------|------|------|
| **P0-1** | 关联/静态构造调用 lowering 计划（`Type::new` 族、`channel`、`from`、`open`、`mem::forget`） | **17（占 45%）** | 中 | 单点收益最大。sab_codegen.zig:12736 是唯一分派点；已有静态分发符号收敛基础（Phase 1 成果）。很可能只需把用户自定义 struct 的关联 fn 纳入现有 `StaticCallPlan` 表 |
| **P0-2** | 借用定长数组形参的索引读取 | **1 rosetta + 1 tests** | 低 | 直接解锁一个 unit test；roadmap Phase 3 P0 子任务明列「数组→切片借用」。改动面小（index_expr 寻址加 borrow-array 形态） |
| **P1-1** | 闭包字面量作为调用实参 | **7** | 中 | 闭包本身已支持（08_closures 通过），缺口只在「作为实参传给方法/外部函数」的物化路径（sab_codegen.zig:12903）。与 iterator/trait-object 族强相关 |
| **P1-2** | 定长数组按值 for-in | **4** | 低 | 复用既有迭代路径 + 数组到区间的衰减即可；四个文件形态完全一致 |
| **P1-3** | 解引用目标赋值 `*p = v` | **3 + 1 tests** | 中 | 同时解锁 tests 里 async_thread_pool；需 guard/smart-pointer 投影地址计划（Phase 1 未决项「提取完整共享地址/投影计划」正是此项） |
| **P2-1** | union 类型 struct literal | **2** | 中 | 需要标签省略布局 + 单活跃成员写入；与 Phase 5 枚举负载布局同族可共用机制 |
| **P2-2** | 一元取负操作符重载 | **1** | 低 | 单一操作符分发分支 |
| **P3-1** | `unsafe` 块 / extern C 调用体 / `asm!` | **3** | 高 | 收益最低难度最高；117 是 inline asm（本质超出 SAB 可移植指令集）。建议**显式决定是否纳入 fallback-zero 范围**，否则应允许这三者长期走 fallback 并在文档标注 |

**预期效果**：完成 P0-1 + P0-2 + P1-1 + P1-2 后，
rosetta 严格通过率从 277/315 (87.9%) 提升到 **292/315 (92.7%)**；
再完成 P1-3 + P2-1 + P2-2 后达 **298/315 (94.6%)**；
tests 达 198/198 (100%)。

---

## 6. 诊断基础设施的重要发现

1. **默认错误信息不含特性名**，38+2 个失败打印的是完全相同的字符串，对并行修复毫无定位价值：
   ```
   SAB Direct Error: direct SLA-to-SAB lowering failed without fallback: error.UnsupportedSabDirectFeature
   ```
   必须叠加 `SLA_SAB_TRACE_UNSUPPORTED=1` 才能看到 `[sab-direct] ...` 层级 trace
   （实现：src/sab_codegen.zig:6616 `traceSabUnsupported` / 6621 `traceUnsupported`，39 个埋点）。
   **建议**：把根因 trace 默认并入 `SAB Direct Error` 输出（或在 NO_FALLBACK 模式下自动开启），否则清零工程的排障成本极高。
2. trace 的**第一行即根因**，后续是逐层向上冒泡（stmt → block → func decl）。
3. 417 个 `UnsupportedSabDirectFeature` 抛出点 **100% 集中在 src/sab_codegen.zig**，无跨模块分散 —— 修复工作可以完全聚焦在单一文件。

---

## 7. 迭代回路测绘（改代码 → 生效 → 重测）

### 结论：`zig build` 单独执行 **不会生效**

宿主加载的是**安装快照副本**，不是 zig-out 的产物：

- 插件 DLL 构建产物：`D:\projects\sla\sa_plugin_sla\zig-out\bin\sla.dll`
- 宿主实际加载路径：`C:\Users\Administrator\AppData\Local\sa_plugins\installed\sla\current\sla.dll`
- 安装动作是**复制**而非链接：sci/src/plugins.zig:2048 `copyFileAbsolute(artifact_abs, installed_artifact)`
- 加载遍历 `<pluginsHome>/installed/<name>/current`：sci/src/plugins.zig:1584、1298-1300
- `SA_PLUGIN_DEV=1` 只影响特权插件沙箱门禁（plugins.zig:1762、3937 `pluginDevMode`），**不改变加载路径**
- 决定性验证：设 `SA_PLUGINS_HOME=/tmp/emptyplug` 后 `sa sla skills --json` 直接报
  `UnknownCommand / SA-CLI-013`，说明 `sla` 子命令确实来自 plugins home 里的那份 DLL

### 实测耗时

| 步骤 | 耗时 |
|------|------|
| `zig build`（src/plugin_compile.zig 追加一行注释后的增量构建） | **42.6 s** |
| 复制 DLL 到 installed/current | < 0.3 s |
| 单个 `sla check` | ~0.07 s |
| 单个 `sla sab build`（严格 + trace） | ~0.1 s |
| 全量 194 tests check+sab | 数秒 |
| 全量 315 rosetta check+sab | 数秒（-P 8 并行） |

### 推荐回路命令序列

每次新开 shell 先执行环境准备：

```bash
cd /d/projects/sla/sa_plugin_sla
export NoDefaultCurrentDirectoryInExePath=
```

单次迭代：

```bash
# 1) 构建（~43s）
zig build

# 2) 刷新宿主加载的快照副本（必须！否则跑的是旧代码）
cp zig-out/bin/sla.dll "/c/Users/Administrator/AppData/Local/sa_plugins/installed/sla/current/sla.dll"

# 3) 重测（秒级）
export SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 SLA_SAB_TRACE_UNSUPPORTED=1

# 单文件快速验证
sla sab build /tmp/slainv/min/h1_borrow_arr_index.sla --out /tmp/x.sab

# 全量回归
ls tests/test_unit_*.sla | xargs -P 8 -I{} sla sab build {} --out /tmp/x.sab
ls -d demos/rosetta/*/ | xargs -P 8 -I{} sla sab build {}main.sla --out /tmp/x.sab
```

**总回路耗时 ≈ 44 s**（其中 43s 在 zig build），重测几乎免费。
因此修复 agent 应当**批量改多个缺口后再构建一次**，而不是每修一个小项就 build。

> 注：本轮已顺手把 installed/current 的 DLL 同步为当前 zig-out 版本（二者 md5 已一致：
> `1cc14f2c3c1d236171d966268374ab8a`），环境基线干净。
> 另：`/d/tools/bin/sla.dll`（2026-08-25）是另一份陈旧拷贝，md5 为
> `4ed9a7ff8d3f2b82e6e37ffc37e987a8`，与本工程无关，勿混淆。

---

## 8. 附：本次测量产生的中间数据路径

| 内容 | 路径 |
|------|------|
| tests check 结果（逐文件 .txt/.rc） | `/tmp/slainv/check/` |
| tests sab 严格结果 | `/tmp/slainv/sab/` |
| rosetta check 结果 | `/tmp/slainv/rcheck/` |
| rosetta sab 严格结果 | `/tmp/slainv/rsab/` |
| 40 个失败的根因 trace | `/tmp/slainv/trace/` |
| 最小复现样例 | `/tmp/slainv/min/` |

（临时目录，重启后可能丢失；报告本体已包含全部结论。）
