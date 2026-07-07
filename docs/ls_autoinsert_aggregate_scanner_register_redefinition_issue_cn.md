# LS autoinsert 聚合测试触发 scanner RegisterRedefinition

状态：已修复并由下游复验。编译器侧同根 `scanner_next_token` 重赋值问题已修复，`sla_tsgo` 已恢复原 LS 聚合断言并通过 SA 后端。

## 当前修复结论

本问题的核心报错是 `scanner_next_token` 内局部变量重新赋值后，SA-text codegen 的线性 consumed 状态没有恢复到可重新定义状态，导致 verifier 报：

```text
error[RegisterRedefinition]: register is already live
  in function @sla__scanner_next_token(state: ptr) -> ptr:
  ...:     pos = tmp_...
  register: pos
```

当前 `src/codegen.zig` 在标识符 reassignment 写入新值后，会移除目标 binding 的 consumed 标记；同批还修复了循环体 lexical cleanup 在 break/continue/非 fallthrough 分支后的 release 一致性，避免 scanner/parser 大型导入图中继续污染清理状态。

已复验的直接证据：

```sh
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_reassign_after_release.sla --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_loop_body_local_cleanup.sla --test-backend sa --jobs 1 --trace-panic
SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_unit_loop_body_local_cleanup.sla --test-backend sab --jobs 1 --trace-panic
zig build --summary all
zig build test --summary all
sa plugin install --dev .
SA_PLUGIN_DEV=1 sa sla help
```

下游 `/home/vscode/projects/mnt/sla_tsgo` 中包含 scanner/parser 大型导入图的 execute gates 也已通过：`test_cli_contract.sla` SA/default 8/8，`test_execute_extra_contract.sla` SA/default 23/23。

下游最终回归 gate 已恢复并通过：

```sh
cd /home/vscode/projects/mnt/sla_tsgo
SA_PLUGIN_DEV=1 sa sla check members/ls/src/ls.sla
SA_PLUGIN_DEV=1 sa sla test tests/test_ls_contract.sla --test-backend sa
```

结果：`members/ls/src/ls.sla` check 通过；`test_ls_contract.sla` 62/62 passed。恢复的聚合断言覆盖 `ls_on_auto_insert(...)` 的普通 JSX closing tag 与 fragment closing kind，以及 edit/range/snippet/trigger 计数。

## 现象

在 `/home/vscode/projects/mnt/sla_tsgo` 增加 LSP `VSOnAutoInsert` summary 后，如果把 `ls_on_auto_insert(...)` 的断言直接加入大型 `tests/test_ls_contract.sla --test-backend sa` 聚合测试，SA 后端编译阶段会在 scanner 生成代码处触发：

```text
error[RegisterRedefinition]: register is already live
  in function @sla__scanner_next_token(state: ptr) -> ptr:
  line ... (expanded 5516):     pos = tmp_1393
  register: pos
```

同一源码下：

- `SA_PLUGIN_DEV=1 sa sla check members/autoinsert/src/autoinsert.sla` 通过；
- `SA_PLUGIN_DEV=1 sa sla check members/ls/src/ls.sla` 通过；
- `SA_PLUGIN_DEV=1 sa sla check members/execute/src/cli.sla` 通过；
- `SA_PLUGIN_DEV=1 sa sla test tests/test_autoinsert_contract.sla --test-backend sa` 通过；
- 移除新增的 LS 聚合断言后，`tests/test_ls_contract.sla --test-backend sa` 恢复通过。

## 复现窗口

问题与大型 LS 聚合测试导入图/生成规模相关，而非 `autoinsert` summary 本身类型错误。早期 direct autoinsert 测试若让 `members/autoinsert` 直接导入 parser，也会触发同一 `scanner_next_token` `RegisterRedefinition`；将 autoinsert 改为 parser-free summary 输入后 direct 测试通过。

## 下游规避

历史上 `sla_tsgo` 保持：

- autoinsert direct contract 覆盖 summary 形状；
- `members/ls/src/ls.sla` source check 覆盖 facade 接线；
- `members/execute/src/cli.sla` source check 覆盖 dispatch；
- 不把新增 autoinsert LS facade 断言放入大型 LS 聚合测试。

## 建议修复项

1. [x] 检查 SA 后端在大型导入图中对 `scanner_next_token` 局部变量/临时寄存器 `pos` 的 liveness 释放。
2. [x] 对重复赋值路径恢复目标 binding 的 consumed 状态；对循环扫描路径补充词法 cleanup release。
3. [x] 修复后用 `sla_tsgo` 恢复的 LS autoinsert 聚合断言作为最终下游回归。
