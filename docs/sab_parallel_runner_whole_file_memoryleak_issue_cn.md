# SAB parallel_runner whole-file MemoryLeak issue

状态：待修复，且全量复现命令归类为危险测试。下游 `sla_ecs` 已用 generated-SA 后端验证新增 `TaskPoolBuilder` / global task-pool facade 通过；默认/SAB 后端的单个 focused tests 也通过。但当测试文件导入 `lib/parallel_runner.sla` 并执行整文件聚合测试时，SAB verifier 在 `.sab` 文件尾部报告无源码定位的 `MemoryLeak`。当前全量 `lib/parallel_runner.sla` 在本地 direct-SAB 路径 10 秒内无输出且不写出 `.sab` 产物，后续不得用长超时反复探测，应先用编译器仓库内的细化模拟 fixture 定位。

## 触发背景

`sla_ecs/lib/task_pool_builder.sla` 新增 Bevy `bevy_tasks::TaskPoolBuilder` 与 `ComputeTaskPool` / `AsyncComputeTaskPool` / `IoTaskPool` 形状的 facade：

- builder 记录 `num_threads`、`stack_size`、thread name id、spawn/destroy callback flag，并通过现有 `EcsParallelTaskPool` build。
- global task pools 用显式 owned `EcsGlobalTaskPools` 值模拟 Bevy 的 `OnceLock` 全局池，因为 SLA 当前没有全局 `OnceLock` 原语。
- 新增 6 个 focused tests，generated-SA 全部通过。

## 通过的验证

generated-SA 整文件：

```bash
cd /home/vscode/projects/sla_ecs
timeout 180s env SA_PLUGIN_DEV=1 sa sla test lib/task_pool_builder.sla \
  --test-backend sa --jobs 1 --trace-panic
```

结果：`75 passed; 0 failed`。

默认/SAB focused tests 分别通过：

```bash
timeout 120s env SA_PLUGIN_DEV=1 sa sla test lib/task_pool_builder.sla \
  --filter "task pool builder defaults" --jobs 1 --trace-panic
timeout 120s env SA_PLUGIN_DEV=1 sa sla test lib/task_pool_builder.sla \
  --filter "task pool builder stores" --jobs 1 --trace-panic
timeout 120s env SA_PLUGIN_DEV=1 sa sla test lib/task_pool_builder.sla \
  --filter "task pool builder build clamps" --jobs 1 --trace-panic
timeout 120s env SA_PLUGIN_DEV=1 sa sla test lib/task_pool_builder.sla \
  --filter "global task pools try" --jobs 1 --trace-panic
timeout 120s env SA_PLUGIN_DEV=1 sa sla test lib/task_pool_builder.sla \
  --filter "global compute async" --jobs 1 --trace-panic
timeout 120s env SA_PLUGIN_DEV=1 sa sla test lib/task_pool_builder.sla \
  --filter "tick global" --jobs 1 --trace-panic
```

结果：6 个 focused SAB tests 均通过。

## 默认/SAB 失败

`task_pool_builder.sla` 默认/SAB 整文件失败：

```bash
timeout 180s env SA_PLUGIN_DEV=1 sa sla test lib/task_pool_builder.sla \
  --jobs 1 --trace-panic
```

错误：

```text
error[MemoryLeak]: live registers remain at function exit
  register: tmp_32941
  state: Active
{"trap":"MemoryLeak","trap_code":1012,"file":".sla-cache/sab/task_pool_builder-97d614c49d5e52c2.sab","line":157001,"source_line":0,"column":null,"source_text":null,"original_text":null,"bad_token":null,"context":[],"register":"tmp_32941","registers":[],"expected_mask":null,"actual_mask":1,"expected_mask_name":null,"actual_mask_name":"Active","upstream_loc":null,"function":null,"is_ffi_wrapper":false,"message":"live registers remain at function exit","hint":null}
```

直接跑被导入的 `parallel_runner.sla` 也失败，说明不是 `task_pool_builder.sla` 的单个 focused test 逻辑问题：

```bash
timeout 180s env SA_PLUGIN_DEV=1 sa sla test lib/parallel_runner.sla \
  --jobs 1 --trace-panic
```

错误：

```text
error[MemoryLeak]: live registers remain at function exit
  register: tmp_32653
  state: Active
{"trap":"MemoryLeak","trap_code":1012,"file":".sla-cache/sab/parallel_runner-efc653488274a974.sab","line":156145,"source_line":0,"column":null,"source_text":null,"original_text":null,"bad_token":null,"context":[],"register":"tmp_32653","registers":[],"expected_mask":null,"actual_mask":1,"expected_mask_name":null,"actual_mask_name":"Active","upstream_loc":null,"function":null,"is_ffi_wrapper":false,"message":"live registers remain at function exit","hint":null}
```

## 判断

- generated-SA 整文件通过，说明 SLA 源层和 SA cleanup 路径能承载该用例。
- 默认/SAB focused tests 全部通过，但导入 `parallel_runner.sla` 的整文件聚合失败，疑似 SAB whole-file aggregation / final cleanup metadata 在大导入图、thread/Arc/function-pointer helper 共存时留下未释放临时寄存器。
- verifier JSON 没有函数名或 SLA 源映射，当前只能定位到 managed `.sab` 文件尾部。

## 2026-07-07 危险测试复核与细化模拟

检讨：之前把 `lib/parallel_runner.sla` 当作普通下游整文件验证，并给到 180s 超时，是错误的。该路径多次在 30s 内无输出，且当前 10s smoke 也不生成 `parallel_runner-*.sab` 缓存产物；继续长跑会浪费编译时间，并可能被误认为“仍在有效验证”。后续规则：全量 `parallel_runner.sla` / `task_pool_builder.sla` direct-SAB 只能用 `timeout 10s` 做危险 smoke；没有输出就立即视为“未取得证据”，转回最小 fixture。

本轮新增/细化编译器仓库内最小模拟，且按 10s 门槛拆成独立小文件，避免多个场景累计后把单个 fixture 变成危险测试。

`tests/test_unit_parallel_runner_min_direct.sla` 覆盖当前已收敛的基础形态和一层无循环 parent/child extend：

- struct 字段持有 `Vec<fn(i32) -> i32>`；
- 函数指针被 push 进 Vec；
- 从 struct 字段 `holder.runs[0]` 取回函数指针并调用。
- 同一 holder 维护 `run_order_positions: Vec<i64>`；
- 从 child holder 的 `child.runs[0]` 取函数指针，push 到 parent holder，模拟 task-set extend 的最小无循环形态。

`tests/test_unit_parallel_runner_loop_order_direct.sla` 覆盖 while-loop order-position 骨架：

- holder 同时拥有 `Vec<fn(i32) -> i32>` 和 `run_order_positions: Vec<i64>`；
- while-loop 只动态读取 `run_order_positions` 并校验顺序，不在循环中索引/转存 `Vec<fn>`。

验证命令全部使用 10s 超时：

```bash
timeout 10s ./zig-out/bin/sla-local-cli sla test tests/test_unit_parallel_runner_min_direct.sla --test-backend sa --trace-panic
timeout 10s env SLA_SAB_NO_FALLBACK=1 ./zig-out/bin/sla-local-cli sla sab build tests/test_unit_parallel_runner_min_direct.sla --out /tmp/parallel_runner_min_direct.sab
timeout 10s env SLA_SAB_NO_FALLBACK=1 ./zig-out/bin/sla-local-cli sla test tests/test_unit_parallel_runner_min_direct.sla --test-backend sab --trace-panic
timeout 10s ./zig-out/bin/sla-local-cli sla test tests/test_unit_parallel_runner_loop_order_direct.sla --test-backend sa --trace-panic
timeout 10s env SLA_SAB_NO_FALLBACK=1 ./zig-out/bin/sla-local-cli sla test tests/test_unit_parallel_runner_loop_order_direct.sla --test-backend sab --trace-panic
timeout 10s /home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli sla test lib/parallel_runner.sla --trace-panic
```

结果：

- 最小模拟第一层 SA：1/1 通过，约 1.5s。
- 最小模拟第一层 SAB build：通过，约 7.7s，写出 `/tmp/parallel_runner_min_direct.sab`。
- 最小模拟第一层 direct-SAB test：1/1 通过，约 8.5s。
- 增加 `run_order_positions` 与无循环 `extend_one` 后，SA 2/2 通过约 1.5s，SAB build 约 7.9s，direct-SAB test 2/2 通过约 8.1s，仍在 10s 门槛内。
- 将 while-loop order-position 骨架拆到独立文件后，SA 1/1 约 2.4s，direct-SAB test 1/1 约 8.0s，仍在 10s 门槛内。
- 已定位的下一层超时形态：在 while-loop 内执行 `parent = push(parent, child.runs[order_pos])`，也就是动态索引 `Vec<fn(...)>` 并把函数指针写入另一个 holder。该形态 10s 内无输出超时；去掉 `child.runs[order_pos]` 后恢复通过。因此当前热点不是 while 本身，也不是 `Vec<i64>` 动态索引，而是 loop 内动态索引函数指针 Vec 并转存。
- 全量 `lib/parallel_runner.sla`：10s 无输出超时，未生成 `parallel_runner-*.sab` 缓存产物。

因此当前最小可提交基线已覆盖 `Vec<fn>` struct 字段、无循环 order-position extend、以及 while-loop order-position 骨架；下一步应修复或优化 loop 内动态索引函数指针 Vec 并转存的 direct-SAB 路径，然后再继续增加多个 `Vec<fn>` 字段、`Arc<*World>` 参数、child-scope 返回 taskset、thread spawn 等维度。每个维度都必须保持 10s 内可验证。只有当某个细化 fixture 复现 MemoryLeak 或明确超过 10s，才进入对应编译器热点/cleanup 修复；全量下游文件不再作为首要定位工具。

## 后续建议

修复 SAB 后应重跑：

```bash
cd /home/vscode/projects/sla_ecs
timeout 10s env SA_PLUGIN_DEV=1 sa sla test lib/parallel_runner.sla --trace-panic
timeout 10s env SA_PLUGIN_DEV=1 sa sla test lib/task_pool_builder.sla --trace-panic
timeout 10s env SA_PLUGIN_DEV=1 sa sla test lib/task_pool_builder.sla --test-backend sa --trace-panic
```

如果 10s smoke 无输出，不能把它当作失败细节；必须回到本仓库细化 fixture 或缓存 SAB 反汇编定位。

下游当前继续以 generated-SA 整文件通过和默认/SAB focused tests 作为 `TaskPoolBuilder` facade 的验证证据。
