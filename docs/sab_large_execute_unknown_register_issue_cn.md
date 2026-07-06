# SAB large execute contract UnknownRegister issue

日期：2026-07-06

状态：未修复 / 下游已记录为编译器侧工单

## 背景

在 `/home/vscode/projects/mnt/sla_tsgo` 继续移植 TypeScript Go 的 language-service dispatch 时，新增了 call hierarchy 的协议常量、LS facade 和 focused contract tests。新增的 `callhierarchy` 与 `ls` focused tests 可以通过，`members/execute/src/cli.sla` 自身也可以通过 `sa sla check`，但任何包含 execute/cli 大型导入图的 test SAB 生成/执行阶段会触发 SA verifier 的 `UnknownRegister`。

这不是 `sla_tsgo` 业务逻辑类型错误：同一个 execute 源文件类型检查通过；不含 execute 大型导入图的 protocol/callhierarchy/ls tests 均通过。

## 复现仓库

```text
/home/vscode/projects/mnt/sla_tsgo
```

相关文件：

- `members/execute/src/cli.sla`
- `tests/test_execute_contract.sla`
- `tests/test_execute_extra_contract.sla`
- `tests/test_cli_contract.sla`

## 通过的对照验证

```sh
cd /home/vscode/projects/mnt/sla_tsgo

SA_PLUGIN_DEV=1 sa sla check members/execute/src/cli.sla
SA_PLUGIN_DEV=1 sa sla test tests/test_callhierarchy_contract.sla
SA_PLUGIN_DEV=1 sa sla test tests/test_ls_contract.sla
SA_PLUGIN_DEV=1 sa sla test tests/test_protocol_contract.sla
SA_PLUGIN_DEV=1 sa sla test tests/test_cli_contract.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla test tests/test_execute_extra_contract.sla --test-backend sa
```

观察结果：

- `members/execute/src/cli.sla` 语法和类型检查成功；
- `test_callhierarchy_contract.sla`：7 passed；
- `test_ls_contract.sla`：25 passed；
- `test_protocol_contract.sla`：27 passed。
- SA text fallback focused gates pass：`test_cli_contract.sla` 8 passed，`test_execute_extra_contract.sla` 3 passed。

## 失败的 SAB/default 验证

```sh
cd /home/vscode/projects/mnt/sla_tsgo

SA_PLUGIN_DEV=1 sa sla test tests/test_execute_contract.sla
SA_PLUGIN_DEV=1 sa sla test tests/test_execute_extra_contract.sla
SA_PLUGIN_DEV=1 sa sla test tests/test_cli_contract.sla
```

`test_execute_contract.sla` 与 `test_execute_extra_contract.sla` 均失败：

```text
error[UnknownRegister]: callee is not declared
  register: tmp_273
{"trap":"UnknownRegister","trap_code":1007,"file":".sla-cache/sab/test_execute_contract-e15ad59db051020b.sab","line":824,"source_line":0,"source_text":null,"original_text":null,"bad_token":null,"register":"tmp_273","message":"callee is not declared"}
```

`test_cli_contract.sla` 同类失败：

```text
error[UnknownRegister]: callee is not declared
  register: tmp_306
{"trap":"UnknownRegister","trap_code":1007,"file":".sla-cache/sab/test_cli_contract-fc3ba74025c3053.sab","line":927,"source_line":0,"source_text":null,"original_text":null,"bad_token":null,"register":"tmp_306","message":"callee is not declared"}
```

## SA fallback 观察

SAB 仍在开发中，下游可以临时使用 `--test-backend sa` 作为 focused gate。当前观察：

```sh
SA_PLUGIN_DEV=1 sa sla test tests/test_cli_contract.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla test tests/test_execute_extra_contract.sla --test-backend sa
```

结果分别为 8/8 passed 和 3/3 passed。

但大聚合套件并不能简单作为 SA fallback gate：

```sh
SA_PLUGIN_DEV=1 sa sla test tests/test_execute_contract.sla --test-backend sa
```

当前结果为 33 passed / 16 failed，失败集中在历史 parse_arg / execute_dispatch assertions，而不是本轮 call hierarchy 功能本身。因此建议下游短期使用 focused SA fallback suites，加上 `sa sla check members/execute/src/cli.sla`，而不是依赖该聚合套件。

## 初步判断

疑似 SAB test path 在大型 import graph / dispatch-heavy test 文件中，对某些 call callee 临时寄存器的声明、metadata 或 materialization 顺序存在丢失。失败点只暴露低层 SAB register 名称和 generated SAB line，没有 SLA source location，且 `sa sla check` 无法复现。

需要注意：这和旧的 call target 字符串拼接问题不同；当前错误不是 `@func(arg)` 形态，而是 verifier 报某个 `tmp_*` callee register 未声明。

## 下游临时处理

`sla_tsgo` 侧继续保留 focused coverage：

- call hierarchy helper 和 LS facade 用 focused tests 验证；
- protocol surface 用 `test_protocol_contract.sla` 验证；
- execute/cli 大型 dispatch tests 暂时记录为 SAB backend blocker，不作为本轮功能完成的唯一 gate。

## 建议修复项

1. [ ] 在 `sa_plugin_sla` 侧构造更小 repro：包含 `members/execute/src/cli.sla` 这类大量 imports、多个 dispatch 分支和若干 protocol constants，但去掉业务无关代码。
2. [ ] 为 SAB verifier trap 补充 upstream SLA source location 或至少函数名，避免只报告 `.sab` line 和 `tmp_*` register。
3. [ ] 检查 test SAB generation 对大型导入图中 call callee register metadata 的收集是否完整。
4. [ ] 修复后用 `sla_tsgo` 三个下游命令作为回归 guard：`test_execute_contract.sla`、`test_execute_extra_contract.sla`、`test_cli_contract.sla`。
