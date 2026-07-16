# issue032: sla_tsgo emit_js_emit_enum fails SA verification with PhiStateConflict

Date: 2026-07-16

## Summary

After issue027's imported-macro type recovery and assigned aggregate alias
load fixes, the SA backend reaches a separate control-flow verifier failure in
`sla_tsgo`:

```text
error[PhiStateConflict]: incoming control-flow states do not agree
  in function @sla__emit_js_emit_enum(...)
  line 133258 (expanded 88850): jmp L_WHILE_HEAD_6310
  register: c
  expected Untracked, actual Consumed
```

The source function is:

```text
/home/vscode/projects/mnt/sla_tsgo/members/emitter/src/emitter.sla:539
fn emit_js_emit_enum(...)
```

## Repro

From `/home/vscode/projects/mnt/sla_tsgo` after installing the current plugin
in dev mode:

```sh
SA_PLUGIN_DEV=1 sa sla test tests/test_compile_ts_to_js_text_contract.sla \
  --test-backend sa --jobs 1 --trace-panic
```

## Current Assessment

This is not the issue027 imported-macro argument type failure. The generated
SA reaches verifier control-flow state merging, where loop backedges disagree
about whether register `c` is consumed. The likely compiler surface is
SA-text loop-body cleanup or binding-state restoration around a conditional
path inside `emit_js_emit_enum`.

## Required Closure

- Add a focused plugin fixture that reproduces the consumed-vs-untracked loop
  backedge state without importing the full downstream compiler.
- Fix the shared lifecycle/control-flow decision when possible; keep concrete
  SA register emission in `src/codegen.zig`.
- Verify only the focused fixture and the downstream
  `test_compile_ts_to_js_text_contract.sla` SA backend serially.
- Do not run a full unit or Zig test suite for this issue.
