# SAB compiler checker-pool 单测 10 秒无输出超时

日期：2026-07-07

## 现象

`sla_tsgo` 新增的 compiler checker-pool 拆分单测在 strict SAB 模式下 10 秒无输出超时，退出码 124。相同环境下 `test_core_contract.sla` 可以通过，说明 SAB 后端基础执行可用，问题集中在导入 `members/compiler/src/compiler.sla` 并调用 retained `ProgramCheckerPoolState` / checker lifecycle 路径的小单元。

## 环境

- 仓库：`/home/vscode/projects/mnt/sla_tsgo`
- 后端：`--test-backend sab`
- 环境变量：`SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1`
- 超时策略：所有测试命令外层使用 `timeout 10s`

## 可复现命令

```sh
cd /home/vscode/projects/mnt/sla_tsgo

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_compiler_checker_pool_api_contract.sla --test-backend sab

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_compiler_checker_pool_discard_contract.sla --test-backend sab

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_compiler_checker_pool_cancel_contract.sla --test-backend sab

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_compiler_checker_pool_diagnostics_contract.sla --test-backend sab

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_compiler_checker_pool_query_contract.sla --test-backend sab

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_compiler_checker_pool_idle_contract.sla --test-backend sab

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_compiler_checker_pool_global_diagnostics_contract.sla --test-backend sab

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_compiler_checker_pool_canceled_global_diagnostics_contract.sla --test-backend sab
```

这些命令均表现为 10 秒内没有 stdout/stderr，`timeout` 返回 124。`test_compiler_checker_pool_diagnostics_contract.sla`、`test_compiler_checker_pool_query_contract.sla`、`test_compiler_checker_pool_idle_contract.sla` 于 2026-07-07 追加复核，仍是 strict SAB 10 秒无输出超时。`test_compiler_checker_pool_global_diagnostics_contract.sla` 和 `test_compiler_checker_pool_canceled_global_diagnostics_contract.sla` 于 2026-07-07 追加复核，修正测试内 move 顺序后仍是 strict SAB 10 秒无输出超时。

## 对照命令

```sh
timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_core_contract.sla --test-backend sab
```

该命令通过：5 passed。

## 静态检查

以下命令均通过：

```sh
timeout 10s env SA_PLUGIN_DEV=1 sa sla check members/compiler/src/compiler.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_compiler_checker_pool_api_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_compiler_checker_pool_discard_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_compiler_checker_pool_cancel_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_compiler_checker_pool_diagnostics_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_compiler_checker_pool_query_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_compiler_checker_pool_idle_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_compiler_checker_pool_global_diagnostics_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_compiler_checker_pool_canceled_global_diagnostics_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_compiler_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check members/project/src/snapshot.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check members/ls/src/ls.sla
```

## 最小化状态

测试已经拆成三个单测试文件，每个文件只包含一个 `@test`：

- API checker release 后保持 stable identity。
- checker pool discard 后保留 API checker。
- canceled API checker release 后清除 persistent checker，并在下次 acquire 创建新 identity。
- diagnostics checker 使用固定 dedicated slot，release 后调度 idle cleanup。
- query checker release 后按 file affinity 复用。
- idle cleanup 清理 diagnostics/query checker，但保留独立 API checker。
- diagnostics/query checker release 时可合并 count-level global diagnostics，并由 TakeNewGlobalDiagnostics 重置 changed 标志。
- canceled checker release 跳过 global diagnostics merge。

## 2026-07-07 Module Table 复核

`sa_plugin_sla/src/plugin.zig` 已加入第一阶段 `SlaModuleTable`，对同一次 import expansion 内的重复 `.sla` import 做 resolved-path 解析缓存，并避免重复输出同一模块声明。但 checker-pool API 单测仍无法在 10 秒内完成 strict SAB build：

```sh
cd /home/vscode/projects/mnt/sla_tsgo
/usr/bin/time -f 'elapsed %e maxrss %M' timeout 10s env SLA_PROFILE=1 SLA_SAB_NO_FALLBACK=1 \
  /home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli \
  sla sab build tests/test_compiler_checker_pool_api_contract.sla \
  --out /tmp/compiler_checker_pool_api.sab
```

结果：`timeout` 退出码 124，`elapsed 10.03 maxrss 150784`。已输出 profile：

- `parse`: 709ms
- `import expand`: 1914ms
- `monomorphize`: 50ms
- `load contracts`: 1631ms
- `type check`: 5302ms 后仍未完成

判断：该工单已经证明单纯 SAB 后端优化或重复解析缓存不够。剩余主要成本来自 flatten 后对 imported body 的无差别 typecheck；后续需要模块符号表、导出签名索引和按调用路径懒惰 typecheck。

## 2026-07-07 test-codegen 可达裁剪复核

`sa_plugin_sla/src/plugin.zig` 已在 test-input 生成路径启用 `pre-typecheck reachable decl filter`，并在 typecheck 后、direct-SAB codegen 前启用精确 `reachable decl filter`。两者都会裁掉未被当前 `@test` 可达的顶层函数和 inherent impl/overload 方法，但保留 trait impl 整组以避免 vtable 破洞。复核命令使用真实 `sla test` 路径：

```sh
cd /home/vscode/projects/mnt/sla_tsgo
/usr/bin/time -f 'elapsed %e maxrss %M' timeout 10s env SLA_PROFILE=1 SLA_SAB_NO_FALLBACK=1 \
  /home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli \
  sla test tests/test_compiler_checker_pool_api_contract.sla --test-backend sab --trace-panic
```

结果：仍为 `timeout` 退出码 124，`elapsed 10.05 maxrss 148736`。已输出 profile：

- `parse`: 554ms
- `import expand`: 1098ms
- `monomorphize`: 25ms
- `pre-typecheck reachable decl filter`: 122ms
- `load contracts`: 1097ms
- `type check`: 2948ms
- `primary decl filter`: 2ms
- `reachable decl filter`: 5ms

判断：该切片降低了无差别 imported body/output 压力，但未关闭 checker-pool strict SAB 10s timeout。timeout 现在发生在 reachable decl filter 之后，说明继续只裁输出不够；下一步要减少 import expansion、contract/std helper loading 和 direct-SAB codegen 依赖加载，并把 ModuleGraph/shallow signature index 推到 import expansion 阶段。

## 2026-07-07 import-expansion 可达体裁剪复核

`sa_plugin_sla/src/plugin.zig` 的 test-codegen 路径现在会在 import expansion 前先收集 `.sla` Module Table/ModuleGraph，按当前选中 `@test` 的语法调用闭包只扁平化可达的 imported top-level function 和 inherent impl/overload 方法。类型、trait、const、macro 和 trait impl 仍保留，避免破坏 typecheck/vtable 安全。复核仍使用真实 `sla test` 路径和 10 秒硬超时：

```sh
cd /home/vscode/projects/mnt/sla_tsgo
/usr/bin/time -f 'elapsed %e maxrss %M' timeout 10s env SLA_PROFILE=1 SLA_SAB_NO_FALLBACK=1 \
  /home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli \
  sla test tests/test_compiler_checker_pool_api_contract.sla --test-backend sab --trace-panic
```

结果：仍为 `timeout` 退出码 124，`elapsed 10.02 maxrss 226176`。已输出 profile：

- `parse`: 298ms
- `import expand`: 696ms
- `monomorphize`: 9ms
- `pre-typecheck reachable decl filter`: 44ms
- `load contracts`: 629ms
- `type check`: 1658ms
- `primary decl filter`: 0ms
- `reachable decl filter`: 4ms

判断：该 slice 明显降低了 checker-pool 的 import expand 和 typecheck 成本，但本工单仍未关闭；timeout 仍发生在 reachable decl filter 之后。下一步应集中在 direct-SAB codegen/output 阶段的可达依赖加载，以及把当前 test-only reachability 进一步下沉为真正的 ModuleGraph/shallow signature index 和 lazy imported-body typecheck。

## 2026-07-07 vtable-aware trait impl 裁剪复核

`sa_plugin_sla/src/plugin.zig` 已在 typecheck 后、direct-SAB codegen 前加入 vtable-aware trait impl 输出裁剪：只有在 trait impl 没有任何可达 trait 方法，且当前可达测试/函数没有 dyn borrow、Box dyn 或 Rc dyn vtable 证据时，才会删除整组 trait impl；需要 vtable 的 impl 仍整组保留。`tests/test_unit_rc_dyn_trait.sla` strict SAB 10 秒 guard 已通过，证明此前的 vtable `UnknownRegister` 风险没有复现。

复核本工单真实路径：

```sh
cd /home/vscode/projects/mnt/sla_tsgo
/usr/bin/time -f 'elapsed %e maxrss %M' timeout 10s env SLA_PROFILE=1 SLA_SAB_NO_FALLBACK=1 \
  /home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli \
  sla test tests/test_compiler_checker_pool_api_contract.sla --test-backend sab --trace-panic
```

结果：仍为 `timeout` 退出码 124，`elapsed 10.03 maxrss 223872`。已输出 profile：

- `parse`: 360ms
- `import expand`: 831ms
- `monomorphize`: 10ms
- `pre-typecheck reachable decl filter`: 45ms
- `load contracts`: 693ms
- `type check`: 1578ms
- `primary decl filter`: 0ms
- `reachable decl filter`: 6ms

判断：vtable-aware trait impl 裁剪是安全的 codegen 前缩减，但对 checker-pool timeout 没有实质改善。本工单仍主要卡在 reachable filter 之后的 direct-SAB/codegen 依赖加载，以及尚未完成的 ModuleGraph/lazy imported-body typecheck。

## 期望

SAB 应在 10 秒窗口内完成这些单测试的编译和执行；如果有所有权或运行期错误，应输出具体 trap，而不是无输出挂到外层 timeout。
