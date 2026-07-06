# SAB empty filter still encodes and reports MemoryLeak

日期：2026-07-06

状态：已修复。SLA test runner 在明确 `--filter` 不匹配任何 `@test` 时会直接返回空测试结果，避免进入 SA/SAB 测试输入生成、SAB 编码和 verifier 路径。

## 背景

在复测 `result_entityitem_filter_cleanup_issue_cn.md` 的历史 filter 时，当前 host 文件中已经没有匹配的测试。
SA backend 对同一 filter 正确返回 `0 passed`，但 SAB backend 仍然会生成/编码 SAB artifact，并在 verifier
阶段报告 `MemoryLeak`。

这不是 `sla_ecs` 业务逻辑失败：同一文件的完整 strict SAB no-fallback gate 已通过，且选中真实测试的 SAB
focused filter 也通过。问题集中在 `--filter` 没有选中任何测试时的 SAB 编码/清理路径。

## 复现仓库

`/home/vscode/projects/sla_ecs`

## 复现命令

历史 stale filter：

```sh
timeout 120s env SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test \
  tests/test_ecs_result_facades.sla \
  --filter "ecs_world_try_query_single returns one" \
  --test-backend sab
```

任意不存在的 filter 也可复现：

```sh
timeout 120s env SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test \
  tests/test_ecs_result_facades.sla \
  --filter "definitely no such ecs test" \
  --test-backend sab
```

## 当前观察

SAB 路径失败：

```text
error[MemoryLeak]: live registers remain at function exit
  register: index
  state: Active
{"trap":"MemoryLeak","trap_code":1012,"file":".sla-cache/sab/test_ecs_result_facades-a2cb1aed1889356.sab","line":1639,"source_line":0,"column":null,"source_text":null,"original_text":null,"bad_token":null,"context":[],"register":"index","registers":[],"expected_mask":null,"actual_mask":1,"expected_mask_name":null,"actual_mask_name":"Active","upstream_loc":null,"function":null,"is_ffi_wrapper":false,"message":"live registers remain at function exit","hint":null}
```

SA backend 对照通过且选中 0 个测试：

```sh
timeout 120s env SA_PLUGIN_DEV=1 sa sla test \
  tests/test_ecs_result_facades.sla \
  --filter "definitely no such ecs test" \
  --test-backend sa
```

```text
----
test result: ok. 0 passed; 0 failed; 0 skipped
```

## 已通过的对照验证

完整 host 文件 strict SAB no-fallback 通过：

```sh
timeout 120s env SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test \
  tests/test_ecs_result_facades.sla \
  --test-backend sab
```

结果：`172 passed; 0 failed; 0 skipped`。

选中真实测试的 SAB focused filter 通过：

```sh
timeout 120s env SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test \
  tests/test_ecs_result_facades.sla \
  --filter "ecs_world_try_get returns ok for present component" \
  --test-backend sab
```

结果：`1 passed; 0 failed; 0 skipped`。

## 期望

当 `--filter` 没有选中任何测试时，SAB backend 应与 SA backend 行为一致：直接返回
`0 passed; 0 failed; 0 skipped`，或至少不应为未选中的测试/辅助函数生成会触发 verifier trap 的 SAB artifact。

## 修复记录

修复位置：`src/plugin.zig`。

当前 `sa sla test` 会在解析测试文件、展开 SLA imports 后先用同一套 `@test` filter 匹配规则判断显式非空 `--filter` 是否命中任何测试。如果没有命中，runner 直接写出：

```text
----
test result: ok. 0 passed; 0 failed; 0 skipped
```

并返回成功，不再生成 managed `.sab` 测试 artifact。解析、宏展开或 import 展开失败时不会吞掉真实错误，而是回到原有测试编译路径。

新增 Zig 回归：`sla test empty filter skips sab compilation`，覆盖 SAB backend 下未命中 filter 时跳过 SAB 编译，且不会生成 managed SAB 路径。

## 修复后验证

本仓库验证：

```sh
zig build test -Dtest-filter="empty filter skips sab" --summary all
zig build --summary all
zig build test --summary all
timeout 120s sa plugin install --dev .
timeout 30s env SA_PLUGIN_DEV=1 sa sla help
```

结果：focused Zig test 1/1；full Zig tests 92/92；官方 dev plugin install/help 通过。

下游只作为 host regression evidence，不修改 `sla_ecs`：

```sh
cd /home/vscode/projects/sla_ecs

timeout 120s env SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test \
  tests/test_ecs_result_facades.sla \
  --filter "definitely no such ecs test" \
  --test-backend sab

timeout 120s env SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test \
  tests/test_ecs_result_facades.sla \
  --filter "ecs_world_try_query_single returns one" \
  --test-backend sab

timeout 120s env SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test \
  tests/test_ecs_result_facades.sla \
  --filter "ecs_world_try_get returns ok for present component" \
  --test-backend sab
```

结果：两个空 filter 均返回 `0 passed; 0 failed; 0 skipped`；真实匹配的 SAB focused filter 仍通过 `1 passed; 0 failed; 0 skipped`。
