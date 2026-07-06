# SAB 聚合测试文件 UseAfterMove issue

日期：2026-07-06

状态：已复验修复。`sla_ecs` 下游仅记录问题，不修改 SLA 编译器源码。

## 摘要

`sla_ecs` 在 `tests/test_ecs_mut_parallel.sla` 中新增 multi-threaded executor ready-batch 循环 runner、access-conflict-aware ready-batch 选择、动态 `Vec<fn>` catalog、width-6 pthread batch、worker-count `EcsParallelTaskPool` facade 和 run-plan deferred apply cleanup 后，生成 SA 后端整文件通过；默认/SAB 后端的 focused smoke 也通过。此前默认/SAB 后端整文件聚合编译失败，SAB verifier 报 `UseAfterMove`。2026-07-06 复验时，默认/SAB 后端整文件已经通过。

这不同于已修复的 `sab_thread_fnptr_ready_batch_unknown_register_issue_cn.md`：当前 failure 不是 focused function-pointer/thread 路径的 `UnknownRegister`，而是整文件聚合 `.sab` artefact 中临时寄存器的 move 状态错误。

## 复验

仓库：

```text
/home/vscode/projects/sla_ecs
```

命令：

```sh
cd /home/vscode/projects/sla_ecs
timeout 180s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --jobs 1 --trace-panic
```

当前结果：

```text
91 passed; 0 failed; 0 skipped
```

## 历史失败输出

```text
error[UseAfterMove]: moved value is no longer usable
  register: tmp_67
  state: expected Consumed, actual Consumed
{"trap":"UseAfterMove","trap_code":1009,"file":".sla-cache/sab/test_ecs_mut_parallel-3b877e38e5c97ce3.sab","line":785,"source_line":0,"register":"tmp_67","expected_mask_name":"Consumed","actual_mask_name":"Consumed","message":"moved value is no longer usable"}
```

## 已通过的对照验证

生成 SA 后端整文件通过：

```sh
timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --test-backend sa --jobs 1 --trace-panic
```

结果：

```text
91 passed; 0 failed; 0 skipped
```

默认/SAB focused smoke 通过：

```sh
timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "ready pair bridge advances plan" --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "ready triple bridge releases dependent" --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "width dispatch selects pair" --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "all dispatch two waves" --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "all dispatch skip releases dependent" --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "all dispatch mismatch status" --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "nonconflict batch skips conflicting ready" --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "nonconflict conflict waves" --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "dynamic catalog first wave" --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "dynamic catalog waves" --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "dynamic catalog quad first wave" --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "dynamic catalog quad waves" --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "task pool batch respects worker count" --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "task pool all runs worker limited waves" --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "task pool applies deferred and clears unapplied" --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "dynamic catalog quint first wave" --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "task pool runs five system batch" --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "dynamic catalog six" --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "batch width at six" --jobs 1 --trace-panic
```

以上 focused default/SAB runs 均通过。

## 初步判断

2026-07-06 复验显示该问题已被编译器侧修复：默认/SAB focused smoke 和整文件聚合均通过。以下判断仅保留为历史定位记录。

问题疑似位于 SAB 整文件聚合/链接或 verifier register-lifetime metadata：单个 focused test 可以通过，但整文件合并后某个临时值 `tmp_67` 被判定为已 consumed 后再次使用。由于 `.sla-cache/sab/*.sab` 是二进制编码，当前只能从 verifier JSON 定位到 `.sab` 第 785 行附近，未取得可读源码级映射。

建议编译器侧优先检查：

- 多测试聚合时临时寄存器编号或 lifetime metadata 是否跨函数/测试污染；
- 函数指针 + `Arc<*TableErasedWorld<R, M>>` + 多个 test case 共存时，SAB verifier 是否错误复用 consumed 状态；
- `.sab` artefact 的 source-map 是否能补充到 verifier 输出，便于后续下游定位。
