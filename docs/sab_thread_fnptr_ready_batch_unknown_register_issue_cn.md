# SAB thread/function-pointer ready-batch path UnknownRegister issue

日期：2026-07-06

状态：已修复并验证（2026-07-06）。修复位于 `sa_plugin_sla` 编译器侧；`sla_ecs` 仅作为下游回归证据。

## 修复摘要

`sa_plugin_sla` 已补充本地最小回归 `tests/test_unit_fn_ptr_thread_pair_direct.sla`，覆盖两个
`thread::spawn` 闭包同时捕获函数指针参数和克隆后的 `Arc<*TinyWorld>` 值。

direct SAB 修复点：

- 记录 call-body 文本中引用到的寄存器到当前函数 metadata，避免 SAB verifier 在 scoped register
  metadata 下把 call 目标/参数视为未声明；
- 对 Rc/Arc receiver `clone()` 走 direct SAB smart-pointer clone 宏，避免生成未解析的
  `@sla__clone(shared)` call text。

验证：

```sh
zig build test -Dtest-filter="escaped thread closure function pointer" --summary all
zig build test -Dtest-filter="paired escaped thread function pointer" --summary all
zig build --summary all

./zig-out/bin/sla-local-cli sla test tests/test_unit_fn_ptr_thread_pair_direct.sla \
  --test-backend sa --jobs 1 --trace-panic

SLA_SAB_NO_FALLBACK=1 ./zig-out/bin/sla-local-cli sla test tests/test_unit_fn_ptr_thread_pair_direct.sla \
  --test-backend sab --jobs 1 --trace-panic

sa plugin install --dev .
SA_PLUGIN_DEV=1 sa sla help
```

下游 focused 回归均通过：

```sh
cd /home/vscode/projects/sla_ecs

SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "ready pair bridge advances plan" --jobs 1 --trace-panic

SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "ready pair runner rejects mismatched batch order" --jobs 1 --trace-panic

SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "ready triple bridge releases dependent" --jobs 1 --trace-panic

SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "width dispatch selects pair" --jobs 1 --trace-panic

SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "width dispatch one releases dependent" --jobs 1 --trace-panic
```

## 背景

`sla_ecs` 在把 multi-threaded executor 的 ready-batch 计划层接到真实 pthread runner 时，新增了
ready-pair / ready-triple / width-dispatch 窄桥接：`ecs_parallel_run_ready_pair_batch`、
`ecs_parallel_run_ready_triple_batch` 和 `ecs_parallel_run_ready_batch_up_to3`。这些函数从
`EcsExecutorRunPlan` 取出 ready 系统，校验 batch 顺序和 exclusive/local 标记，然后通过已有 pthread
runner 或 singleton serial fallback 执行传入的函数指针。

ECS 侧 SA backend 已通过，说明库逻辑和类型检查成立；默认 SAB backend 在相同 focused tests 上触发
SA verifier 的 `UnknownRegister`。

## 复现仓库

```text
/home/vscode/projects/sla_ecs
```

相关文件：

- `lib/parallel_runner.sla`
- `lib/executor_multi_threaded.sla`
- `tests/test_ecs_mut_parallel.sla`

## 通过的 SA 验证

```sh
cd /home/vscode/projects/sla_ecs

SA_PLUGIN_DEV=1 sa sla check lib/parallel_runner.sla

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "ready pair bridge advances plan" \
  --test-backend sa --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "ready pair runner rejects mismatched batch order" \
  --test-backend sa --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "ready triple bridge releases dependent" \
  --test-backend sa --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "width dispatch selects pair" \
  --test-backend sa --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "width dispatch one releases dependent" \
  --test-backend sa --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --test-backend sa --jobs 1 --trace-panic
```

结果：focused 五个测试通过；整文件 SA backend 75/75 passed。

## 失败的 SAB/default 验证

```sh
cd /home/vscode/projects/sla_ecs

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "ready pair bridge advances plan" \
  --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "ready pair runner rejects mismatched batch order" \
  --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "ready triple bridge releases dependent" \
  --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "width dispatch selects pair" \
  --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "width dispatch one releases dependent" \
  --jobs 1 --trace-panic
```

两个 focused default/SAB runs 都失败，错误形态如下：

```text
error[UnknownRegister]: callee is not declared
  register: tmp_867
{"trap":"UnknownRegister","trap_code":1007,"file":".sla-cache/sab/test_ecs_mut_parallel-da122c4f33b3b1c9.sab","line":3995,"message":"callee is not declared","register":"tmp_867"}
```

以及：

```text
error[UnknownRegister]: callee is not declared
  register: tmp_785
{"trap":"UnknownRegister","trap_code":1007,"file":".sla-cache/sab/test_ecs_mut_parallel-d0af4ed4766b6def.sab","line":3716,"message":"callee is not declared","register":"tmp_785"}
```

ready-triple focused test 同类失败：

```text
error[UnknownRegister]: callee is not declared
  register: tmp_895
{"trap":"UnknownRegister","trap_code":1007,"file":".sla-cache/sab/test_ecs_mut_parallel-864b4f123057446f.sab","line":4066,"message":"callee is not declared","register":"tmp_895"}
```

width-dispatch focused tests 同类失败：

```text
error[UnknownRegister]: callee is not declared
  register: tmp_825
{"trap":"UnknownRegister","trap_code":1007,"file":".sla-cache/sab/test_ecs_mut_parallel-7791818b7595214b.sab","line":3815,"message":"callee is not declared","register":"tmp_825"}
```

```text
error[UnknownRegister]: callee is not declared
  register: tmp_850
{"trap":"UnknownRegister","trap_code":1007,"file":".sla-cache/sab/test_ecs_mut_parallel-79b2a425f4caa1cc.sab","line":3957,"message":"callee is not declared","register":"tmp_850"}
```

## 反汇编观察

```sh
SA_PLUGIN_DEV=1 sa sla sab disasm \
  .sla-cache/sab/test_ecs_mut_parallel-da122c4f33b3b1c9.sab \
  --out /tmp/ready_pair_advances.disasm.sa

SA_PLUGIN_DEV=1 sa sla sab disasm \
  .sla-cache/sab/test_ecs_mut_parallel-d0af4ed4766b6def.sab \
  --out /tmp/ready_pair_mismatch.disasm.sa
```

相关 disasm 片段显示 failure surface 在 `thread::spawn` worker 与函数指针间接调用附近：

```sa
call r2309,"@pthread_spawn","*tmp_956, *slot"
...
func_decl $sla_thread_worker_0,fn:2155
...
call_indirect r2315,"tmp_960","tmp_959"
```

另一个 focused artefact 中：

```sa
call r2167,"@pthread_spawn","*tmp_874, *slot"
...
func_decl $sla_thread_worker_0,fn:2013
...
call_indirect r2173,"tmp_878","tmp_877"
```

注意：这不是旧的 `@func(arg)` call-target 字符串拼接问题。`docs/sab_call_target_issue_cn.md` 的旧 guard
已经验证修复。本问题表现为 SAB/SA verifier 在 thread/function-pointer lowering 后认为某个临时 callee
register 未声明。

## 初步判断

疑似 direct SAB 或 SA-compatible SAB encode 在以下组合上丢失/错配了函数指针 callee 的 register 声明或
materialization 顺序：

```sla
fn runner(
    first: fn(Arc<*TableErasedWorld<R, M>>) -> i32,
    second: fn(Arc<*TableErasedWorld<R, M>>) -> i32,
) -> i32 {
    return ecs_parallel_run_mut_batch(world, first, second, access_a, access_b);
}
```

其中 `ecs_parallel_run_mut_batch` 内部使用 `thread::spawn(^|| first(shared_world))` 和
`thread::spawn(^|| second(shared_world))` 形态。

## ECS 侧处理

`sla_ecs` 不直接修改编译器源码。当前处理策略：

- ECS 完成证据使用 `--test-backend sa`；
- default/SAB failure 记录为 compiler issue；
- P0 executor 工作继续在 ECS 库层推进；
- 后续 compiler 修复后，应重新运行上述两个 default/SAB focused tests。

## 建议 compiler 回归

构造一个小型 fixture，避免依赖完整 `sla_ecs`：

```sla
fn worker_arg(p: Arc<*TinyWorld>) -> i32 { return 1; }

fn run_pair(
    world: TinyWorld,
    first: fn(Arc<*TinyWorld>) -> i32,
    second: fn(Arc<*TinyWorld>) -> i32,
) -> i32 {
    let ptr = &world;
    let shared = Arc::new(ptr);
    let a = thread::spawn(^|| first(shared));
    let b = thread::spawn(^|| second(shared));
    return a.join() + b.join();
}
```

验证目标：

```sh
SA_PLUGIN_DEV=1 sa sla test <fixture>.sla --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test <fixture>.sla --test-backend sab --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test <fixture>.sla --test-backend sab --jobs 1 --trace-panic
```

SAB 修复完成后，应同时重跑 `sla_ecs/tests/test_ecs_mut_parallel.sla` 的两个 ready-pair focused tests。
