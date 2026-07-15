# Issue 029: Fallible extern i32 payload and call-arg temp cleanup

## Symptom

SLA code that called `.sai` externs returning `i32!` could trip capability or cleanup failures while passing generated pointer/stack-slot temporaries through extern calls.

The same investigation also exposed a call-argument cleanup gap: when an identifier lived in an addressable stack slot, `genExpr(identifier)` could materialize a temporary `load` register, but call-argument cleanup still classified the source as a plain identifier and did not release that temporary.

## Cause

SLA planned call lowering did not pass `.sai` raw `ptr` extern params through the shared call-argument materialization rules, so by-value raw pointers could be treated like owning aggregate values. The cleanup path also missed temporary registers produced while reading stack-slot identifiers.

During the investigation, the SA runtime ABI was verified with executable tests: fallible extern payloads are read from the SA ABI payload slot at offset `+8`, including `i32!`.

## Fix

SA text and direct SAB codegen now keep by-value raw `ptr` extern params as by-value values instead of ownership transfers. SA text call-argument cleanup also releases generated temporary result registers for stack-slot identifiers and materializing casts.

## Regression

`tests/test_unit_fallible_extern_payload_direct.sla` now covers both:

- `u64!` payloads via `sa_fs_read_file`.
- `i32!` payloads via `sa_fs_metadata_free(metadata)`.
