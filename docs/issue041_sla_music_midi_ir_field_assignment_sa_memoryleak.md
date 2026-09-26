# issue041: MidiIR field assignment leaves live register in SA-text test cleanup

Date: 2026-07-16

Status: fixed

## Summary

While adding SMF time-signature metadata in `sla_music_cli`, the generated-SA
backend reported a function-exit live register when a test constructed a
`MidiIR`, assigned one of its scalar metadata fields, and then validated or
wrote the value.

The music code now avoids this shape with `midi_ir_new_ex(...)`, which
initializes the scalar metadata in the returned struct literal. The original
field-assignment form is valid SLA and should not leak an active temporary at
test function exit.

## Downstream Repro Shape

From `/home/vscode/projects/sla_music_cli`, the failing source shape was:

```sla
@test "midi writers reject invalid raw midi ir meter metadata"() {
    let bad_meter = midi_ir_new(480, 500000);
    bad_meter.beats_per_measure = 65;
    if midi_ir_metadata_valid(&bad_meter) != false { panic(2746); };
}
```

The failing command was:

```sh
SA_PLUGIN_DEV=1 sa sla test src/midi.sla --test-backend sa --jobs 1 --trace-panic
```

The reported error was:

```text
error[MemoryLeak]: live registers remain at function exit
  in function @test "midi writers reject invalid raw midi ir meter metadata"()
  source_text: "    return"
  register: tmp_25494
  state: Active
```

The same failure also reproduced when the test called `midi_write_smf1_ir` or
`midi_write_smf2_ump_ir` after the scalar field assignment.

## Current Assessment

This appears to be an SA-text cleanup/lifetime issue for a local aggregate that
contains a pointer-backed field (`MidiIR.tracks: Vec<MidiIrTrack>`) after a
scalar field assignment. The temporary created around the aggregate field update
remains active until the test function return.

The issue is distinct from the music project's metadata validation behavior:
the equivalent one-shot constructor form compiles and passes.

## Fix

Fixed in `src/codegen.zig` by applying the shared
`fieldBaseResultNeedsRelease()` decision to ordinary SA-text field assignment
bases. Assigned aggregate locals with nested owner fields are stored in
assigned value slots; reading such a local for `local.scalar = value` produces a
temporary base register that must be released after the store. Resolved lexical
bindings are still kept alive by the shared field-base rule.

Added focused coverage in `tests/test_unit_field_assign_move_cleanup.sla`:
`field assign scalar on vec aggregate releases base temp`.

## Required Closure

- [x] Add a focused compiler fixture with a local struct containing a `Vec`
  field, followed by scalar field assignment and a borrowed validation call.
- [x] Ensure generated-SA cleanup consumes/releases any temporary produced by
  the field assignment before function exit.
- [x] Verify the focused fixture with `--test-backend sa`.
- [x] Re-run the downstream `sla_music_cli` related SA files. Current
  `src/midi.sla` retains the `midi_ir_new_ex` workaround for the original test,
  while `src/music_ir.sla` still contains the scalar field-assignment shape;
  both pass with the fixed compiler.

## Verification

- `zig fmt --check src/codegen.zig`
- `zig build -j1 --summary all` 7/7
- `./zig-out/bin/sla-local-cli sla test tests/test_unit_field_assign_move_cleanup.sla --test-backend sa --jobs 1 --trace-panic` 4/4
- `SA_PLUGIN_DEV=1 sa plugin install --dev .`
- `SA_PLUGIN_DEV=1 sa sla help`
- `SA_PLUGIN_DEV=1 sa sla test tests/test_unit_field_assign_move_cleanup.sla --test-backend sa --jobs 1 --trace-panic` 4/4
- From `/home/vscode/projects/sla_music_cli`:
  - `SA_PLUGIN_DEV=1 sa sla test src/midi.sla --test-backend sa --jobs 1 --trace-panic` 38/38
  - `SA_PLUGIN_DEV=1 sa sla test src/music_ir.sla --test-backend sa --jobs 1 --trace-panic` 26/26
