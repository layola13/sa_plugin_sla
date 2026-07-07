# execute_extra 编译阶段 parse_tsconfig_from_path UseAfterMove

状态：已修复并复验。该工单暴露的是 SA-text 清理状态和 direct SAB 参数物化的组合问题；`sla_tsgo` 仅作为下游回归证据，修复位于 `sa_plugin_sla` 编译器侧。

## 当前修复结论

`parse_tsconfig_from_path` 的 `data` 双重释放、后续 `scanner_next_token` 的 `pos` 重定义，以及循环体局部清理在非 fallthrough 分支污染后不一致的问题，均已在当前编译器实现中修复。direct SAB 路径另有一个同批暴露的问题：Copy 标量参数在 SAB consuming op 中重复使用时需要入口 stack slot 物化；该问题也已修复。

本 issue 当前复验结果：

```sh
zig build --summary all
zig build test --summary all
sa plugin install --dev .
SA_PLUGIN_DEV=1 sa sla help

SA_PLUGIN_DEV=1 sa sla test tests/test_unit_tsconfig_buffer_cleanup.sla --test-backend sa --jobs 1 --trace-panic
SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_unit_tsconfig_buffer_cleanup.sla --test-backend sab --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_reassign_after_release.sla --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_loop_body_local_cleanup.sla --test-backend sa --jobs 1 --trace-panic
SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_unit_loop_body_local_cleanup.sla --test-backend sab --jobs 1 --trace-panic
SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_unit_sab_binary_copy_param_direct.sla --test-backend sab --jobs 1 --trace-panic
```

下游 `/home/vscode/projects/mnt/sla_tsgo` 复验：

```sh
SA_PLUGIN_DEV=1 sa sla check members/execute/src/cli.sla
SA_PLUGIN_DEV=1 sa sla test tests/test_cli_contract.sla --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test tests/test_execute_extra_contract.sla --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test tests/test_cli_contract.sla --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test tests/test_execute_extra_contract.sla --jobs 1 --trace-panic
```

结果：`cli_contract` SA/default 均为 8/8 passed；`execute_extra_contract` SA/default 均为 23/23 passed；`members/execute/src/cli.sla` check 通过。

## 根因

1. SA-text imported macro value materialization 后没有把实际释放记录到 `consumed_bindings`，`JSON_PARSE(data, data_len)` 消费 `data` 后，函数返回清理阶段又生成 `!data`。
2. 标识符重新赋值后，旧的 consumed 状态没有恢复，`scanner_next_token` 中类似 `pos = ...` 的路径会被 verifier 视为 live register 重定义。
3. 循环体局部清理依赖当前线性 codegen 状态；遇到 break/continue/非 fallthrough 分支污染后，普通 lexical local cleanup 需要基于词法绑定发出 release，而不是只相信线性 consumed 状态。
4. direct SAB 对 by-value primitive Copy 参数直接复用参数寄存器；SAB consuming op 会消耗寄存器，导致同一 Copy 参数后续再次使用时出现 move-state 问题。当前实现会把这类参数在函数入口物化到 stack slot，并在使用处 load。

## 现象

`sla_tsgo` 的 `tests/test_execute_extra_contract.sla` 在 `--test-backend sa` 下会先编译整份测试文件和导入图，即使使用 `--filter` 只选择 LSP dispatch 测试，也会在 `parse_tsconfig_from_path` 的清理阶段触发 `UseAfterMove`：

```sh
SA_PLUGIN_DEV=1 sa sla test tests/test_execute_extra_contract.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla test tests/test_execute_extra_contract.sla --test-backend sa --filter "dispatch lsp folding range"
```

失败点示例：

```text
error[UseAfterMove]: moved value is no longer usable
  in function @sla__parse_tsconfig_from_path(path: ptr, path_len: i64) -> ptr:
  line 21200 (expanded 3756):     !data
  register: data
  state: expected Consumed, actual Consumed
```

## 影响

当前影响已解除：`test_execute_extra_contract.sla` 可以重新作为 SA backend 和 default/SAB backend dispatch gate 使用。历史上该 failure 发生在整文件导入图编译/清理阶段，不是 LSP folding range dispatch 分支本身。

以下为历史判断，保留用于说明原始 failure 边界：

- 该 failure 发生在整文件导入图编译/清理阶段，不是当前 LSP folding range dispatch 分支本身。
- `members/execute/src/cli.sla` 的 `sa sla check` 通过，可作为当前 execute dispatch source-level 证据。
- 由于 `--filter` 仍会编译整份文件，`test_execute_extra_contract.sla` 暂时不能作为 SA backend dispatch gate。

## 相关文件

- `/home/vscode/projects/mnt/sla_tsgo/tests/test_execute_extra_contract.sla`
- `/home/vscode/projects/mnt/sla_tsgo/members/syntax/src/tsconfig.sla`
- `/home/vscode/projects/mnt/sla_tsgo/members/execute/src/cli.sla`
