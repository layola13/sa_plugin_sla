# SAB 编译 `sla_tsgo` Program TS->JS 编译出口测试触发 UseAfterMove

## 状态

- 日期：2026-07-07
- 触发仓库：`/home/vscode/projects/mnt/sla_tsgo`
- 测试文件：
  - `tests/test_compile_ts_to_js_text_contract.sla`
  - `tests/test_program_emit_text_contract.sla`
- 后端：`sab`
- 约束：`SLA_SAB_NO_FALLBACK=1`

## 复现命令

```sh
cd /home/vscode/projects/mnt/sla_tsgo
timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_compile_ts_to_js_text_contract.sla --test-backend sab
timeout 10s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_program_emit_text_contract.sla --test-backend sab
```

## 实际结果

拆分测试后不再表现为超时，而是两个 Program/compile 入口均稳定触发同类 SAB 运行期错误，且没有源码位置：

```text
error[UseAfterMove]: moved value is no longer usable
  register: ti
  state: expected Consumed, actual Consumed
{"trap":"UseAfterMove","trap_code":1009,"file":".sla-cache/sab/test_compile_ts_to_js_text_contract-1b5ee966f18fe67b.sab","line":34164,"source_line":0,...}
{"trap":"UseAfterMove","trap_code":1009,"file":".sla-cache/sab/test_program_emit_text_contract-94ffbcbd213f6641.sab","line":34164,"source_line":0,...}
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

因此当前问题不是 `emit_js_text` 的简单循环逻辑。问题在 Program 级路径：

1. `program_new_single_file` 将源码 ptr/len 保留到 `ProgramSourceFile.text/text_len`。
2. `program_emit_to_text` 从 `Program.primary_source_file` 取源码文本并调用 `emit_source_text`。
3. strict SAB 在这条 Program 路径上触发 `UseAfterMove`，但 `sa sla check` 通过且错误没有源码位置。

已经规避过的源码侧模式：

- 不再从同一个 `ProgramSourceFile` 同时读取 file-name ptr 和 source-text ptr。
- Program emit 返回结构不再携带 file-name ptr。
- 返回结构中先读取 text_len，再读取 text ptr。

这些改动后 strict SAB 仍在相同内部位置报 `UseAfterMove`。

## 相关 check

以下静态检查均通过：

```sh
timeout 10s env SA_PLUGIN_DEV=1 sa sla check members/emitter/src/emitter.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check members/compiler/src/compiler.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_compile_ts_to_js_text_contract.sla
timeout 10s env SA_PLUGIN_DEV=1 sa sla check tests/test_program_emit_text_contract.sla
```
