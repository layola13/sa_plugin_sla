# SAB compiler checker-pool 单测 10 秒无输出超时

日期：2026-07-07

## 现象

`sla_tsgo` 新增的 compiler checker-pool 拆分单测在 strict SAB 模式下 10 秒无输出超时，退出码 124。相同环境下 `test_core_contract.sla` 可以通过，说明 SAB 后端基础执行可用，问题集中在导入 `members/compiler/src/compiler.sla` 并调用 retained `ProgramCheckerPoolState` / API checker lifecycle 路径的小单元。

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
```

这些命令均表现为 10 秒内没有 stdout/stderr，`timeout` 返回 124。

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
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_compiler_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check members/project/src/snapshot.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check members/ls/src/ls.sla
```

## 最小化状态

测试已经拆成三个单测试文件，每个文件只包含一个 `@test`：

- API checker release 后保持 stable identity。
- checker pool discard 后保留 API checker。
- canceled API checker release 后清除 persistent checker，并在下次 acquire 创建新 identity。

## 期望

SAB 应在 10 秒窗口内完成这些单测试的编译和执行；如果有所有权或运行期错误，应输出具体 trap，而不是无输出挂到外层 timeout。
