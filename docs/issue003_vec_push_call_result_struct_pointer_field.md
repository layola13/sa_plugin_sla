# issue003: helper-returned struct stored in Vec lost pointer-backed field borrow

Status: fixed/verified. Dev-plugin SA and strict direct-SAB focused regressions
are recorded below.

## Symptom

Parsing `PushTrack`-style values stored in `Vec<T>` failed when later borrowing a
nested pointer-backed field such as `&ast.tracks[0].name`.

Observed failure:

- SA-text: `panic(43002)`
- direct SAB: same panic in the equivalent test

## Root Cause

The compiler handled the helper-returned struct correctly, but the nested field
borrow lowering was wrong:

- `Vec<T>` stored the returned struct value as expected.
- Borrowing a nested pointer-backed field used the field slot address instead of
  the loaded pointer value.
- In direct SAB, the same shape was still emitted as an address borrow at the
  call site, so `&field` on a pointer-backed field kept pointing at the slot,
  not the pointee.

That made `push_span_len(&ast.tracks[0].name)` read the wrong memory.

## Fix

- SA-text `genBorrow` now loads pointer-backed fields before borrowing them.
- direct SAB `genBorrow` does the same.
- direct SAB prefixed borrow-arg lowering now treats any pointer-backed field
  like the existing Vec-field special case and passes the loaded pointer value.

## Regression

- `tests/test_unit_vec_push_call_result_struct.sla`

## Verification

```sh
zig build
SA_PLUGIN_DEV=1 sa plugin install --dev /home/vscode/projects/sa_plugins/sa_plugin_sla
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_vec_push_call_result_struct.sla --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_vec_push_call_result_struct.sla --test-backend sab --jobs 1 --trace-panic
```

## 2026-07-14 Follow-up

Reverified after the direct SAB pointer-backed field-borrow and call-argument
cleanup fixes:

```sh
SA_PLUGIN_DEV=1 sa plugin install --dev .
SA_PLUGIN_DEV=1 sa sla help
SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_unit_vec_push_call_result_struct.sla --test-backend sab --jobs 1 --trace-panic
```

The strict direct SAB gate passes under `SLA_SAB_NO_FALLBACK=1`.

## 2026-07-14 Follow-up: local struct field copies

Extended the regression with
`"vec push consumes local struct field copies"`, covering the related shape
where `PushSpan` values are first bound to locals and then moved into a
`PushTrack` struct literal before `Vec::push`.

Fix detail: direct SAB now releases the moved source after creating a
shallow-copy value for all-scalar pointer-backed struct fields, and marks the
copied field value as transferred into the containing struct.

Verification:

```sh
zig build -j1 --summary all
SA_PLUGIN_DEV=1 sa plugin install --dev .
SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_unit_vec_push_call_result_struct.sla --test-backend sab --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_vec_push_call_result_struct.sla --test-backend sa --jobs 1 --trace-panic
```

Result: both SA and strict direct SAB pass 2/2.
