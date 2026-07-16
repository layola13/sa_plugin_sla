# issue040: sla_music_cli music_ir strict SAB stops at UnsupportedSabDirectFeature

Date: 2026-07-16

Status: open

## Summary

While closing issue034, the original `sla_music_cli/src/music_ir.sla` generated
SA backend repro passed, and the focused compiler Vec-element field fixture
also passed under strict direct SAB. The full downstream `music_ir.sla` strict
SAB path still fails differently:

```text
SAB Direct Error: direct SLA-to-SAB lowering failed without fallback: error.UnsupportedSabDirectFeature
```

This is not the issue034 generated-SA `UseAfterMove` on a consumed Vec element
field base.

## Repro

From `/home/vscode/projects/sla_music_cli`:

```sh
SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 \
  sa sla test src/music_ir.sla --test-backend sab --jobs 1 --trace-panic
```

## Current Assessment

The focused Vec element repeated-field compiler fixture passes in strict SAB,
so the remaining downstream strict-SAB failure is a broader unsupported
lowering surface inside `music_ir.sla`.

## Required Closure

- Identify the first unsupported direct-SAB construct in `src/music_ir.sla`.
- Add a focused compiler fixture for that unsupported surface.
- Verify the focused fixture under strict direct SAB and generated SA.
- Re-run the downstream `music_ir.sla` strict SAB command.
