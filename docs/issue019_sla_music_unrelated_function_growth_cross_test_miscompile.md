# issue019: SLA music unrelated function growth cross-test miscompile

Date: 2026-07-14

## Status

Open; current SLAN/source-growth direct-SAB subcase fixed on 2026-07-17.

## Summary

In `/home/vscode/projects/sla_music_cli`, small unrelated source changes can
make previously passing tests fail in other imported modules. The observed
failures look like a backend/codegen instability rather than a music-domain
logic regression because the failing tests do not execute the edited logic.

Two independent attempts reproduced the same shape:

- Expanding `midi_is_indicator_header` in `src/midi.sla` from a 4-byte `MIDI`
  check to the full 13-byte `MIDI2.0.0` indicator header caused broad SMF tests
  to fail.
- Expanding `music_patch_write_editor_text` in `src/music_ir.sla` to serialize
  already-carried layout context fields caused `src/music_ir.sla` itself to
  pass, but `src/midi.sla` failed under both SA-text and direct SAB. SA-text
  also failed unrelated `src/music_parse.sla` and `src/music_lower.sla` tests.

Both attempted SLA changes were reverted in `sla_music_cli`; the project was
left clean rather than committing a slice that breaks the fallback gate.

## Reproduction Notes

Baseline at `/home/vscode/projects/sla_music_cli` commit `ea1842b` previously
passed the fallback gate:

```sh
SA_PLUGIN_DEV=1 sa sla test src/byte.sla --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test src/music_ir.sla --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test src/midi.sla --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test src/music_parse.sla --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test src/music_lower.sla --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla check src/main.sla
```

The `music_patch_write_editor_text` expansion only added additional calls to
existing integer serialization helpers for fields already present in
`MusicPatchHunk`:

- `glyph_y_layout`
- `glyph_collision_lane`
- `glyph_beam_group`
- `glyph_beam_position`

After that change:

```sh
SA_PLUGIN_DEV=1 sa sla test src/music_ir.sla --test-backend sa --jobs 1 --trace-panic
```

passed 14/14, but:

```sh
SA_PLUGIN_DEV=1 sa sla test src/midi.sla --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test src/midi.sla --test-backend sab --jobs 1 --trace-panic
```

both failed the same unrelated SMF tests, including panics `2017`, `2205`,
`2403`, `2412`, `2302`, `2604`, `2614`, and `2650`.

SA-text additionally failed parser/lower tests such as panics `3002`, `3041`,
`3102`, and related lowerer assertions. A direct SAB check of
`src/music_parse.sla` still passed, suggesting at least part of that wider
failure set is SA-text-specific.

## Expected

Adding extra serialization calls in `music_patch_write_editor_text`, or adding
extra byte comparisons in `midi_is_indicator_header`, should not change SMF
writer/parser behavior or parser/lower tests that do not execute that code.

## Actual

Unrelated tests fail with invalid parsed output or missing parsed IR data after
small source growth in an imported module.

## Impact

This blocks continuing richer pure-SLA music patch serialization and stricter
MIDI Clip header validation while keeping the required SA-text fallback gate
healthy.

## 2026-07-17 Focused Subcase

While extending `/home/vscode/projects/sla_music_cli/src/midi.sla` with
SMF2 UMP `SLAN` malformed-payload coverage, the single focused SA-text test:

```sh
SA_PLUGIN_DEV=1 sa sla test src/midi.sla --test-backend sa --jobs 1 \
  --trace-panic --filter "smf2 ump rejects unsupported packet types"
```

passed 1/1, but the matching strict direct-SAB filter failed before assertions:

```text
error[RegisterRedefinition]: register is already live
register: end_tick
```

The generated SAB showed `NUM_U64_CHECKED_ADD(add_ok, end_tick, ...)` lowering
its leading output directly into the existing stack slot for `end_tick`, e.g.
an `op.add` destination was the same register previously defined by
`stack_alloc`. Direct SAB now routes imported scalar macro leading outputs that
target stack-slot locals through a temporary register and stores the result
back into the slot.

Added focused compiler regression:

- `tests/test_unit_checked_add_macro_output_direct.sla`
- Zig regression: `sla sab backend stores imported scalar macro outputs into stack slots`

Serial focused verification passed:

- `zig build test -j1 -Dtest-filter='stores imported scalar macro outputs' --summary all`: 2/2.
- `zig build -j1 --summary all`: 7/7.
- local generated-SA fixture 1/1.
- local strict direct-SAB fixture 1/1.
- `SA_PLUGIN_DEV=1 sa plugin install --dev .`.
- `SA_PLUGIN_DEV=1 sa sla help`.
- installed/dev generated-SA fixture 1/1.
- installed/dev strict direct-SAB fixture 1/1.
- downstream dirty checkout focused strict direct-SAB
  `src/midi.sla --filter "smf2 ump rejects unsupported packet types"`: 1/1.

This does not close the whole issue019 cross-test instability: the current
`sla_music_cli` checkout is dirty, and no broader `midi.sla` or fallback-gate
rerun was used for this slice.

## 2026-07-17 Current Representative Recheck

After the focused direct-SAB subcase was fixed, the currently relevant
representative probes no longer reproduce the earlier cross-test symptoms on
the current tree:

- `SA_PLUGIN_DEV=1 sa sla test src/music_parse.sla --test-backend sa --jobs 1 --trace-panic --filter "music parser captures top level track and score"` passed 1/1.
- `SA_PLUGIN_DEV=1 sa sla test src/midi.sla --test-backend sa --jobs 1 --trace-panic --filter "smf1 imports back into midi ir"` passed 1/1.
- `SA_PLUGIN_DEV=1 sa sla test src/midi.sla --test-backend sa --jobs 1 --trace-panic --filter "music ir writes smf1 through midi ir"` passed 1/1.
- `SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test src/midi.sla --test-backend sab --jobs 1 --trace-panic --filter "smf1 decompiles into normalized sla source"` passed 1/1.
- `SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test src/midi.sla --test-backend sab --jobs 1 --trace-panic --filter "midi import any detects smf clip and raw ump containers"` passed 1/1.

This narrows the remaining open issue019 surface to the broader historical
growth scenario rather than the specific parser/lower/import probes above.
