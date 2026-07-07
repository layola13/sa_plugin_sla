# sla_ts main direct SAB 10s timeout

## 状态

待排查。该问题来自 `/home/vscode/projects/sa_plugins/sla_ts` 当前重构分支的验证限制。

## 复现命令

```sh
cd /home/vscode/projects/sa_plugins/sla_ts
timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  /home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli \
  sla test src/main.sla --test-backend sab --jobs 1 --trace-panic \
  --filter 'default main path runs compile mode'
```

当前结果：

```text
exit=124
```

## 对照

更小的 `sla_ts` compiler emit 单元可以在同样 10s 约束内单独通过：

```sh
timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  /home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli \
  sla test tests/compiler_emit.sla --test-backend sab --jobs 1 --trace-panic \
  --filter 'compiles typed variable declaration to javascript'
```

结果：

```text
[PASS] compiles typed variable declaration to javascript
test result: ok. 1 passed; 0 failed; 0 skipped
```

`src/tsgo/compiler.sla` 本身已经不包含 `@test`，但 `src/main.sla` 的导入链在 direct SAB/no-fallback 下仍超过 10s。

## 期望

`--filter` 指定单个测试时，direct SAB/no-fallback 编译和执行应能在小项目导入链上稳定低于 10s，或至少提供阶段性 profile/诊断，便于确认是 import expansion、type check、SAB lowering、link/test runner 哪个阶段耗时。
