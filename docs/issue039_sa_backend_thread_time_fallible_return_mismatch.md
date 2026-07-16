# Issue 039: SA backend thread/time fallible return mismatch blocks live HTTP loopback

## Symptom

Current `SA_PLUGIN_DEV=1 sa sla test --test-backend sa` can emit an LLVM backend return type mismatch when SLA code uses std thread/time helpers needed by live HTTP loopback tests:

```text
llvmc backend: Function return type does not match operand type of return inst!
  ret { i32, i32 } zeroinitializer
 i64
error: Failed
```

The same class of failure appears for existing thread tests, not just scodex code:

```sh
timeout 180s env SA_PLUGIN_DEV=1 sa sla test \
  /home/vscode/projects/sa_plugins/sa_plugin_sla/tests/test_unit_fn_ptr_thread_pair_direct.sla \
  --test-backend sa --trace-panic
```

Using `thread::sleep(Duration::from_millis(1))` through `sa_std/time.sla` also triggers the mismatch in scodex live HTTP/SSE loopback work. Trying to route through `TIME_THREAD_SLEEP_NS` exposes the same lower-level problem around `sa_time_sleep_ns(ns: u64) -> i32!`.

## Impact

`/home/vscode/projects/sla_codex/crates/scodex-runtime/src/http_server_adapter.sla` can start a real `http-server`, send an async `http-client` request, and perform the server accept/respond step, but the client side needs either:

- a working std sleep/yield while polling the async operation, or
- a working worker thread so the main thread can perform a synchronous client request while the server accepts/responds.

Both paths currently hit the SA backend mismatch above.

## Notes

- `sa sla build` can still emit SA text for the scodex file.
- The generated `thread_sleep` wrapper is `void`, but expands `TIME_THREAD_SLEEP_NS`, which calls `sa_time_sleep_ns`.
- A temporary attempt to change `sa_time_sleep_ns` to plain `i32` in the active std surface changed the mismatch from `... i64` to `... i32`, indicating the runtime/backend still materializes a `{ i32, i32 }` return shape.
- A temporary attempt to apply `?` inside `TIME_THREAD_SLEEP_NS` produced `EarlyReturnLeak` before the LLVM stage, matching the current fallible-cleanup constraints for macro expansion.

## Requested fix

Audit SA backend lowering for:

- `JoinHandle<T>::join().unwrap()` return lowering for scalar `T`.
- Imported fallible extern calls such as `sa_time_sleep_ns(ns: u64) -> i32!`.
- Macro-expanded fallible calls in std helpers where the result is intentionally ignored or converted into blocking/yield behavior.

Add focused regressions for:

- `tests/test_unit_fn_ptr_thread_pair_direct.sla` on `--test-backend sa`.
- `sa_std/time.sla` `thread::sleep(Duration::from_millis(1))` on `--test-backend sa`.
- A loopback-style async poll that sleeps/yields between `sa_http_client_async_poll` calls.
