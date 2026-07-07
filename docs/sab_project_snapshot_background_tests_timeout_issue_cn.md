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

## 期望

SAB 应在 10 秒窗口内完成这些单测试的编译和执行；如果有所有权或运行期错误，应输出具体 trap，而不是无输出挂到外层 timeout。
