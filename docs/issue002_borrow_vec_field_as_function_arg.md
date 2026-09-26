# issue002: borrowing Vec field as function argument can change helper behavior

Date: 2026-07-13

Status: fixed/verified. Dev-plugin SA and strict direct-SAB focused regressions
are recorded below.

## Context

While implementing `/home/vscode/projects/sla_music_cli/src/music_parse.sla`, a
helper behaved differently when passed a local `Vec<u8>` versus a borrowed
`Vec<u8>` field from a parser struct.

## Observed commands

```sh
cd /home/vscode/projects/sla_music_cli
SA_PLUGIN_DEV=1 sa sla test src/music_parse.sla --test-backend sa --jobs 1 --trace-panic --filter "ident advances"
```

The test verified:

```sla
if first.start != 0 { panic(3037); };
if first.end != 5 { panic(3038); };
if parser.source[0] != 116 { panic(3039); };
let keyword = music_keyword(&parser.source, &first);
```

The span and byte check passed, but `music_keyword(&parser.source, &first)`
returned `MusicKeyword::Unknown` and panicked with `3032`.

A sibling test using a local vector passed:

```sla
let source = music_test_source_small();
let span = span_new(0, 5);
let keyword = music_keyword(&source, &span);
```

## Expected

Passing `&parser.source` to a helper should behave the same as passing `&source`
when the field contains the same `Vec<u8>` value.

## Workaround

Keep parser state separate from the source buffer: store only `offset` in the
parser state and pass the source buffer as an explicit `&Vec<u8>` argument.

## Root Cause

`Vec<T>` stored in a struct field is represented as a pointer-backed owner in
the field slot. Field indexing and explicit field borrows were lowering through
the same path as ordinary field address projection, so `holder.values[0]` and
`&holder.values` could pass the field slot where downstream Vec logic expected
the Vec owner pointer.

This was masked for some `Vec<i32>` paths, but `Vec<u8>` exposed it because the
typed element load and the field-slot/owner distinction both matter.

## Resolution

Fixed in `src/codegen.zig` and `src/sab_codegen.zig`.

- SA-text Vec index read/write and `len(Vec)` now use a Vec owner receiver.
- For Vec fields, the receiver is loaded from the field slot before reading
  `Vec_ptr` / `Vec_len`.
- Explicit `&vec_field` call arguments now pass the loaded Vec owner pointer,
  matching the effective shape of `&local_vec`.
- Element reads use the concrete element load type, so `Vec<u8>` reads `u8`
  instead of loading a full `u64` slot and casting.
- Direct SAB mirrors the explicit `&Vec` field call-arg behavior and keeps
  Vec direct indexing on owner pointers.

Regression added:

```text
tests/test_unit_borrow_vec_field_call_arg.sla
```

Verified with dev plugin mode:

```sh
zig build
SA_PLUGIN_DEV=1 sa plugin install --dev /home/vscode/projects/sa_plugins/sa_plugin_sla
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_borrow_vec_field_call_arg.sla --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_borrow_vec_field_call_arg.sla --test-backend sab --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_vec_index_assign.sla --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_vec_index_assign.sla --test-backend sab --jobs 1 --trace-panic
```

## 2026-07-14 Follow-up

Reverified after the direct SAB Vec-field owner and call-argument cleanup fixes:

```sh
SA_PLUGIN_DEV=1 sa plugin install --dev .
SA_PLUGIN_DEV=1 sa sla help
SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_unit_borrow_vec_field_call_arg.sla --test-backend sab --jobs 1 --trace-panic
```

The strict direct SAB gate passes under `SLA_SAB_NO_FALLBACK=1`.
