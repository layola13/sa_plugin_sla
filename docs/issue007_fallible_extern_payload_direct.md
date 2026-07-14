# Issue 007: fallible extern payload calls were treated as raw scalar calls

## Symptom

Direct SLA calls to `.sai` externs declared with a fallible return, for example:

```text
@extern sa_fs_read_file(&path: ptr, path_len: u64, max_bytes: u64) -> u64!
```

were type-checked or lowered inconsistently. The type checker could expose the call as `void`, while codegen emitted the fallible ABI container as if it were the payload scalar. Downstream calls such as `sa_fs_read_buffer_len(buffer)` then received the wrong value shape, and LLVM builds could fail with a stored-value/pointer-operand type mismatch.

## Fix

The SLA type checker now maps fallible extern returns to their payload type for existing `.sai` ABI declarations. Both text SA codegen and direct SAB codegen call the extern into a fallible ABI container, load the payload from offset `+8`, release the container, and return the payload register to the SLA expression.

No SLA syntax was added.

## Regression

`tests/test_unit_fallible_extern_payload_direct.sla` calls `sa_fs_read_file`, feeds the returned payload into read-buffer externs, frees the buffer, and uses `switch`-based status helpers to cover the direct payload path.

## 2026-07-14 Follow-up

Reverified after dev plugin refresh:

```sh
zig build -j1 --summary all
zig build test -j1 -Dtest-filter="direct sab extern" --summary all
SA_PLUGIN_DEV=1 sa plugin install --dev .
SA_PLUGIN_DEV=1 sa sla help
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_fallible_extern_payload_direct.sla --test-backend sa --jobs 1 --trace-panic
SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_unit_fallible_extern_payload_direct.sla --test-backend sab --jobs 1 --trace-panic
```

All passed. A related SA-text call-argument gap was fixed at the same time:
raw-pointer string-literal/imported-macro results passed to by-value `ptr`
parameters now receive the required `^` operand prefix.
