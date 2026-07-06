# SAB parallel_runner whole-file MemoryLeak issue

状态：待修复。下游 `sla_ecs` 已用 generated-SA 后端验证新增 `TaskPoolBuilder` / global task-pool facade 通过；默认/SAB 后端的单个 focused tests 也通过。但当测试文件导入 `lib/parallel_runner.sla` 并执行整文件聚合测试时，SAB verifier 在 `.sab` 文件尾部报告无源码定位的 `MemoryLeak`。本文只记录 issue，不修改 SLA 编译器源码。

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

## 后续建议

修复 SAB 后应重跑：

```bash
cd /home/vscode/projects/sla_ecs
SA_PLUGIN_DEV=1 sa sla test lib/parallel_runner.sla --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test lib/task_pool_builder.sla --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test lib/task_pool_builder.sla --test-backend sa --jobs 1 --trace-panic
```

下游当前继续以 generated-SA 整文件通过和默认/SAB focused tests 作为 `TaskPoolBuilder` facade 的验证证据。
