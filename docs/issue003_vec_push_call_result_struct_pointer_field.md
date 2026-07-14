# issue003: helper-returned struct stored in Vec lost pointer-backed field borrow

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
