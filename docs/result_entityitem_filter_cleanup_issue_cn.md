# Result<EntityItem<T>> focused filter cleanup / SAB encoding issue

日期：2026-07-06

## 背景

`sla_ecs` 在补 `Result<T>` 风格的 recoverable `try_*` facade 时，尝试为
`ecs_world_try_query_single<T, R, M>` 增加 focused 测试。该函数返回
`Result<EntityItem<T>>`，用于表达 Bevy `QuerySingleError::{NoEntities, MultipleEntities}`。

整文件 SA 路径曾可通过，但对单个新增测试使用 `--filter` 剪枝后，会在生成的 SA verifier
阶段暴露 cleanup trap；默认 SAB 路径则在 SAB encode 阶段报告 `VerificationTrap`。

## 复现命令

仓库：`/home/vscode/projects/sla_ecs`

```sh
timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_result_facades.sla \
  --filter "ecs_world_try_query_single returns one" \
  --test-backend sa
```

观察到的 SA verifier 错误：

```text
error[MemoryLeak]: live registers remain at function exit
  in function @test "ecs_world_try_query_single returns one"():
  source_text: "    return"
  register: tmp_9615
  state: Active
```

默认/SAB 路径：

```sh
timeout 120s env SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_result_facades.sla \
  --filter "ecs_world_try_query_single returns one"
```

观察到：

```text
SAB Error: failed to encode SAB for .../.sla-cache/sab/test_ecs_result_facades-69b20eb29463be85.sa: error.VerificationTrap
```

## 期望

`--filter` 剪枝后的单测应与整文件 SA 语义一致：

- `Result<EntityItem<T>>` 的 ok/err payload 临时值在函数退出前被正确清理；
- SA verifier 不应留下 Active register；
- SAB backend 不应在编码同一生成 SA 时触发 `VerificationTrap`。

## 当前状态

状态：fixed/verified（2026-07-19）。

历史 host filter `"ecs_world_try_query_single returns one"` 仍为 stale（选中 0 个测试），不作为修复证据。
本轮以本地 focused regressions 为守卫，并修复了 direct SAB struct-literal 字段 move 未发
SAB-visible `move_` 导致的 `items` MemoryLeak（`cleanup_query_new` 路径）。

## 修复摘要

- direct SAB 函数退出清理现在会释放可清理的 borrow 参数，以及 by-value/move 的 pointer-shaped
  参数；raw 参数仍不释放。
- direct SAB 支持 `unsafe { ... }` 表达式、pointer-to-pointer cast 的 fresh bitcast、void
  function-pointer indirect call 的无目标 `call_indirect`。
- `Box::from_raw` 与 consuming `Box::into_raw` 进入 `sla_std/std_surface.sla_meta`，避免 raw
  pointer roundtrip 误释放或 unsupported。
- direct SAB 会把后续被赋值的 primitive `let`/参数绑定物化成 stack slot，避免
  `scan = scan - 1`、`found = scan` 这类循环变量在 SAB verifier 中变成 UseAfterMove 或
  RegisterRedefinition。
- direct SAB struct-literal field move 对源 local 发出 `move_`（不再只 `markConsumed`）。

新增/守卫 focused regressions：

- `tests/test_unit_result_entityitem_self_cleanup.sla`
- `tests/test_unit_box_from_raw_direct.sla`
- `tests/test_unit_fn_ptr_void_direct.sla`
- `tests/test_unit_scalar_reassign_scan_direct.sla`

## 验证证据（2026-07-19 local CLI）

```sh
./zig-out/bin/sla-local-cli sla test tests/test_unit_result_entityitem_self_cleanup.sla \
  --test-backend sa --jobs 1 --trace-panic   # 1/1
SLA_SAB_NO_FALLBACK=1 ./zig-out/bin/sla-local-cli sla test \
  tests/test_unit_result_entityitem_self_cleanup.sla --test-backend sab --jobs 1 --trace-panic  # 1/1
# box/fn_ptr/scalar_reassign fixtures likewise SA+SAB 1/1 each
```

## 剩余说明

本文件只表示该 docs-priority issue 的当前 repro surface 已修复。全局 roadmap 仍保持开放：完整
RefCell 生命周期、broader macro convergence、完整 shared call/materialization plan、broader async、
closures/callables、SCI fragment naming/boundary 等仍需继续推进。
