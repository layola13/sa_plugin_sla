# issue034: sla_music_cli MidiIR Vec element repeated field load fails SA with UseAfterMove

Date: 2026-07-16

Status: fixed

## Summary

The `sla_music_cli` SA-text fallback gate fails while verifying generated SA
for the existing `midi_ir_to_music_ir` function:

```text
error[UseAfterMove]: moved value is no longer usable
  in function @sla__midi_ir_to_music_ir(&midi: ptr) -> ptr:
  line 48948 (expanded 12251): tmp_3453 = load tmp_3432+0 as u8
  register: tmp_3432
  state: expected Consumed, actual Consumed
```

The failure reproduces on the clean music commit `89ef3bd`, so it is not caused
by the subsequent uncommitted editor-plan reader work.

## Repro

From `/home/vscode/projects/sla_music_cli`:

```sh
SLA_KEEP_TEST_SA=1 SA_PLUGIN_DEV=1 sa sla test src/music_ir.sla \
  --test-backend sa --jobs 1 --trace-panic
```

`SA_PLUGIN_DEV=1 sa sla check src/music_ir.sla` succeeds. The failure occurs
only after SLA emits `src/music_ir.test.sa` and the SA verifier checks it.

## Source Shape

The relevant SLA code reads one `Vec<MidiIrTrack>` element and then projects
several scalar fields from it:

```sla
let track = midi.tracks[i];
music_ir_add_track(&ir, MusicIrTrack {
    is_drum: track.channel == 9,
    instr: track.program as i64,
    channel: track.channel as i64,
    group: track.group as i64,
    // other fields omitted
});
```

The generated SA obtains the element owner pointer in `tmp_3432`, consumes it
immediately after loading `track.channel`, and then uses the consumed pointer
for `track.program`, `track.channel`, and `track.group`:

```sa
tmp_3432 = tmp_3441
tmp_3450 = load tmp_3432+1 as u8
!tmp_3432
...
tmp_3453 = load tmp_3432+0 as u8
...
tmp_3461 = load tmp_3432+1 as u8
tmp_3463 = load tmp_3432+2 as u8
```

## Resolution

SA-text codegen treats the pointer-backed `Vec` element projection as though
the first scalar field read ends the aggregate temporary's lifetime. Later
field projections still reference the same temporary register. This is a
codegen ownership/lifecycle defect rather than invalid SLA source.

This is narrower than the older general Vec alias report
`issue_music_ir_vec_inline_struct_index_alias_cn.md`: the generated element
pointer and exact premature consume are now known.

The field-base lifetime fixes from issues035/033 now keep resolved lexical
aggregate bindings alive while still releasing genuine temporary field bases.
The original `music_ir.sla` SA backend repro passes in the current tree.

Added `tests/test_unit_vec_index_assign.sla` coverage for a pointer-backed
struct stored in a `Vec`, assigned to a local, and read through repeated scalar
fields in one aggregate literal.

Direct SAB for the focused compiler fixture passes. The real
`sla_music_cli/src/music_ir.sla` strict SAB path fails differently with
`UnsupportedSabDirectFeature`; that is tracked separately as issue040.

## Verification

Serial focused verification only; no full suite was run:

- `git diff --check`.
- `zig build -j1 --summary all` 7/7.
- Local `tests/test_unit_vec_index_assign.sla` SA 6/6.
- Local strict SAB for the same fixture 6/6.
- Official `SA_PLUGIN_DEV=1 sa plugin install --dev .` and
  `SA_PLUGIN_DEV=1 sa sla help`.
- Installed/dev `tests/test_unit_vec_index_assign.sla` SA 6/6.
- Installed/dev strict SAB for the same fixture 6/6.
- Downstream `/home/vscode/projects/sla_music_cli/src/music_ir.sla` SA
  backend 25/25.
