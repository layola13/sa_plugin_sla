# HTTP loopback threaded native link issue

状态：partial/runtime residual（2026-07-19）。llvmc `ret {i32,i32}` 与 SAB StackEscape 已消除：check/sab build/build-obj 通过；SA test 运行时 panic 断言失败，SAB test 运行时 signal 11。线程 spawn 参数名改为唯一符号，避免与 `slot = stack_alloc` 冲突。

日期: 2026-07-17

## 摘要

`sla_codex` 的 Responses HTTP/SSE loopback 在 `.sa` check/build 阶段可以通过，
但包含 threaded client worker 的旧 adapter 在 native link / workspace build 阶段仍会触发后端错误。

受影响文件:

- `/home/vscode/projects/sla_codex/crates/scodex-runtime/src/http_loopback_sse_adapter.sla`

相关命令:

```sh
SA_PLUGIN_DEV=1 sa sla build crates/scodex-runtime/src/http_loopback_sse_adapter.sla --out /tmp/scodex-http-loopback.sa
SA_PLUGIN_DEV=1 sa build-exe /tmp/scodex-http-loopback.sa -o /tmp/scodex-http-loopback
SA_PLUGIN_DEV=1 sa sla build-workspace -p scodex-cli -o /tmp/scodex-workspace
```

## 现象

`.sa` build 成功，但 native executable / workspace object emit 失败:

```text
llvmc backend: Function return type does not match operand type of return inst!
  ret { i32, i32 } zeroinitializer
 i64
```

将 thread worker 改为通过 buffer 写状态并返回 `u64` 后，仍能在 thread
closure lowering 路径遇到 slot/capture 相关错误:

```text
error[UseAfterMove]: moved value is no longer usable
  in function @sla_thread_worker_0(&slot: ptr) -> i32
```

## 当前 workaround

`sla_codex` 新增了不导入旧 threaded adapter 的 executable-safe adapter:

- `/home/vscode/projects/sla_codex/crates/scodex-runtime/src/http_loopback_exec_adapter.sla`

该 adapter 使用单线程 async client request + server accept/respond + post-response poll，
可以通过:

```sh
SA_PLUGIN_DEV=1 sa sla check crates/scodex-runtime/src/http_loopback_exec_adapter.sla
SA_PLUGIN_DEV=1 sa sla build crates/scodex-runtime/src/http_loopback_exec_adapter.sla --out /tmp/scodex-http-exec-loopback.sa
SA_PLUGIN_DEV=1 sa build-exe /tmp/scodex-main.sa -o /tmp/scodex
```

但单线程 async workaround 目前只能让 native `scodex exec` 到达 server-side
request validation，client response readiness 仍 fail-closed (`16202`)。完整
Responses loopback 仍需要 threaded/concurrent path 能够 native link。

## 期望

- `thread::spawn(^|| worker(...))` 支持 worker 返回结构体，或清晰拒绝并给出诊断。
- `thread::spawn` 捕获多个 ptr/u64 参数并返回 `u64` 时，不应在 generated
  `@sla_thread_worker_*` 中产生 slot `UseAfterMove`。
- 成功 native link 后，`sla_codex` 可以移除 executable-only workaround，直接复用
  request-aware HTTP loopback observed persistence adapter。

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
