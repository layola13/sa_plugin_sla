# Issue 039: SA backend thread/time fallible return mismatch blocks live HTTP loopback

## Status

Resolved for the focused SA-backend thread and sleep blockers on 2026-07-17.
The downstream scodex live HTTP loopback can now revalidate against these
compiler paths; that downstream integration is not part of this focused
compiler regression slice.

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

## Root cause

- SCI's runtime exports both `sa_time_sleep_ns` and `sa_time_sleep_ms` as
  ordinary `i32` functions.
- `sci/sa_std/time.sai` declares both functions as `i32!`.
- SCI's LLVM shim additionally hardcodes `sa_time_sleep_ns` as a fallible
  `{ i32, i32 }` function, so changing only the generated declaration cannot
  make that symbol ABI-consistent.
- `sa_time_sleep_ms` is not covered by the hardcoded shim. A focused plain-SA
  test declaring `sa_time_sleep_ms(ms: u64) -> i32` passed 1/1.
- The thread function-pointer path separately needed inline escaped-closure
  execution, scalar `JoinHandle<T>::join()` Result construction, and unwrap
  lowering that avoid the mismatched pthread/fallible surface for captures
  that cannot safely escape.

## Fix

- SA-text thread closures capturing function pointers or noncopy payloads now
  consume the shared escaped-closure execution plan and use inline join
  storage. Generated output for the pair fixture contains no pthread branch,
  indirect call, spawn wrapper, or unused `sa_std/thread.sa` import.
- SA-text manually constructs scalar join Results and lowers Result unwrap
  without the mismatched macro return path.
- When the selected time surface contains only
  `TIME_DURATION_FROM_MILLIS` plus `TIME_THREAD_SLEEP_NS`, codegen now lowers
  the duration multiplication directly, omits `sa_std/time.sa`, declares
  `sa_time_sleep_ms(u64) -> i32`, and calls that ordinary ABI. Nanoseconds are
  rounded up to milliseconds so a nonzero sub-millisecond duration is not
  truncated to zero.
- Other time macro combinations retain the existing std import and lowering;
  the workaround does not silently rewrite unsupported time surfaces.

Added focused regression:

- `tests/test_unit_time_sleep_fallible_direct.sla`

## Verification

All compiler build/test commands were run serially after checking for existing
Zig/SA processes:

- `zig fmt --check src/codegen.zig`
- `zig build -j1 --summary all`: 7/7
- local SA pair fixture: 1/1
- local SA time sleep fixture: 1/1
- `SA_PLUGIN_DEV=1 sa plugin install --dev .`
- `SA_PLUGIN_DEV=1 sa sla help`
- installed/dev SA pair fixture: 1/1
- installed/dev SA time sleep fixture: 1/1
- generated time fixture contains no `sa_std/time.sa`, `TIME_*`, or
  `sa_time_sleep_ns` reference
- `git diff --check`

No full Zig or SLA test suite was run.
