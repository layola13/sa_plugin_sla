# issue036: sla_tsgo class member modifier loop fails SA with PhiStateConflict

Date: 2026-07-16

Status: open

## Summary

After the assigned aggregate field-base fix closes issue033, the
`sla_tsgo` compile-to-JS SA contract advances to:

```text
error[PhiStateConflict]: incoming control-flow states do not agree
  in function @sla__emit_js_skip_class_member_modifiers(src: ptr, src_len: i64
  line 165394 (expanded 115321): jmp L_WHILE_EXIT_9285
  register: next
  expected Active, actual Consumed
```

The conflicting paths are reported as:

```text
Path via 'L_THEN_9313': Active
Path via target 'L_WHILE_EXIT_9285': Consumed
```

The source function is:

```text
/home/vscode/projects/mnt/sla_tsgo/members/emitter/src/emitter.sla:2558
fn emit_js_skip_class_member_modifiers(src: ptr, src_len: int, start: int) -> int
```

## Repro

From `/home/vscode/projects/mnt/sla_tsgo` after installing the current plugin
in dev mode:

```sh
SA_PLUGIN_DEV=1 sa sla test tests/test_compile_ts_to_js_text_contract.sla \
  --test-backend sa --jobs 1 --trace-panic
```

## Current Assessment

The loop declares `let next = i`, conditionally reassigns `next` through a
deep keyword chain, may `break` when no modifier matches, then assigns
`i = next`. The generated SA reaches the while exit with `next` active on one
path and consumed on another. This is a scalar loop-local cleanup/control-flow
merge issue, separate from issue033's aggregate field-base lifetime.

## Required Closure

- Derive a focused compiler fixture for a loop-local scalar that is
  conditionally reassigned, read by a break condition, and used after it.
- Identify which break or natural-backedge cleanup path consumes `next`.
- Put the lifecycle/control-flow decision in shared lowering rules where
  practical, keeping SA label/register emission local to `src/codegen.zig`.
- Verify only the focused fixture and downstream compile-to-JS SA contract
  serially. Do not run a full test suite.
