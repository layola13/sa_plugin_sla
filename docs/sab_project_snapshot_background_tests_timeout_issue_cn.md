# SAB project snapshot/project collection/config registry/API 单测 10 秒无输出超时

日期：2026-07-07

## 现象

`sla_tsgo` 中拆分后的 project snapshot / project collection / config registry / API 单测在 strict SAB 模式下 10 秒无输出超时，退出码 124。相同环境下 `test_core_contract.sla` 可以通过，说明 SAB 后端基础执行可用，问题集中在导入 `members/project/src/snapshot.sla` 并调用 project session snapshot / collection / config registry / API 路径的小单元。

## 环境

- 仓库：`/home/vscode/projects/mnt/sla_tsgo`
- 后端：`--test-backend sab`
- 环境变量：`SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1`
- 超时策略：所有测试命令外层使用 `timeout 10s`

## 可复现命令

```sh
cd /home/vscode/projects/mnt/sla_tsgo

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_project_background_update_contract.sla --test-backend sab

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_project_background_warm_contract.sla --test-backend sab

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_project_background_wait_contract.sla --test-backend sab

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_project_collection_default_cache_contract.sla --test-backend sab

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_project_collection_open_contract.sla --test-backend sab

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_project_config_registry_contract.sla --test-backend sab

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_project_snapshot_config_registry_contract.sla --test-backend sab

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_project_api_open_contract.sla --test-backend sab

timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_project_api_update_contract.sla --test-backend sab
```

这些命令均表现为 10 秒内没有 stdout/stderr，`timeout` 返回 124。`test_project_collection_default_cache_contract.sla` 已在 SLA 编译器 ReleaseFast rebuild 后额外串行复核，仍然 10 秒无输出超时。`test_project_api_open_contract.sla` 和 `test_project_api_update_contract.sla` 于 2026-07-07 追加复核，仍是 strict SAB 10 秒无输出超时。

## 对照命令

```sh
timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_core_contract.sla --test-backend sab
```

该命令通过：5 passed。

## 静态检查

以下命令均通过：

```sh
timeout 10s env SA_PLUGIN_DEV=1 sa sla check members/project/src/snapshot.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_project_background_update_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_project_background_warm_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_project_background_wait_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_project_collection_default_cache_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_project_collection_open_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_project_config_registry_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_project_snapshot_config_registry_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_project_api_open_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_project_api_update_contract.sla
```

## 最小化状态

测试已经从大的 `tests/test_project_contract.sla` 拆成单测试文件，每个文件只包含一个 `@test`。background 单测使用 synthetic `SessionState` / `project_empty_program()` 构造 project snapshot，避免 parser/program 文本扫描路径干扰；project collection 单测只覆盖 `ProjectCollection.fileDefaultProjects` / open configured project 小路径；config registry 单测只覆盖 fixed-capacity `ConfigFileRegistry` lookup、ancestor 和 snapshot/collection registry retention；API 单测只覆盖 `APIOpenProject`/`APIUpdateWithFileChanges` 的固定容量 `apiOpenedProjects` 状态和 pending flush/scheduled update cancellation。

## 2026-07-07 Module Table 复核

`sa_plugin_sla/src/plugin.zig` 已加入第一阶段 `SlaModuleTable`：同一次 import expansion 内按 resolved path 缓存已解析 `.sla` AST，并用 emitted set 防止重复 append。同一轮复核确认该 stopgap 没有解决本工单的大型 unique import graph：

```sh
cd /home/vscode/projects/mnt/sla_tsgo
/usr/bin/time -f 'elapsed %e maxrss %M' timeout 10s env SLA_PROFILE=1 SLA_SAB_NO_FALLBACK=1 \
  /home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli \
  sla sab build tests/test_project_background_update_contract.sla \
  --out /tmp/project_background_update.sab
```

结果：`timeout` 退出码 124。已输出 profile：

- `parse`: 2313ms
- `import expand`: 5679ms
- `monomorphize`: 28ms
- `load contracts`: 861ms

判断：当前瓶颈仍在 SLA 前端导入展开/全量 flatten 后续流程。Module Table 防重复解析只能处理重复 import，对 project snapshot 这类大量唯一模块的图不够；后续需要 shallow exported-symbol index、namespace isolation 和 lazy typecheck，避免把所有 imported function body 拼进当前 program 后一起 typecheck。

## 2026-07-07 test-codegen 可达裁剪复核

`sa_plugin_sla/src/plugin.zig` 已在 test-input 生成路径启用 `pre-typecheck reachable decl filter`，并在 typecheck 后、direct-SAB codegen 前启用精确 `reachable decl filter`。两者都会裁掉未被当前 `@test` 可达的顶层函数和 inherent impl/overload 方法，但保留 trait impl 整组以避免 vtable 破洞。复核命令使用真实 `sla test` 路径：

```sh
cd /home/vscode/projects/mnt/sla_tsgo
/usr/bin/time -f 'elapsed %e maxrss %M' timeout 10s env SLA_PROFILE=1 SLA_SAB_NO_FALLBACK=1 \
  /home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli \
  sla test tests/test_project_background_update_contract.sla --test-backend sab --trace-panic
```

结果：仍为 `timeout` 退出码 124，`elapsed 10.05 maxrss 339712`。已输出 profile：

- `parse`: 2280ms
- `import expand`: 5495ms
- `monomorphize`: 33ms
- `pre-typecheck reachable decl filter`: 26ms
- `load contracts`: 678ms
- `type check`: 551ms
- `primary decl filter`: 0ms
- `reachable decl filter`: 1ms

判断：test-path 可达裁剪已把 typecheck 压到约 0.5s，post-typecheck output filter 本身约 1ms，但本工单仍未修复。当前最大前端成本仍是 import expand 约 5.5s，且 timeout 发生在 reachable decl filter 之后、direct-SAB codegen/test 执行完成前。下一步需要 ModuleGraph/shallow symbol index，避免把大量唯一 imported AST 先拼接展开；同时 direct-SAB codegen 需要按可达 test 子图加载 std/helper 依赖。

## 2026-07-07 import-expansion 可达体裁剪复核

`sa_plugin_sla/src/plugin.zig` 的 test-codegen 路径现在会在 import expansion 前先收集 `.sla` Module Table/ModuleGraph，按当前选中 `@test` 的语法调用闭包只扁平化可达的 imported top-level function 和 inherent impl/overload 方法。类型、trait、const、macro 和 trait impl 仍保留，避免破坏 typecheck/vtable 安全。复核仍使用真实 `sla test` 路径和 10 秒硬超时：

```sh
cd /home/vscode/projects/mnt/sla_tsgo
/usr/bin/time -f 'elapsed %e maxrss %M' timeout 10s env SLA_PROFILE=1 SLA_SAB_NO_FALLBACK=1 \
  /home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli \
  sla test tests/test_project_background_update_contract.sla --test-backend sab --trace-panic
```

结果：仍为 `timeout` 退出码 124，`elapsed 10.04 maxrss 364416`。已输出 profile：

- `parse`: 1966ms
- `import expand`: 4834ms
- `monomorphize`: 4ms
- `pre-typecheck reachable decl filter`: 3ms
- `load contracts`: 696ms
- `type check`: 330ms
- `primary decl filter`: 0ms
- `reachable decl filter`: 1ms

判断：import-expansion 可达体裁剪使 typecheck 继续下降到约 0.33s，import expand 从上一轮约 5.5s 降到约 4.8s，但本工单仍未关闭。当前剩余瓶颈仍包括 parser/import graph 预扫描、唯一模块解析和 reachable filter 之后的 direct-SAB codegen/依赖加载；下一步需要真正的 shallow signature index、命名空间隔离和 lazy codegen dependency loading，而不是继续把大量 imported body 拼入当前 program。

## 期望

SAB 应在 10 秒窗口内完成这些单测试的编译和执行；如果有所有权或运行期错误，应输出具体 trap，而不是无输出挂到外层 timeout。
