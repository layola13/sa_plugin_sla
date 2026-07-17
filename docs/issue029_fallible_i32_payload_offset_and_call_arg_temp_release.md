# Issue 029: Fallible extern i32 payload and call-arg temp cleanup

Status: fixed/verified. SA-text and direct SAB share
`lowering_rules.abiFalliblePayloadOffset`; focused regressions are recorded
below.

## Symptom

SLA code that called `.sai` externs returning `i32!` could trip capability or cleanup failures while passing generated pointer/stack-slot temporaries through extern calls.

The same investigation also exposed call-argument cleanup gaps around stack-slot temporaries:

- owning value temps loaded from stack slots still need cleanup after a call;
- by-value raw `ptr` parameters must not release stack-slot load temps, because those values can be external handles or non-owning pointer scalars;
- direct SAB stack-slot assignment for raw `ptr` values must store with pointer storage type and consume loaded pointer scalars as non-owning values.

## Cause

SLA planned call lowering did not pass `.sai` raw `ptr` extern params through the shared call-argument materialization rules, so by-value raw pointers could be treated like owning aggregate values. A later cleanup pass over-corrected by releasing generated stack-slot load temps even when the target param was a by-value raw `ptr`.

The direct SAB path had the same ownership-class issue and also used the ordinary primitive type for `ptr` stack-slot stores, producing a `void` store type where later loads expected `ptr`.

During the investigation, the SA runtime ABI was verified with executable tests: fallible extern payloads use C ABI field alignment. `i32!` payloads are read from offset `+4`, while wider payloads such as `u64!` and `ptr!` are read from offset `+8`.

The native SA LLVM caller also needed a matching fix for external `i32!` functions. On x86_64, C returns `struct { i32 status; i32 value; }` packed in one `i64`; SCI now declares those external calls as `i64` and unpacks them back into the internal fallible aggregate before storing the call result.

## Fix

SA text and direct SAB codegen now keep by-value raw `ptr` params as by-value values instead of ownership transfers. SA text call-argument cleanup releases generated temporary result registers for stack-slot identifiers only when the target parameter is not by-value raw `ptr`.

Direct SAB now treats raw `ptr` stack-slot assignment sources as non-owning values and stores them with pointer storage type.

SA text and direct SAB now share `lowering_rules.abiFalliblePayloadOffset`, so both backends use offset `+4` for `i32!` and offset `+8` for `u64!`, `ptr!`, and other 8-byte-aligned payloads.

## Regression

`tests/test_unit_fallible_extern_payload_direct.sla` now covers:

- `u64!` payloads via `sa_fs_read_file`.
- `i32!` payloads via `sa_fs_metadata_free(metadata)`.
- consuming `ptr!` cleanup via `sa_json_free(node)`.

Additional focused regressions:

- `src/codegen.zig`: `by-value raw pointer call arg does not release stack-slot load temp`.
- `tests/test_unit_ptr_value_arg_reuse.sla`: `by value ptr stack slot params can be reused after calls`, verified with SA backend and strict direct SAB backend.
