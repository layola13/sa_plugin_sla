# HTTP loopback adapter test backend regressions

## 背景

在 `/home/vscode/projects/sla_codex` 中实现 SLA-native Codex 的
Responses HTTP/SSE loopback 与 `sa_plugin_db` observed persistence 时，
`crates/scodex-runtime/src/http_loopback_sse_adapter.sla` 可以通过：

```bash
timeout 60s env SA_PLUGIN_DEV=1 sa sla check crates/scodex-runtime/src/http_loopback_sse_adapter.sla
timeout 120s env SA_PLUGIN_DEV=1 sa sla build crates/scodex-runtime/src/http_loopback_sse_adapter.sla --out /tmp/scodex-http-observed.sa
timeout 120s env SA_PLUGIN_DEV=1 sa sla sab build crates/scodex-runtime/src/http_loopback_sse_adapter.sla --out /tmp/scodex-http-observed.sab
```

但执行测试后端失败。

## 复现

工作目录：

```text
/home/vscode/projects/sla_codex
```

SA test backend：

```bash
timeout 240s env SA_PLUGIN_DEV=1 sa sla test crates/scodex-runtime/src/http_loopback_sse_adapter.sla --test-backend sa
```

实际输出：

```text
llvmc backend: Function return type does not match operand type of return inst!
  ret { i32, i32 } zeroinitializer
 i64
error: Failed
```

SAB test backend：

```bash
timeout 240s env SA_PLUGIN_DEV=1 sa sla test crates/scodex-runtime/src/http_loopback_sse_adapter.sla --test-backend sab
```

实际输出：

```text
error[StackEscape]: stack allocation cannot be moved out of its function
  register: tmp_1529
  state: expected Active, actual Active
{"trap":"StackEscape","trap_code":1025,"file":".sla-cache/sab/http_loopback_sse_adapter-d17dc4a3e525e975.sab","line":4274,...}
```

## 期望

- SA test backend 不应在 LLVM lowering/codegen 阶段把 struct return 降成不匹配的 `i64`。
- SAB test backend 不应把合法的 loopback fixture/closure lowering 误判为 `StackEscape`。
- `check`、SA build、SAB build 都已通过时，test backend 应至少执行到用户测试并给出具体测试断言结果。

## 影响

该问题阻塞对真实 HTTP/SSE loopback test 的执行验证。当前 `sla_codex` 只能证明：

- HTTP adapter type-check 通过
- SA 文本后端 build 通过
- SAB build 通过
- DB adapter 独立 SA/SAB 测试通过

但无法用 `sa sla test` 执行 HTTP loopback 端到端测试。

## 相关说明

该失败形态在新增 observed persistence wrapper 前已由基线 HTTP adapter 复现，
不是 `sa_plugin_db` 或 caller-root persistence 写入逻辑引入的错误。
