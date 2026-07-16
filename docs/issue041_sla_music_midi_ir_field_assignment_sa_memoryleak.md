# issue041: MidiIR field assignment leaves live register in SA-text test cleanup

Date: 2026-07-16

Status: open

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

## Required Closure

- [ ] Add a focused compiler fixture with a local struct containing a `Vec`
  field, followed by scalar field assignment and a borrowed validation call.
- [ ] Ensure generated-SA cleanup consumes/releases any temporary produced by
  the field assignment before function exit.
- [ ] Verify the focused fixture with `--test-backend sa`.
- [ ] Re-run the downstream `sla_music_cli` repro shape without the
  `midi_ir_new_ex` workaround.
