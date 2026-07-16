# issue036: sla_tsgo class member modifier loop fails SA with PhiStateConflict

Date: 2026-07-16

Status: fixed

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

## Resolution

The loop declares `let next = i`, conditionally reassigns `next` through a
deep keyword chain, may `break` when no modifier matches, then assigns
`i = next`. The generated SA reaches the while exit with `next` active on one
path and consumed on another. This is a scalar loop-local cleanup/control-flow
merge issue, separate from issue033's aggregate field-base lifetime.

SA-text now tracks top-level while-body `let` locals during block emission and
emits the same local cleanup on break/continue exits and natural backedges.
Primitive loop locals are emitted even when the emitter's global consumed cache
was polluted by a different branch, so SA verifier path state remains
authoritative. The older AST-scanned natural-backedge cleanup no longer releases
the same top-level `let` locals a second time; this also covers the follow-on
`check_kw` `kwb` double-release exposed after the original `next` conflict was
fixed.

## Verification

Serial focused verification only; no full suite was run:

- `zig build -j1 --summary all` 7/7.
- Local `tests/test_unit_loop_body_local_cleanup.sla` SA 4/4.
- Local strict SAB for the same file 4/4.
- `SA_PLUGIN_DEV=1 sa plugin install --dev .`.
- Official `SA_PLUGIN_DEV=1 sa sla help`.
- Installed/dev `tests/test_unit_loop_body_local_cleanup.sla` SA 4/4 and
  strict SAB 4/4.
- Downstream `/home/vscode/projects/mnt/sla_tsgo`
  `tests/test_compile_ts_to_js_text_contract.sla` SA 68/68.
