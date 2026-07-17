# issue047: SLA music source-aware chord grouping trips SA-text move-state verifier

Status: fixed.

While extending `sla_music_cli` normalized SLA output, a source-aware chord
grouping variant in `music_ir_write_normalized_sla_ex` triggered SA-text
verification failures when the code inspected `ir.notes[chord_i].hook_span`
inside a chord-writing loop.

The implementation was temporarily changed to avoid this source-aware
hook-span grouping shape and keep the music fallback gate passing. Source-less
chord grouping could continue, but source-aware chord grouping with hook-span
inspection exposed a compiler/codegen blocker.

Observed command:

```sh
cd /home/vscode/projects/sla_music_cli
SA_PLUGIN_DEV=1 sa sla test src/music_lower.sla --test-backend sa --jobs 1 --trace-panic
```

Observed failures from the attempted source-aware implementation:

```text
error[UseAfterMove]: moved value is no longer usable
  in function @sla__music_ir_write_normalized_sla_ex(&ir: ptr, &source: ptr, u
  line 103890 (expanded 58400):     tmp_19633 = ptr_add tmp_19597, 80
  register: tmp_19597
  state: expected Consumed, actual Consumed
```

After narrowing the implementation, a related shape still failed:

```text
error[PhiStateConflict]: incoming control-flow states do not agree
  in function @sla__music_ir_write_normalized_sla_ex(&ir: ptr, &source: ptr, u
  line 103901 (expanded 58408):     jmp L_MERGE_4468
  register: tmp_19597
  state: expected Active, actual Consumed
```

The failing source shape repeatedly projects or borrows nested scalar fields
from a `Vec<MusicIrNote>` element around conditionals and helper calls:

```sla
let chord_note = ir.notes[chord_i];
if use_source_names == true {
    let track_hook = ir.tracks[t].hook_span;
    if music_sla_span_is_ident(source, &chord_note.hook_span) == true {
        if chord_note.hook_span.start != track_hook.start { ... };
        if chord_note.hook_span.end != track_hook.end { ... };
        music_sla_push_note_hook(&out, source, &chord_note.hook_span);
    };
};
```

Expected behavior:

- SA-text should keep consistent move states for the projected `Vec` element
  value across the conditional paths.
- Repeated scalar field projections and borrowed helper calls against
  `chord_note.hook_span` should not consume the element base on only one merge
  path.

Root cause:

- SA-text repeated-let aliasing can resolve a local such as `chord_note` to a
  generated `tmp_*` register.
- Ordinary field loads already distinguished that resolved binding alias from
  a true expression temporary.
- The field-address path used for `&chord_note.hook_span` only checked the
  `tmp_*` spelling, recorded the resolved binding as a borrow source temp, and
  call-argument cleanup recursively emitted `!tmp_*`.
- Later scalar field projections, or a sibling merge path, still needed the
  same Vec element owner, producing `UseAfterMove` or `PhiStateConflict`.

Resolution:

- `src/lowering_rules.zig` now owns
  `fieldAddressProjectionTracksSourceTemp()`, matching the existing
  field-base release rule for resolved binding aliases.
- `src/codegen.zig::genFieldAddress()` uses that rule so a generated `tmp_*`
  register is tracked as a borrow source temp only when it is a true expression
  temporary, not when it is the current resolved binding for a local.
- Added `tests/test_unit_vec_index_assign.sla` coverage for source-aware
  nested span borrow/projection around branches, including the repeated-let
  alias shape that previously reproduced the move-state verifier failure.

Verification:

- `zig build test -j1 -Dtest-filter='shared lowering rules classify call materialization decisions' --summary all` 2/2.
- `zig build -j1 --summary all` 7/7.
- Local generated-SA filter
  `tests/test_unit_vec_index_assign.sla --filter "vec element nested span borrow keeps branch state"` 1/1.
- Local strict direct-SAB no-fallback for the same filter 1/1.
- Official `SA_PLUGIN_DEV=1 sa plugin install --dev .` and
  `SA_PLUGIN_DEV=1 sa sla help`.
- Installed/dev generated-SA and strict direct-SAB no-fallback for the same
  filter 1/1 each.
- No full test suite was run.

Historical workaround:

- `sla_music_cli` only groups normalized chords in the source-less path.
- Source-aware normalized output continues to serialize notes individually when
  hook/source compensation would require the unstable nested-span access shape.
