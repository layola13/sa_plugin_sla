# SAB thread closure function-pointer capture issue in parallel iterator

日期：2026-07-06

状态：待修复。下游 `sla_ecs` 已用 generated-SA 后端验证业务实现正确；默认/SAB 后端仍在函数指针进入 `thread::spawn(^|| ...)` 的路径上产生错误结果。本文仅记录 issue，不修改 SLA 编译器源码。

## 摘要

`sla_ecs` 新增 Bevy `bevy_tasks::ParallelIterator` 风格的 `Vec<i32>` 批处理 consumer：`count`、`sum`、`product`、`min`/`max`、`collect`、`map`、`partition`、`fold`、`all`、`any`、`position`。

实现使用现有 `EcsParallelTaskPool`，在每个 batch 上通过 `thread::spawn(^|| ...)` 执行 worker，再按 batch 插入顺序 join 并合并结果。generated-SA 后端整文件通过，但默认/SAB 后端在捕获函数指针的 threaded worker 路径返回错误结果。

## 下游文件

```text
/home/vscode/projects/sla_ecs/lib/parallel_iterator.sla
```

关键形状：

```sla
handles.push(thread::spawn(^|| ecs_parallel_i32_iter_partition_batch(chunk, predicate)));
handles.push(thread::spawn(^|| ecs_parallel_i32_iter_fold_batch(chunk, init, folder)));
handles.push(thread::spawn(^|| ecs_parallel_i32_iter_predicate_batch(task_start, chunk, predicate)));
```

其中 `predicate` / `folder` 是命名函数指针参数。

## generated-SA 通过

```sh
cd /home/vscode/projects/sla_ecs
timeout 180s env SA_PLUGIN_DEV=1 sa sla test lib/parallel_iterator.sla \
  --test-backend sa --jobs 1 --trace-panic
```

结果：

```text
[PASS] parallel iterator stats count sum product min max
[PASS] parallel iterator empty stats match iterator identities
[PASS] parallel iterator collect and map preserve batch order
[PASS] parallel iterator partition preserves per side order
[PASS] parallel iterator fold returns one value per batch
[PASS] parallel iterator all any position consume whole batches
[PASS] parallel iterator zero worker runs inline
----
test result: ok. 76 passed; 0 failed; 0 skipped
```

## 默认/SAB 失败

最小下游焦点复现：

```sh
cd /home/vscode/projects/sla_ecs
timeout 180s env SA_PLUGIN_DEV=1 sa sla test lib/parallel_iterator.sla \
  --filter "parallel iterator partition" --jobs 1 --trace-panic
```

失败：

```text
error: test parallel iterator partition preserves per side order exited with code 27
  code path: "parallel iterator partition preserves per side order"
  panic: code=31131
  trace-panic: enabled
PANIC: code=31131
[FAIL] parallel iterator partition preserves per side order
----
test result: FAILED. 0 passed; 1 failed; 0 skipped
```

整文件默认/SAB 还会失败：

```text
[FAIL] parallel iterator partition preserves per side order  panic: code=31131
[FAIL] parallel iterator fold returns one value per batch      panic: code=31142
[FAIL] parallel iterator all any position consume whole batches panic: code=31150
test result: FAILED. 73 passed; 3 failed; 0 skipped
```

共同点：失败测试都把函数指针参数捕获进 `thread::spawn(^|| ...)`。不需要函数指针的 `stats` 路径，以及当前 `map` 焦点路径，通过默认/SAB。

## 尝试过的规避

把函数指针拆成任务局部再捕获：

```sla
let task_predicate = predicate;
handles.push(thread::spawn(^|| ecs_parallel_i32_iter_partition_batch(chunk, task_predicate)));
```

会让默认/SAB 在构建/校验阶段失败，错误更早：

```text
error[PhiStateConflict]: incoming control-flow states do not agree
  register: predicate
  state: expected Active, actual Consumed
{"trap":"PhiStateConflict","trap_code":1015,
 "file":".sla-cache/sab/parallel_iterator-fdee3bdc59968ce7.sab",
 "line":808,
 "register":"predicate",
 "expected_mask_name":"Active",
 "actual_mask_name":"Consumed",
 "message":"incoming control-flow states do not agree",
 "hint":"register 'predicate' has mismatched path states:\n  - Path via 'L_WHILE_EXIT_37': Active\n  - Path via target 'L_MERGE_29': Consumed\nSelf-repair hint: Consume/release 'predicate' on all paths (e.g. using '!predicate'), or don't consume it on any path."}
```

该规避未保留到 `sla_ecs`，因为 generated-SA 原实现正确，且 task-local 版本会引入 SAB verifier 状态冲突。

## 额外 generated-SA 代码形状发现

实现过程中还发现 generated-SA 对 `if matches != true` 的 bool 比较形状会导致 `all_match` 错误。下游已改写为显式分支：

```sla
if matches {
    any_match = true;
    ...
} else {
    all_match = false;
};
```

这个 generated-SA 形状已在下游规避，当前主阻塞点是默认/SAB 的 thread closure + function pointer capture。

## 初步判断

SAB 路径需要重点检查：

- `thread::spawn(^|| ...)` closure 环境中函数指针参数的捕获/复制/生命周期状态；
- 循环内多次 spawn 时，函数指针参数在不同控制流路径上的 Active/Consumed 状态合流；
- 函数指针作为普通 Copy-like callable 值时，SAB 是否错误地把某条捕获路径视为 consuming move；
- closure lowered call target 与函数指针 vtable/call-target 的线程入口传递。

下游当前按用户要求优先使用 generated-SA 继续推进 Bevy parity；SAB 问题留作编译器侧 issue。

## 2026-07-07 修复记录

状态：已在编译器侧修复并用本地 direct-SAB no-fallback 验证。官方 `sa plugin install --dev .` 本轮曾长时间无输出并被中断，因此下游 host 证据使用刚构建的 `zig-out/bin/sla-local-cli` 直接运行；提交前仍需在可用 host 环境重跑安装链路。

根因与修复：

- native SAB 间接调用 `fn(...) -> bool` 时，`i1` 返回 ABI 在跨 helper/thread-closure 组合路径上不稳定；SAB 函数签名层将 boolean 返回扩宽为 `i32`，返回点由 emitter/native lowering 负责 coercion，避免 `predicate(4)` 在 caller 侧变成 false。
- `thread::spawn(^|| ...)` 的 inline-join 路径不再把同步执行的 noncopy capture 当作逃逸结果强制消费，避免 loop 分支合流时 `chunk` 在一条路径 Active、另一条路径 Consumed。
- escaped worker 的 fnptr capture slot 现在保存实际 call target，worker 对 fnptr capture 使用 slot 地址，避免多一层间接。
- struct literal 显式 move 字段的标识符消费延迟到所有字段生成之后，修复 `batch_count: len(batch_starts)` 在 `batch_starts` 字段 move 后再次使用的 UseAfterMove。

新增/扩展回归：

```text
tests/test_unit_fn_ptr_thread_loop_partition_direct.sla
```

验证：

```sh
SLA_SAB_NO_FALLBACK=1 ./zig-out/bin/sla-local-cli sla test \
  tests/test_unit_fn_ptr_thread_loop_partition_direct.sla --test-backend sab --jobs 1 --trace-panic
SLA_SAB_NO_FALLBACK=1 ./zig-out/bin/sla-local-cli sla test \
  tests/test_unit_fn_ptr_value.sla --test-backend sab --jobs 1 --trace-panic
SLA_SAB_NO_FALLBACK=1 ./zig-out/bin/sla-local-cli sla test \
  tests/test_unit_fn_ptr_thread_pair_direct.sla --test-backend sab --jobs 1 --trace-panic
zig build test --summary all
cd /home/vscode/projects/sla_ecs
/home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli sla test \
  lib/parallel_iterator.sla --filter "parallel iterator partition" --test-backend sab --jobs 1 --trace-panic
/home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli sla test \
  lib/parallel_iterator.sla --filter "parallel iterator fold" --test-backend sab --jobs 1 --trace-panic
/home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli sla test \
  lib/parallel_iterator.sla --filter "parallel iterator all any position" --test-backend sab --jobs 1 --trace-panic
```
