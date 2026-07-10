# SA backend mut-parallel whole-file for_stmt TypeMismatch issue

日期：2026-07-07

状态：已修复并复验；历史整文件 generated-SA `for_stmt` TypeMismatch 当前不再复现。后续 `docs/sa_scope_taskset_move_cleanup_useaftermove_issue_cn.md` 的 aggregate reassignment cleanup 修复后，完整 `/home/vscode/projects/sla_ecs/tests/test_ecs_mut_parallel.sla` generated-SA 和默认/SAB 路径均已通过 129/129。本文保留原始失败记录作为回归背景。

## 最新复验

后续 compiler cleanup 的完整聚合复验证据：

```bash
cd /home/vscode/projects/sla_ecs
timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --test-backend sa --jobs 1 --trace-panic

timeout 300s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --jobs 1 --trace-panic
```

结果：完整 generated-SA 129/129 passed；完整默认/SAB 路径 129/129 passed。

关联修复记录：

- `src/codegen.zig` 对非 Copy、非 borrow-like identifier RHS assignment 只迁移 compiler-side value-state metadata 并标记 RHS consumed，不再在 `bag = next_bag` / `a = next_a` 后让 loop-body cleanup 二次释放 RHS。
- `src/sab_codegen.zig` 对 identifier assignment 采用同样状态迁移策略，避免 direct SAB 在 `assign target,rhs` 后再额外 `move_ rhs`。
- 本 repo 回归：`tests/test_unit_sa_aggregate_reassign_move_cleanup.sla`。
- 下游 focused gate：`tests/test_ecs_mut_parallel.sla --filter "task pool scoped task set" --test-backend sa` 16/16 passed。

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

原 Batch 141 ECS stream 不修改 compiler，因此当时只把 executor isolated whole-file SA/default 和受影响 parallel bridge focused tests 作为 completion evidence。当前 compiler 侧后续 cleanup 已覆盖并关闭整文件聚合路径；后续若该文件再次失败，应以新的错误阶段和最小 compiler repro 重新开 issue。
