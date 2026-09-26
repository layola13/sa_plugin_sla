# HTTP loopback adapter test backend regressions

状态：partial/runtime residual（2026-07-19）。llvmc `ret {i32,i32}` 与 SAB StackEscape 已消除：check/sab build/build-obj 通过；SA test 运行时 panic 断言失败，SAB test 运行时 signal 11。线程 spawn 参数名改为唯一符号，避免与 `slot = stack_alloc` 冲突。

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

## 2026-07-19 recheck

```sh
timeout 60s env SA_PLUGIN_DEV=1 sa sla check crates/scodex-runtime/src/http_loopback_sse_adapter.sla
timeout 60s env SA_PLUGIN_DEV=1 sa sla sab build crates/scodex-runtime/src/http_loopback_sse_adapter.sla --out /tmp/scodex-http.sab
timeout 90s env SA_PLUGIN_DEV=1 sa sla test crates/scodex-runtime/src/http_loopback_sse_adapter.sla --test-backend sa --jobs 1 --trace-panic
timeout 90s env SA_PLUGIN_DEV=1 sa build-obj /tmp/http_loop.sa -o /tmp/http_loop.o
```

Results:

- check / sab build: pass
- test / build-obj: llvmc `Function return type does not match operand type of return inst! ret { i32, i32 } zeroinitializer` vs `i32`

This residual is a native-backend ABI/return-shape issue (SCI `llvmc`), not the original SLA plugin SAB MemoryLeak path. Keep open until native return lowering is fixed or adapter return shapes are rewritten.


## 2026-07-19 复核

仍 open。`http_loopback_sse_adapter.sla`：check 通过；strict SAB test 仍 `StackEscape`（tmp 寄存器）。threaded native link 工单仍依赖 thread worker 结构体返回/slot capture 修复；exec-safe 单线程 workaround 仍是下游规避路径。

## 2026-07-19 SCI/native + SAB follow-up

### Closed in this pass
1. **llvmc return-type mismatch** (`ret { i32, i32 } zeroinitializer` vs `i32`): current SCI `sa build-obj` on the generated adapter `.sa` succeeds; no longer a compile blocker.
2. **SAB StackEscape on thread spawn**: direct SAB thread spawn/worker params no longer reuse the bare name `slot`, which collided with ordinary `slot = stack_alloc 8` locals in the same module (same symbol id). Fix in `sa_plugin_sla` `emitEscapedSpawnWrapper` / `emitEscapedWorker`.

### Still open
- SA backend focused tests compile and run but **assert-fail** (`panic 19021/19031/...`) — adapter/runtime behavior, not native ABI compile.
- SAB backend focused tests now pass verify/codegen but **signal 11** at runtime under the loopback worker path — remaining correctness residual.

Verification:
```sh
timeout 40s sa build-obj /tmp/http_loop_new.sa -o /tmp/http_loop_ok.o
timeout 60s env SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla sab build crates/scodex-runtime/src/http_loopback_sse_adapter.sla --out /tmp/http.sab
timeout 60s env SA_PLUGIN_DEV=1 sa sla test crates/scodex-runtime/src/http_loopback_sse_adapter.sla --test-backend sa --jobs 1 --filter "http loopback sse fails closed on non success response"
```
