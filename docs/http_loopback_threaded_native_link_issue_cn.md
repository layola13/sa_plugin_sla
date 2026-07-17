# HTTP loopback threaded native link issue

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
