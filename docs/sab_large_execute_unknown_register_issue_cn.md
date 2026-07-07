# SAB large execute contract UnknownRegister issue

日期：2026-07-06

状态：原 UnknownRegister blocker 已修复并复验。当前下游 default/SAB execute 聚合套件可以生成并运行，不再在 SAB verifier 阶段因 `tmp_*` callee register 未声明而中断；`test_execute_contract.sla` 仍有历史 parse_arg / dispatch 业务断言失败，需作为下游语义问题单独处理。

## 当前复验结论

`sa_plugin_sla` 当前修复覆盖了大型 execute/cli 导入图中暴露的两类编译器问题：

- SA-text 清理状态：imported macro value materialization、重赋值 consumed 状态恢复、循环体词法 cleanup 一致性。
- direct SAB Copy 参数：by-value primitive Copy 参数在入口物化 stack slot，避免 consuming SAB op 重复消耗同一个参数寄存器。

下游 `/home/vscode/projects/mnt/sla_tsgo` 当前复验：

```sh
SA_PLUGIN_DEV=1 sa sla check members/execute/src/cli.sla
SA_PLUGIN_DEV=1 sa sla test tests/test_cli_contract.sla --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test tests/test_execute_extra_contract.sla --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test tests/test_cli_contract.sla --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test tests/test_execute_extra_contract.sla --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test tests/test_execute_contract.sla --jobs 1 --trace-panic
```

结果：

- `members/execute/src/cli.sla` check 通过。
- `test_cli_contract.sla` SA/default 均为 8/8 passed。
- `test_execute_extra_contract.sla` SA/default 均为 23/23 passed。
- `test_execute_contract.sla` default/SAB 不再触发 verifier trap；当前结果为 33 passed / 16 failed，失败集中在历史 parse_arg / dispatch runtime/business assertions。

本 repo 回归覆盖：

- `tests/test_unit_tsconfig_buffer_cleanup.sla`
- `tests/test_unit_reassign_after_release.sla`
- `tests/test_unit_loop_body_local_cleanup.sla`
- `tests/test_unit_sab_binary_copy_param_direct.sla`

本地验证：`zig build --summary all`、`zig build test --summary all`、`sa plugin install --dev .`、`SA_PLUGIN_DEV=1 sa sla help` 均通过。

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

## 历史失败的 SAB/default 验证

```sh
cd /home/vscode/projects/mnt/sla_tsgo

SA_PLUGIN_DEV=1 sa sla test tests/test_execute_contract.sla
SA_PLUGIN_DEV=1 sa sla test tests/test_execute_extra_contract.sla
SA_PLUGIN_DEV=1 sa sla test tests/test_cli_contract.sla
```

历史上 `test_execute_contract.sla` 与 `test_execute_extra_contract.sla` 均失败：

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

当前 `test_cli_contract.sla` 与 `test_execute_extra_contract.sla` 已不再需要 SA fallback 才能绕过 SAB verifier；SA/default 均已通过。以下为历史观察，保留用于说明当时的规避方式。

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

## 修复后判断

原 `UnknownRegister` 不再是当前 blocker。修复后看，至少当前 execute/cli 大型导入图暴露的问题并不是业务源码类型错误，而是编译器清理/寄存器状态在 SA-text 与 direct SAB 两条尾端上的不一致：SA-text 在宏参数释放、重赋值、循环词法 cleanup 上会污染 verifier 状态；direct SAB 在 Copy scalar param 复用上会把参数寄存器当成可重复消费值。

失败点只暴露低层 SAB register 名称和 generated SAB line、缺少 SLA source location 这一诊断弱点仍然存在，后续 verifier trap 仍建议补充 upstream location 或至少函数名。

需要注意：这和旧的 call target 字符串拼接问题不同；当前错误不是 `@func(arg)` 形态，而是 verifier 报某个 `tmp_*` callee register 未声明。

## 下游处理状态

`sla_tsgo` 侧可以恢复使用 focused coverage 作为正常 gate：

- `test_cli_contract.sla`：SA/default 8/8 passed；
- `test_execute_extra_contract.sla`：SA/default 23/23 passed；
- `test_execute_contract.sla`：default/SAB 可运行，但当前 33/49 通过，剩余失败是历史 runtime/business assertion，不是 SAB verifier blocker。

## 后续建议项

1. [x] 在 `sa_plugin_sla` 侧构造 focused repro：tsconfig buffer cleanup、重赋值 release 恢复、循环体局部 cleanup、direct SAB Copy scalar param。
2. [x] 用 `sla_tsgo` 三个下游命令作为回归 guard：`test_cli_contract.sla`、`test_execute_extra_contract.sla`、`test_execute_contract.sla`。前两个 SA/default 全绿；第三个不再 verifier trap，仅保留历史业务断言失败。
3. [ ] 为未来 SAB verifier trap 补充 upstream SLA source location 或至少函数名，避免只报告 `.sab` line 和 `tmp_*` register。
4. [ ] 下游单独清理 `test_execute_contract.sla` 中历史 parse_arg / dispatch runtime assertions。
