# issue025: sa_std buffer_free consuming handle cleanup UseAfterMove

Date: 2026-07-15
Status: fixed in source; pending normal plugin release

## Context

While removing the obsolete Deno plugin dependency from `sla-hub`, the runtime
env/file bridge was migrated to `sa_std/env.sai` and `sa_std/fs.sai`.

The SA-facing contracts mark buffer-free helpers as consuming scalar handles:

```text
@extern sa_env_buffer_free(^buffer: u64) -> i32
@extern sa_fs_read_buffer_free(^buffer: u64) -> i32
```

Calling these helpers from SLA after reading an owned `sa_std` buffer can fail
verification with `UseAfterMove`, even though source code uses the handle only
once for cleanup.

## Minimal Shape

This shape reproduces the problem:

```sla
@import "sa_std/env.sai"
@import "sa_std/env.sa"

@test "std env buffer free consumes once"() {
    let handle = sa_env_get(STR_PTR("SLA_STD_ENV_PROBE"), STR_LEN("SLA_STD_ENV_PROBE") as u64);
    let data = ENV_BUFFER_DATA(handle);
    let len = sa_env_buffer_len(handle);
    if len == 0 { panic(8103); };
    if sa_env_buffer_free(handle) != 0 { panic(8105); };
}
```

Observed verifier failure:

```text
error[UseAfterMove]: moved value is no longer usable
source_text: !handle
register: handle
state: expected Consumed, actual Consumed
```

The same shape also appears through the macro facade:

```sla
let free_status: i32 = 0;
ENV_BUFFER_FREE(free_status, handle);
```

The expanded SA call consumes `handle`, then lexical cleanup still emits a
second release/fence for the same register.

## Expected Behavior

A scalar passed to an extern parameter marked `^buffer: u64` should be consumed
exactly once. The function-local cleanup pass should recognize that the value
has already been consumed and should not emit a second cleanup use.

## Actual Behavior

The generated cleanup attempts to use the consumed scalar again and verifier
reports `UseAfterMove`.

## Impact

Projects using `sa_std` owned buffer handles cannot directly call the intended
typed free helpers from SLA without tripping verifier cleanup in some contexts.
This affects env and fs buffer handles at least:

- `sa_env_buffer_free(^buffer: u64)`
- `sa_fs_read_buffer_free(^buffer: u64)`

## Fix

The SLA plugin now handles consuming extern scalar arguments in two places:

- the type checker marks direct identifier arguments passed to `^` extern
  params as consumed, so lexical cleanup does not release them again;
- the SA-text codegen path treats generated temporaries for extern move args
  as consumed after the call instead of emitting a normal release.

This covers both direct handles and field-access temporaries such as
`value.handle`.

Regression coverage:

- `sla typechecker treats extern move args as consumed for cleanup`
- `sla sa codegen does not release extern move field temps`

Project-side workaround removed:

- `/home/vscode/projects/sla-hub/src/env_bridge.sla` now calls
  `sa_env_buffer_free(handle)` and `sa_fs_read_buffer_free(handle)` directly.

## Verification

- `zig build test --summary all` in `sa_plugin_sla`: 218/218 passed.
- `SA_PLUGIN_DEV=1 sa sla test src/env_bridge.sla --test-backend sa`: passed.
- `SA_PLUGIN_DEV=1 sa sla test src/config_bridge.sla --test-backend sa`: passed.
- `SA_PLUGIN_DEV=1 sa sla test src/runtime.sla --test-backend sa`: passed.
