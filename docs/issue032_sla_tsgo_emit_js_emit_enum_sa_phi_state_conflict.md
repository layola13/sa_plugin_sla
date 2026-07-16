# issue032: sla_tsgo emit_js_emit_enum fails SA verification with PhiStateConflict

Date: 2026-07-16

Status: fixed for the tracked `emit_js_emit_enum` Phi signature.

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

## Root Cause And Fix

`emit_js_emit_enum` declares `let c` in multiple sequential loops. SA-text
used the source name as a function-global register name, so a consumed `c`
state from an earlier lexical binding polluted a later loop whose first
incoming path expected `c` to be untracked.

Direct SAB already had a per-function repeated-`let` scanner and allocated a
fresh register for every occurrence. That scanner now lives in shared
`src/lowering_rules.zig` as `collectRepeatedLetBindings()` and is consumed by
both emitters. SA-text assigns lexical aliases to repeated `let` declarations
and records the concrete alias per AST node so natural loop-backedge cleanup
still targets the generated register after the block alias stack is popped.

`tests/test_unit_loop_body_local_cleanup.sla` now contains two sequential
loops that both declare `let c`. Before the fix it reproduced:

```text
error[PhiStateConflict]: incoming control-flow states do not agree
  register: c
  expected Untracked, actual Consumed
```

## Verification

Serial focused verification:

- `zig fmt --check src/codegen.zig src/lowering_rules.zig src/sab_codegen.zig`
- `git diff --check`
- focused shared repeated-let Zig test (1/1)
- `zig build -j1 --summary all` (7/7)
- local SA-text and strict direct-SAB fixture (2/2 each)
- official dev plugin install/help
- downstream `test_compile_ts_to_js_text_contract.sla` no longer reaches the
  `emit_js_emit_enum` `PhiStateConflict`

The downstream contract now stops later at an independent
`parse_jsx_like_expression` SA-text `UseAfterMove`, tracked as issue033. No
full test suite was run.
