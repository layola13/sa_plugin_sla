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

已验证修复当前可复现的 host surface。历史 focused filter：

```sh
SA_PLUGIN_DEV=1 sa sla test /home/vscode/projects/sla_ecs/tests/test_ecs_result_facades.sla \
  --test-backend sa --jobs 1 --trace-panic \
  --filter "ecs_world_try_query_single returns one"
```

当前仍选中 `0` 个测试，因此它是 stale filter，不作为修复证据。修复证据改用当前 host 文件的
完整 installed SA/SAB gate 和插件内 focused regressions。

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

新增 focused regressions：

- `tests/test_unit_result_entityitem_self_cleanup.sla`
- `tests/test_unit_box_from_raw_direct.sla`
- `tests/test_unit_fn_ptr_void_direct.sla`
- `tests/test_unit_scalar_reassign_scan_direct.sla`

## 验证证据

- `zig build --summary all` 通过。
- `zig build test --summary all`：85/85 通过。
- local strict direct-SAB no-fallback sweep：107/107 `tests/test_unit_*.sla` files，260/260 cases。
- `sa plugin install --dev .` 通过。
- `SA_PLUGIN_DEV=1 sa sla help` 通过。
- installed host ECS strict direct-SAB no-fallback：`/home/vscode/projects/sla_ecs/tests/test_ecs_result_facades.sla` 172/172 通过。
- installed host ECS SA-text：同文件 172/172 通过。
- installed host `parallel.sla` strict direct-SAB no-fallback：1/1 通过。
- installed focused borrow-temp 25/25、RefCell payload 7/7 通过。
- SAB disasm call-target guard 无非法 `@...(` target 匹配。

## 剩余说明

本文件只表示该 docs-priority issue 的当前 repro surface 已修复。全局 roadmap 仍保持开放：完整
RefCell 生命周期、broader macro convergence、完整 shared call/materialization plan、broader async、
closures/callables、SCI fragment naming/boundary 等仍需继续推进。
