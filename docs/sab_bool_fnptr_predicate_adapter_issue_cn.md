# SAB bool function-pointer predicate adapter result issue

日期：2026-07-06

状态：已修复并本地复验。下游 `sla_ecs` 已用 generated-SA 后端验证同一测试通过；默认/SAB 后端曾在普通 `fn(i32) -> bool` predicate adapter 路径返回错误结果。2026-07-07 已在编译器侧修复 direct-SAB bool fnptr 返回 ABI，并用本地 direct-SAB no-fallback 复验。

## 摘要

`sla_ecs` 为 Bevy `bevy_tasks::ParallelIterator` adapter parity 新增了 materialized `Vec<i32>` adapters：`chain`、`filter`、`filter_map`、`flat_map`、`flatten`、`inspect`、`copied`、`cloned`、`cycle_take`、`fuse_next_batch`。

其中 `chain + filter + filter_map` 测试在 generated-SA 后端通过，但默认/SAB 后端在普通 predicate adapter 上得到错误过滤结果。

这不同于 `docs/sab_thread_closure_fnptr_parallel_iterator_issue_cn.md`：当前问题不涉及 `thread::spawn(^|| ...)`，只涉及普通同步函数中调用 `fn(i32) -> bool` 函数指针并按结果分支。

## 下游文件

```text
/home/vscode/projects/sla_ecs/lib/parallel_iterator.sla
```

关键形状：

```sla
fn ecs_parallel_i32_iter_filter(values: Vec<i32>, predicate: fn(i32) -> bool) -> Vec<i32> {
    let out: Vec<i32> = Vec::new();
    let i: i64 = 0;
    while i < len(values) as i64 {
        let value = values[i];
        if predicate(value) { out.push(value); };
        i = i + 1;
    }
    return out;
}

fn ecs_parallel_i32_is_even(value: i32) -> bool { return value % 2 == 0; }
```

测试先把两个 Vec chain 起来，随后用 `ecs_parallel_i32_is_even` 过滤，期望得到 `[4, 2, 6]`。

## generated-SA 通过

```sh
cd /home/vscode/projects/sla_ecs
timeout 180s env SA_PLUGIN_DEV=1 sa sla test lib/parallel_iterator.sla \
  --filter "parallel iterator adapters chain filter filter map" \
  --test-backend sa --jobs 1 --trace-panic
```

结果：

```text
[PASS] parallel iterator adapters chain filter filter map
----
test result: ok. 1 passed; 0 failed; 0 skipped
```

整文件 generated-SA 也通过：

```text
test result: ok. 79 passed; 0 failed; 0 skipped
```

## 默认/SAB 失败

```sh
cd /home/vscode/projects/sla_ecs
timeout 180s env SA_PLUGIN_DEV=1 sa sla test lib/parallel_iterator.sla \
  --filter "parallel iterator adapters" --jobs 1 --trace-panic
```

结果：

```text
error: test parallel iterator adapters chain filter filter map exited with code 70
  code path: "parallel iterator adapters chain filter filter map"
  panic: code=31174
  trace-panic: enabled
PANIC: code=31174
[FAIL] parallel iterator adapters chain filter filter map
[PASS] parallel iterator adapters flat map flatten inspect copy clone
[PASS] parallel iterator adapters cycle take and fuse next batch
----
test result: FAILED. 2 passed; 1 failed; 0 skipped
```

`panic(31174)` 对应：

```sla
if len(filtered) != 3 { panic(31174); };
```

说明 `filter` 阶段的结果数量错误，而同一输入/同一函数指针在 generated-SA 下正确。

## 初步判断

SAB 路径需要检查：

- `fn(i32) -> bool` 函数指针的 indirect call 返回 bool 值；
- bool 返回值进入 `if predicate(value)` 分支时的条件 lowering；
- 循环内多次调用同一函数指针时，call target / return register / condition register 是否被错误复用或覆盖；
- 与 thread-closure fnptr capture issue 区分：本 issue 没有线程、没有 closure、没有 `JoinHandle`，是普通同步 adapter predicate。

下游当前继续按用户要求优先使用 generated-SA 推进 Bevy parity；SAB 问题留作编译器侧 issue。

## 2026-07-07 修复记录

状态：已在编译器侧修复并用本地 direct-SAB no-fallback 验证。根因与 thread-closure issue 共享：native SAB 间接调用 bool 返回时，`i1` 返回值在 caller 侧可被错误解释。SAB 函数签名层将 boolean 返回 ABI 扩宽为 `i32` 后，同步 predicate adapter 和 threaded predicate batch 均通过。

验证：

```sh
SLA_SAB_NO_FALLBACK=1 ./zig-out/bin/sla-local-cli sla test \
  tests/test_unit_fn_ptr_value.sla --test-backend sab --jobs 1 --trace-panic
cd /home/vscode/projects/sla_ecs
/home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli sla test \
  lib/parallel_iterator.sla --filter "parallel iterator adapters" --test-backend sab --jobs 1 --trace-panic
```

下游 adapter 结果：`chain filter filter map`、`flat map flatten inspect copy clone`、`cycle take and fuse next batch` 均通过。
