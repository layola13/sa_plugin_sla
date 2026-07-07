# SAB 编译 `sla_tsgo` 简单 TS->JS 编译出口测试超时

## 状态

- 日期：2026-07-07
- 触发仓库：`/home/vscode/projects/mnt/sla_tsgo`
- 测试文件：`tests/test_compile_emit_text_contract.sla`
- 后端：`sab`
- 约束：`SLA_SAB_NO_FALLBACK=1`

## 复现命令

```sh
cd /home/vscode/projects/mnt/sla_tsgo
timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_compile_emit_text_contract.sla --test-backend sab
```

## 实际结果

命令在 10 秒超时退出，无 stdout/stderr 诊断：

```text
exit code: 124
```

## 期望结果

该小测试只验证一个简单编译出口：

```ts
let x: number = 42;
```

期望输出 JS 文本：

```js
let x = 42;
```

测试应在 10 秒内完成。

## 已收窄信息

同一文本擦除逻辑的 emitter-only 小测试可以通过 strict SAB：

```sh
timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_emitter_js_text_contract.sla --test-backend sab
```

通过结果：

```text
[PASS] emit js text erases simple type annotation
----
test result: ok. 1 passed; 0 failed; 0 skipped
```

因此当前超时更可能与导入 `members/compiler/src/compiler.sla` 后的 SAB 编译/运行体积或结构返回路径有关，而不是 `emit_js_text` 的简单循环逻辑本身。

## 相关 check

以下静态检查均通过：

```sh
timeout 10s env SA_PLUGIN_DEV=1 sa sla check members/emitter/src/emitter.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check members/compiler/src/compiler.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_compile_emit_text_contract.sla
```
