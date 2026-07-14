# issue009: Vec field owner regression in direct SAB field borrows

Date: 2026-07-14

## Context

While extending `/home/vscode/projects/sla_music_cli`, byte-reader tests exposed
that a `Vec<u8>` stored in a struct field could be read as empty or corrupted
when borrowed through another struct.

This regressed the earlier `issue002` coverage around `&holder.values` and
`holder.values[0]`.

## Reproduction

```sh
cd /home/vscode/projects/sa_plugins/sa_plugin_sla
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_borrow_vec_field_call_arg.sla --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_borrow_vec_field_call_arg.sla --test-backend sab --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_borrow_struct_with_borrow_field_mutates_plain_field.sla --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_borrow_struct_with_borrow_field_mutates_plain_field.sla --test-backend sab --jobs 1 --trace-panic
```

The failing shapes were:

```sla
if holder.values[0] != 116 { panic(42002); };
if vec_field_first_is_track(&holder.values) != true { panic(42003); };

let reader = borrow_reader_new(&writer.bytes);
if borrow_reader_read_u8(&reader) != 77 { panic(7131); };
```

## Root Cause

SA-text already loaded the Vec owner from the struct field slot before direct
indexing or passing `&field` as a `&Vec<T>` argument.

Direct SAB still treated the field slot address itself as the Vec owner in two
places:

- direct Vec owner receiver for `field[index]`
- prefixed `&field` call-argument lowering for `&Vec<T>`

That let callees read the containing struct or field slot as though it were a
Vec header.

## Resolution

`src/sab_codegen.zig` now mirrors SA-text for Vec fields:

- `genVecOwnerReceiver` loads the owner pointer from a field projection before
  reading `Vec_ptr` / `Vec_len`.
- `genBorrow` returns the loaded owner for `&vec_field`.
- prefixed borrow call-arg lowering passes the loaded Vec owner for
  `&vec_field`, then releases that temporary after the call.

Verified after rebuilding and installing the dev plugin:

```sh
zig build
SA_PLUGIN_DEV=1 sa plugin install --dev /home/vscode/projects/sa_plugins/sa_plugin_sla
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_borrow_vec_field_call_arg.sla --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_borrow_vec_field_call_arg.sla --test-backend sab --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_borrow_struct_with_borrow_field_mutates_plain_field.sla --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_borrow_struct_with_borrow_field_mutates_plain_field.sla --test-backend sab --jobs 1 --trace-panic
```

## 2026-07-14 Follow-up

Reverified the direct SAB owner paths after the pointer-backed field-borrow and
Vec direct-index fixes:

```sh
SA_PLUGIN_DEV=1 sa plugin install --dev .
SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_unit_borrow_vec_field_call_arg.sla --test-backend sab --jobs 1 --trace-panic
SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_unit_vec_push_call_result_struct.sla --test-backend sab --jobs 1 --trace-panic
SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_unit_borrow_struct_with_borrow_field_mutates_plain_field.sla --test-backend sab --jobs 1 --trace-panic
```

All passed under `SLA_SAB_NO_FALLBACK=1`.
