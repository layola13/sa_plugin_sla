# 生成 SA scoped task set move cleanup UseAfterMove issue

日期：2026-07-06

状态：cleanup 子问题已修复并复验；完整下游聚合 SA 与默认/SAB 路径均已通过。`next_world` / `next_a` / `next_bag` 这类非 Copy aggregate identifier reassignment 不再生成额外 RHS release，也不会在 loop-body cleanup 阶段二次释放。完整 `/home/vscode/projects/sla_ecs/tests/test_ecs_mut_parallel.sla` 现在越过 aggregate cleanup UseAfterMove；先前观察到的 `ecs_parallel_scope_run_result_recursive` 21 args vs 22 params `InvalidArgsCount` 属于历史瞬态记录，最新复验不再复现。

最新复验：

本 repo 新增 focused 回归：

```sh
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_sa_aggregate_reassign_move_cleanup.sla \
  --test-backend sa --jobs 1 --trace-panic

SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_unit_sa_aggregate_reassign_move_cleanup.sla \
  --test-backend sab --jobs 1 --trace-panic
```

结果均为 1/1 passed。

下游局部复验：

```sh
cd /home/vscode/projects/sla_ecs
SA_PLUGIN_DEV=1 sa sla test lib/entity_dynamic.sla \
  --test-backend sa --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "task pool scoped task set" \
  --test-backend sa --jobs 1 --trace-panic
```

结果：`lib/entity_dynamic.sla` 7/7 passed，`task pool scoped task set` 16/16 passed。

完整聚合复验：

```sh
cd /home/vscode/projects/sla_ecs
timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --test-backend sa --jobs 1 --trace-panic

timeout 300s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --jobs 1 --trace-panic
```

结果：完整 generated-SA 129/129 passed；完整默认/SAB 路径 129/129 passed。历史上同一区域曾短暂出现 `InvalidArgsCount`，但最新 full-run 证据显示它不再是当前 blocker；`--filter "task pool scoped task set"` 仍保留为本 issue 的 focused generated-SA cleanup gate。

## 编译器侧修复

新增回归：`tests/test_unit_sa_aggregate_reassign_move_cleanup.sla`，覆盖：

```text
let (next_bag, value) = move_bag_advance(bag, ...);
bag = next_bag;
```

根因：identifier-to-identifier aggregate assignment 在生成 `bag = next_bag` 后，SA/SAB verifier 已把 RHS 当作 move 消费；旧 codegen 仍允许 loop-body cleanup 对 `next_bag` 发 `!next_bag`。direct SAB 旧路径同样会在 `assign bag,next_bag` 后再发 `move_ next_bag`，导致 strict SAB `UseAfterMove`。直接调用 release/move RHS 都不正确，因为会立刻生成额外消费。

修复：`src/codegen.zig` 在普通 identifier assignment 写入 target 后，如果 RHS 是非 Copy、非 borrow-like 的 identifier，则只迁移 compiler-side value-state metadata 并标记 RHS consumed，不输出额外 release；target 的 consumed 状态仍在新值写入后恢复为 live。`src/sab_codegen.zig` 对 identifier assignment 采用同样策略：`assign` 后只更新 emitter consumed 状态，不再额外发 `move_`；字段/索引 `store` 路径仍保留显式 move。

当前本地 10s strict direct-SAB no-fallback 复验：`tests/test_unit_sa_aggregate_reassign_move_cleanup.sla` 1/1 passed，约 2.01s。

## 摘要

`sla_ecs` 继续补 Bevy `TaskPool::scope` parity 时，新增 0-worker scope-thread drain 行为后，默认/SAB 后端整文件通过，但生成 SA 后端在 `tests/test_ecs_mut_parallel.sla` 的 scoped recursive runner 路径触发 verifier `UseAfterMove`。

失败点不是 SLA 类型检查：

```sh
cd /home/vscode/projects/sla_ecs
SA_PLUGIN_DEV=1 sa sla check lib/parallel_runner.sla
```

结果：

```text
Sla Compiler: Successfully parsed and verified syntax and types of lib/parallel_runner.sla.
```

## 复现命令

```sh
cd /home/vscode/projects/sla_ecs
timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "recursive scope records child generator lanes" \
  --test-backend sa --jobs 1 --trace-panic
```

## 历史 cleanup 失败输出

下游规避 `next` / `handle` 后，整文件 generated-SA 聚合仍可在 table-erased world attach 路径复现同类 move cleanup 问题：

```sh
cd /home/vscode/projects/sla_ecs
timeout 180s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --test-backend sa --jobs 1 --trace-panic
```

```text
error[UseAfterMove]: moved value is no longer usable
  in function @sla__table_erased_world_attach_with_values_TableErasedTime_Tabl
  line 41255 (expanded 25624):     !next_world
  register: next_world
  state: expected Consumed, actual Consumed
{"trap":"UseAfterMove","trap_code":1009,"file":"tests/test_ecs_mut_parallel.test.sa","line":25624,"source_line":41255,"source_text":"    !next_world","original_text":"    !next_world","register":"next_world","expected_mask_name":"Consumed","actual_mask_name":"Consumed","function":"@sla__table_erased_world_attach_with_values_TableErasedTime_Tabl","message":"moved value is no longer usable"}
```

上一轮同一整文件聚合还曾在旧 allocator 测试里暴露 `next_a` cleanup failure：

```text
error[UseAfterMove]: moved value is no longer usable
  in function @test "dynamic allocator grows beyond fixed capacity"():
  line 92494 (expanded 116474):     !next_a
  register: next_a
```

规避前，新增 scoped recursive runner 路径曾稳定复现：

```text
error[UseAfterMove]: moved value is no longer usable
  in function @sla__ecs_parallel_task_pool_scope_run_tasks_recursive_with_opti
  line 32823 (expanded 16787):     !next
  register: next
  state: expected Consumed, actual Consumed
{"trap":"UseAfterMove","trap_code":1009,"file":"tests/test_ecs_mut_parallel.test.sa","line":16787,"source_line":32823,"source_text":"    !next","original_text":"    !next","register":"next","expected_mask_name":"Consumed","actual_mask_name":"Consumed","function":"@sla__ecs_parallel_task_pool_scope_run_tasks_recursive_with_opti","message":"moved value is no longer usable"}
```

同一轮还观察到过相同形态的 generated-SA cleanup failure：`let handle = handles[j]; handle.join().unwrap();` 后生成 `!handle`，报 `handle` already consumed。下游已把该处改为直接 `handles[j].join().unwrap()` 规避。

2026-07-06 继续实现 pool-lane child generator threaded execution 时，又观察到两个 related generated-SA failure，默认/SAB 后端均通过：

```text
error[UseAfterMove]: moved value is no longer usable
  in function @sla__ecs_parallel_task_pool_scope_run_tasks_recursive_with_opti
  line 32024 (expanded 15707):     !child_handle
  register: child_handle
  state: expected Consumed, actual Consumed
```

下游将 `let child_handle = thread::spawn(...); child_handle.join().unwrap()` 改成链式 `thread::spawn(...).join().unwrap()` 后，generated-SA 继续暴露同一函数内的局部重定义问题：

```text
error[RegisterRedefinition]: register is already live
  in function @sla__ecs_parallel_task_pool_scope_run_tasks_recursive_with_opti
  line 32650 (expanded 16481):     child_tasks = tmp_3364
  register: child_tasks
```

下游最终通过“不在多分支中复用 `child_tasks` 可重赋值局部、每个分支直接 merge generated task set”规避。

2026-07-06 继续实现 pool-lane child-result generator 批处理时，generated-SA focused 测试还观察到一个同类控制流状态合并问题，默认/SAB 后端通过：

```text
error[PhiStateConflict]: incoming control-flow states do not agree
  in function @sla__ecs_parallel_task_pool_scope_run_tasks_recursive_with_opti
  line 32678 (expanded 16485):     jmp L_WHILE_HEAD_991
  register: result_value
  state: expected Consumed, actual Active
```

下游将跨分支可重赋值的 `result_value` 改为各分支局部绑定后，focused generated-SA 用例通过；整文件 generated-SA 仍回到上面的 aggregate cleanup failure。

## 下游规避记录

`sla_ecs` 当前未改编译器，只做了两类源码级规避：

- 避免 `JoinHandle` 从 `Vec` 取出到局部后再 consuming `join()`，改为直接 `handles[j].join().unwrap()`；
- 避免 `JoinHandle` 先绑定到局部再 consuming `join()`，在 child generator threaded path 中改为链式 `thread::spawn(...).join().unwrap()`；
- 避免多分支复用同一个 aggregate local 后反复赋值，改为每个分支直接把 generated task set merge 到目标 task set；
- 避免 `pending = next` 直接把局部 aggregate move 给另一个 local，改为 `pending = ecs_parallel_scoped_task_set_extend(ecs_parallel_scoped_task_set_new(), next)`，复用已有 child-set move helper 形态。

规避后，相关 focused generated-SA 用例通过：

```sh
timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "recursive scope records child generator lanes" \
  --test-backend sa --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "task pool scoped task set" \
  --test-backend sa --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "recursive scope" \
  --test-backend sa --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "child result generators by workers" \
  --test-backend sa --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "nested child result generators by workers" \
  --test-backend sa --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "ticks child generator lanes" \
  --test-backend sa --jobs 1 --trace-panic
```

结果：

```text
1 passed; 0 failed; 0 skipped
16 passed; 0 failed; 0 skipped
11 passed; 0 failed; 0 skipped
1 passed; 0 failed; 0 skipped
1 passed; 0 failed; 0 skipped
1 passed; 0 failed; 0 skipped
```

## 已通过对照

默认/SAB 后端整文件通过：

```sh
timeout 300s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --jobs 1 --trace-panic
```

结果：

```text
128 passed; 0 failed; 0 skipped
```

新增 0-worker 用例在默认/SAB 后端通过：

```sh
timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "zero workers drains" --jobs 1 --trace-panic
```

结果：

```text
1 passed; 0 failed; 0 skipped
```

## 初步判断

疑似 generated-SA lowering/verifier cleanup 对 move 后局部变量仍生成 release：

- `next` 是 `EcsParallelScopedTaskSet<R,M>` 局部值；
- loop 内逐步 `next = ecs_parallel_scoped_task_set_extend(next, child_tasks)`；
- round 末尾 `pending = next` 后，生成 SA 仍对已 consumed 的 `next` 发出 `!next` cleanup；
- 类似形态也曾出现在 `JoinHandle` 局部 move 后 cleanup。

建议编译器侧检查：

- 赋值 move 后源 local 的 cleanup 是否被正确抑制；
- loop/block 作用域结束时 aggregate local cleanup 是否忽略 consumed 状态；
- indexed move 到局部后调用 consuming 方法时，局部 cleanup 是否重复释放；
- generated-SA 与 SAB 后端在 move cleanup metadata 上是否存在差异。
