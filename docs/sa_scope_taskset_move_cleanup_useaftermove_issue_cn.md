# 生成 SA scoped task set move cleanup UseAfterMove issue

日期：2026-07-06

状态：新发现，下游 `sla_ecs` 已对当前 scoped-task-set 和 `JoinHandle` 形态做局部规避；生成 SA 整文件聚合仍可在无关旧测试中复现同类 cleanup 问题。不修改 SLA 编译器源码。

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

## 当前失败输出

下游规避 `next` / `handle` 后，整文件 generated-SA 聚合仍可在旧 allocator 测试里复现同类 move cleanup 问题：

```sh
cd /home/vscode/projects/sla_ecs
timeout 180s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --test-backend sa --jobs 1 --trace-panic
```

```text
error[UseAfterMove]: moved value is no longer usable
  in function @test "dynamic allocator grows beyond fixed capacity"():
  line 90921 (expanded 114484):     !next_a
  register: next_a
  state: expected Consumed, actual Consumed
{"trap":"UseAfterMove","trap_code":1009,"file":"tests/test_ecs_mut_parallel.test.sa","line":114484,"source_line":90921,"source_text":"    !next_a","original_text":"    !next_a","register":"next_a","expected_mask_name":"Consumed","actual_mask_name":"Consumed","function":"@test \"dynamic allocator grows beyond fixed capacity\"():","message":"moved value is no longer usable"}
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

## 下游规避记录

`sla_ecs` 当前未改编译器，只做了两类源码级规避：

- 避免 `JoinHandle` 从 `Vec` 取出到局部后再 consuming `join()`，改为直接 `handles[j].join().unwrap()`；
- 避免 `pending = next` 直接把局部 aggregate move 给另一个 local，改为 `pending = ecs_parallel_scoped_task_set_extend(ecs_parallel_scoped_task_set_new(), next)`，复用已有 child-set move helper 形态。

规避后，相关 focused generated-SA 用例通过：

```sh
timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "recursive scope records child generator lanes" \
  --test-backend sa --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "task pool scoped task set" \
  --test-backend sa --jobs 1 --trace-panic
```

结果：

```text
1 passed; 0 failed; 0 skipped
16 passed; 0 failed; 0 skipped
```

## 已通过对照

默认/SAB 后端整文件通过：

```sh
timeout 300s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --jobs 1 --trace-panic
```

结果：

```text
122 passed; 0 failed; 0 skipped
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
