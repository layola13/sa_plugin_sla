# issue019: SLA music unrelated function growth cross-test miscompile

Date: 2026-07-14

## Status

Open.

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
