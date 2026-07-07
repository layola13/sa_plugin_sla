# SA backend mut-parallel whole-file for_stmt TypeMismatch issue

日期：2026-07-07

## 背景

在 `sla_ecs` Batch 141（multi-threaded executor active-running can-run gates）后，核心受影响的 executor isolated 测试和 focused parallel bridge 测试均通过，但 `tests/test_ecs_mut_parallel.sla` 的整文件 generated-SA 聚合在执行前的类型检查阶段失败。

## 复现命令

```bash
cd /home/vscode/projects/sla_ecs
timeout 240s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla --test-backend sa --jobs 1 --trace-panic
```

观察到：

```text
Type Check Error: failed to verify types: checkStmt failed at node tag for_stmt (error.TypeMismatch)
```

## 对照通过项

```bash
timeout 120s env SA_PLUGIN_DEV=1 sa sla check lib/executor_multi_threaded.sla
timeout 180s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_lib_executor_multi_threaded_isolated.sla --test-backend sa --jobs 1 --trace-panic
timeout 180s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_lib_executor_multi_threaded_isolated.sla --jobs 1 --trace-panic
timeout 120s env SA_PLUGIN_DEV=1 sa sla check lib/parallel_runner.sla
timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla --test-backend sa --filter "ready" --jobs 1 --trace-panic
timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla --test-backend sa --filter "nonconflict" --jobs 1 --trace-panic
timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla --test-backend sa --filter "main thread executor" --jobs 1 --trace-panic
```

这些 focused paths 通过，说明当前观察更像整文件聚合/可达性/typecheck 路径问题，而不是 Batch 141 executor gate 语义失败。

## 处理策略

本 ECS stream 不修改 compiler。Batch 141 completion evidence 使用 executor isolated whole-file SA/default 以及受影响 parallel bridge focused tests。
