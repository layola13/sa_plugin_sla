# SAB task-pool custom batch width focused test UnknownRegister issue

日期：2026-07-07

状态：已修复。下游 `sla_ecs` generated-SA、默认/SAB focused tests 均通过；本记录保留原始 verifier `UnknownRegister dst` 复现和修复证据。

## 背景

`sla_ecs` 为 `lib/parallel_runner.sla` 的 Bevy ECS multi-threaded executor / TaskPool 模型新增了 `ecs_parallel_task_pool_with_batch_width(worker_count, max_batch_width)`，用于把 TaskPool worker 数和每批调度宽度分开建模。新增 focused 测试：

```text
tests/test_ecs_mut_parallel.sla
task pool custom batch width separates worker count from waves
```

该测试覆盖：

- `worker_count=4`，`max_batch_width=2`
- lifecycle callbacks 按 worker 数运行 4 次
- scoped threaded tasks 按 batch width 形成 3 个 waves

## 通过的 generated-SA 验证

```sh
cd /home/vscode/projects/sla_ecs

timeout 120s env SA_PLUGIN_DEV=1 sa sla check lib/parallel_runner.sla

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --test-backend sa \
  --filter "task pool custom batch width separates worker count from waves" \
  --jobs 1 --trace-panic

timeout 240s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --test-backend sa --jobs 1 --trace-panic
```

结果：

```text
focused: 1 passed; 0 failed; 0 skipped
whole file: 133 passed; 0 failed; 0 skipped
```

## 失败的默认/SAB focused 验证

```sh
cd /home/vscode/projects/sla_ecs

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "task pool custom batch width separates worker count from waves" \
  --jobs 1 --trace-panic
```

失败输出：

```text
error[UnknownRegister]: register is not declared in the current scope
  register: dst
{"trap":"UnknownRegister","trap_code":1007,"file":".sla-cache/sab/test_ecs_mut_parallel-6fdd429b04c217b2.sab","line":899,"source_line":0,"column":null,"source_text":null,"original_text":null,"bad_token":null,"context":[],"register":"dst","registers":[],"expected_mask":null,"actual_mask":null,"expected_mask_name":null,"actual_mask_name":null,"upstream_loc":null,"function":null,"is_ffi_wrapper":false,"message":"register is not declared in the current scope","hint":null}
```

## 第二个同类复现：MainThreadExecutor 派生 options

同日 `sla_ecs` 又为 Bevy `MainThreadExecutor(pub Arc<ThreadExecutor<'static>>)` 对应模型新增了
`EcsParallelMainThreadExecutor` facade，并通过
`ecs_parallel_scope_options_with_main_thread_executor(...)` 从 owner-thread ticker / executor identity 派生
`EcsParallelScopeOptions`。generated-SA 通过，默认/SAB focused test 仍触发同类 `dst` 未声明。

通过的 generated-SA：

```sh
cd /home/vscode/projects/sla_ecs

timeout 120s env SA_PLUGIN_DEV=1 sa sla check lib/parallel_runner.sla

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --test-backend sa \
  --filter "main thread executor facade preserves owner ticker and identity" \
  --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --test-backend sa \
  --filter "external executor identity" \
  --jobs 1 --trace-panic

timeout 240s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --test-backend sa --jobs 1 --trace-panic
```

结果：

```text
main thread executor facade preserves owner ticker and identity: 1 passed
main thread executor options drive external executor identity: 1 passed
whole file: 139 passed; 0 failed; 0 skipped
```

默认/SAB 对照：

```sh
timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "main thread executor facade preserves owner ticker" \
  --jobs 1 --trace-panic
```

结果：通过。

```sh
timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "external executor identity" \
  --jobs 1 --trace-panic
```

失败输出：

```text
error[UnknownRegister]: register is not declared in the current scope
  register: dst
{"trap":"UnknownRegister","trap_code":1007,"file":".sla-cache/sab/test_ecs_mut_parallel-e290e6e2f1f177a7.sab","line":2483,"source_line":0,"column":null,"source_text":null,"original_text":null,"bad_token":null,"context":[],"register":"dst","registers":[],"expected_mask":null,"actual_mask":null,"expected_mask_name":null,"actual_mask_name":null,"upstream_loc":null,"function":null,"is_ffi_wrapper":false,"message":"register is not declared in the current scope","hint":null}
```

## 根因与修复

根因在 `sa_plugin_sla/src/sab_codegen.zig::recordCallBodyRegs()`。direct SAB 会把 decoded std macro fragment 中出现过的符号名加入全局 `symbol_ids`；其中包含宏内部/历史形参名 `dst`。旧实现扫描任意 call body 文本时，只要 token 已存在于全局 `symbol_ids`，就把它记录为当前函数 scope register。后续 call body 文本中出现裸 `dst` 时，`dst` 被误认为当前函数寄存器，最终 SAB verifier 报：

```text
error[UnknownRegister]: register is not declared in the current scope
  register: dst
```

修复：`recordCallBodyRegs()` 仍记录直接 call target，但 call body 中的普通 identifier 只有在已经属于当前函数 scope register 时才会被保留；全局 symbol table 中存在但当前函数未声明的 `dst` / `tmp_*` 不再被拉进当前函数 register list。

新增/更新回归：

```sh
zig build test -Dtest-filter="direct sab instruction reg scan records call body refs" --summary all
```

该回归覆盖：

- 显式 call 输出寄存器会记录；
- 当前 scope 已存在的参数寄存器会保留；
- 直接 callee symbol 会记录；
- 全局已知但当前 scope 未声明的 `dst` / `tmp_42` 不会被记录。

## 修复后验证

本地构建与回归：

```sh
zig fmt --check src/sab_codegen.zig
zig build test -Dtest-filter="direct sab instruction reg scan records call body refs" --summary all
zig build --summary all
zig build test --summary all
sa plugin install --dev .
SA_PLUGIN_DEV=1 sa sla help
```

结果：

- focused Zig test：1/1 passed；
- `zig build --summary all`：通过，约 44.34s，MaxRSS 约 1GB；
- `zig build test --summary all`：99/99 passed，约 43.26s，MaxRSS 约 1.1GB；
- 官方 dev install/help：通过；
- 未删除 `.zig-cache` / `zig-out` / `.sla-cache` / `.sa_cache`。

下游 focused 默认/SAB 验证：

```sh
cd /home/vscode/projects/sla_ecs

/usr/bin/time -f 'elapsed %e maxrss %M' timeout 10s env SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 \
  sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "task pool custom batch width separates worker count from waves" \
  --test-backend sab --trace-panic

/usr/bin/time -f 'elapsed %e maxrss %M' timeout 10s env SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 \
  sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "external executor identity" \
  --test-backend sab --trace-panic
```

结果：

```text
task pool custom batch width separates worker count from waves: 1 passed; elapsed 1.79
main thread executor options drive external executor identity: 1 passed; elapsed 1.93
```

本地 `zig-out` CLI 复跑也通过：

```text
task pool custom batch width separates worker count from waves: 1 passed; elapsed 2.18
```

## 原始初步判断

这不是早先已修复的 `callee/tmp_*` thread function-pointer issue，也不是整文件聚合 `UseAfterMove tmp_67` issue。当前 failure 是 focused default/SAB 路径在 `.sab` verifier 中引用了未声明的 `dst` register。

建议编译器侧优先检查：

- focused test 中 `EcsParallelTaskPool` struct 构造、clamp 后字段赋值和后续 by-value 复用的 SAB lowering；
- focused test 中 `EcsParallelMainThreadExecutor` 包装 `EcsThreadExecutor`、返回 `EcsParallelScopeOptions` 结构值、随后将 options by-value 传给 scope runner 的 SAB lowering；
- `thread::spawn` lifecycle callback 与 scoped task runner 同一 focused test 内共存时，SAB register metadata 是否遗漏 `dst` 临时；
- verifier source map 是否能把 `.sab` 第 899 行映射回 SLA 源表达式，便于进一步定位。
