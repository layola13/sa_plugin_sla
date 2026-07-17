# issue048: SLA music struct literal Vec field direct-SAB MemoryLeak

Date: 2026-07-17

Status: fixed

## Summary

The filtered strict direct-SAB run for the current dirty `sla_music_cli`
`src/music_lower.sla` note-ordering regression failed before assertions with a
function-exit `MemoryLeak`.

The failing command was:

```sh
SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test src/music_lower.sla \
  --test-backend sab \
  --filter "music normalized sla orders same track notes by tick" \
  --jobs 1 --trace-panic
```

The reported register was `tmp_8253` in
`.sla-cache/sab/music_lower-7e2144818a7195b3.sab`.

## Root Cause

Disassembling the generated SAB showed `tmp_8253` was the result of
`Vec::new()` for this struct-literal field:

```sla
music_ir_add_track(&ir, MusicIrTrack {
    name: span_new(0, 1),
    imported_name: Vec::new(),
    ...
});
```

Direct SAB stored the owned field value into the aggregate but only marked the
temporary consumed in codegen state. It did not emit a visible SAB consumed
marker for the stored field value. When the aggregate was later moved into the
by-value call argument, the verifier still saw the field temporary as live at
function exit.

## Fix

`src/sab_codegen.zig::genStructLiteral()` now emits the same visible consumed
marker used by macro struct-literal lowering when a non-identifier moved field
value needs release after being stored into the aggregate.

Added focused coverage in
`tests/test_unit_vec_push_call_result_struct.sla`:
`direct sab moves vec new struct literal field into call arg`.

## Verification

No full test suite was run.

- `zig fmt --check src/sab_codegen.zig`
- `zig build -j1 --summary all` 7/7
- Local strict SAB focused fixture:
  `SLA_SAB_NO_FALLBACK=1 ./zig-out/bin/sla-local-cli sla test
  tests/test_unit_vec_push_call_result_struct.sla --test-backend sab --filter
  "direct sab moves vec new struct literal field into call arg" --jobs 1
  --trace-panic` passed 1/1.
- `SA_PLUGIN_DEV=1 sa plugin install --dev .`
- `SA_PLUGIN_DEV=1 sa sla help`
- Installed/dev strict SAB focused fixture passed 1/1.
- Downstream dirty `sla_music_cli` strict SAB filter
  `music normalized sla orders same track notes by tick` passed 1/1.
