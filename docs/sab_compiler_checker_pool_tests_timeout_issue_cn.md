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
```

这些命令均表现为 10 秒内没有 stdout/stderr，`timeout` 返回 124。`test_compiler_checker_pool_diagnostics_contract.sla`、`test_compiler_checker_pool_query_contract.sla`、`test_compiler_checker_pool_idle_contract.sla` 于 2026-07-07 追加复核，仍是 strict SAB 10 秒无输出超时。

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

`sa_plugin_sla/src/plugin.zig` 已在 test-input 生成路径启用 `pre-typecheck reachable decl filter`，会在 typecheck 前裁掉未被当前 `@test` 可达的顶层函数和 inherent impl/overload 方法。复核命令使用真实 `sla test` 路径：

```sh
cd /home/vscode/projects/mnt/sla_tsgo
/usr/bin/time -f 'elapsed %e maxrss %M' timeout 10s env SLA_PROFILE=1 SLA_SAB_NO_FALLBACK=1 \
  /home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli \
  sla test tests/test_compiler_checker_pool_api_contract.sla --test-backend sab --trace-panic
```

结果：仍为 `timeout` 退出码 124，`elapsed 10.06 maxrss 202752`。已输出 profile：

- `parse`: 299ms
- `import expand`: 608ms
- `monomorphize`: 13ms
- `pre-typecheck reachable decl filter`: 98ms
- `load contracts`: 624ms
- `type check`: 1741ms

判断：该切片显著降低了无差别 imported body typecheck 压力，但未关闭 checker-pool strict SAB 10s timeout。timeout 现在发生在 typecheck 和 primary/reachable decl filter 之后，说明下一步要继续减少 direct-SAB codegen/output 阶段的非可达声明生成，并把 ModuleGraph/shallow signature index 推到 import expansion 阶段。

## 期望

SAB 应在 10 秒窗口内完成这些单测试的编译和执行；如果有所有权或运行期错误，应输出具体 trap，而不是无输出挂到外层 timeout。
