# issue008: SA lexical cleanup re-released moved call arguments

## Summary

The generated SA backend could emit a scope cleanup for a local aggregate after
that local had already been moved into a by-value function argument.

Observed failures:

```text
UseAfterMove: !bag
UseAfterMove: !parsed_track
```

The music CLI hit this while parsing SMF1 tracks:

```sla
let parsed_track = midi_parse_smf_track(bytes, &chunk, &song);
sm_song_add_track(&song, parsed_track);
```

## Root Cause

`emitLexicalCleanupRelease` removed the local from `consumed_bindings` before
delegating to `emitRelease`. That bypassed the normal consumed-value guard and
forced `emitRelease` to generate another `!local`.

## Fix

Lexical cleanup now delegates directly to `emitRelease`. Already-consumed
locals keep their consumed marker, so `emitRelease` skips the duplicate cleanup.

## Regression

Added:

```text
tests/test_unit_move_arg_lexical_cleanup_sa.sla
```

The existing `tests/test_unit_plain_call_arg_consumes_owned_binding.sla` also
covers the same SA backend failure mode.

## 2026-07-14 Follow-up

Reverified locally after the call-argument cleanup consolidation:

```sh
./zig-out/bin/sla-local-cli sla test tests/test_unit_move_arg_lexical_cleanup_sa.sla --test-backend sa --jobs 1 --trace-panic
./zig-out/bin/sla-local-cli sla test tests/test_unit_plain_call_arg_consumes_owned_binding.sla --test-backend sa --jobs 1 --trace-panic
```

Both local SA-text gates pass.

Official dev-plugin rerun:

```sh
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_move_arg_lexical_cleanup_sa.sla --test-backend sa --jobs 1 --trace-panic
```

Result:

```text
[PASS] sa lexical cleanup skips moved call argument
test result: ok. 1 passed; 0 failed; 0 skipped
```
