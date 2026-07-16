# issue038: sla_ecs scope completion aggregate helper call fails direct SAB with UseAfterMove

Date: 2026-07-16

Status: fixed

## Summary

The default/direct-SAB backend fails while compiling the focused
`sla_ecs` scope-completion tests:

```text
error[UseAfterMove]: moved value is no longer usable
register: sla__ecs_scope_completion_complete_pending_at_i32__param_0_queue
```

`sa sla check` succeeds. The same compiler defect reproduces in an older
scope-completion test, so it is not introduced by the new panic/catch cases.

## Downstream Repro

From `/home/vscode/projects/sla_ecs`:

```sh
SA_PLUGIN_DEV=1 sa sla test lib/task_scope_completion.sla \
  --filter "scope completion pending first task blocks result drain" \
  --jobs 1 --trace-panic
```

## Minimal Compiler Repro

From `/home/vscode/projects/sa_plugins/sa_plugin_sla`:

```sh
SA_PLUGIN_DEV=1 sa sla test \
  tests/test_unit_sab_stack_aggregate_shallow_copy_arg.sla \
  --test-backend sab --jobs 1 --trace-panic
```

The reduced source passes a `QueueState` containing two `Vec` fields to a
read-only helper, then reads and mutates the original aggregate afterward.
Direct SAB emits:

```text
@sla__queue_len(^sla__complete_pending__param_0_queue)
```

The move-prefixed call consumes the original parameter before its later field
loads and return.

## Root Cause

Direct-SAB call lowering can preserve a later-used plain aggregate by copying
its outer ABI slots into a temporary call argument. Its eligibility predicate
rejects any aggregate containing a standard owner such as `Vec`, even though
the standard owner occupies a pointer ABI slot inside the outer aggregate.
Lowering therefore falls back to moving the original aggregate.

The top-level standard owner must remain non-copyable. Only a plain outer
aggregate may shallow-copy a nested owner slot for a temporary by-value call.

## Resolution

- Direct SAB and SA-text now accept a nested standard-owner slot only when it
  appears inside a plain outer aggregate being shallow-copied for a preserved
  by-value call argument.
- Top-level `Vec`, `Box`, map, set, and smart-pointer values remain
  non-copyable and still require normal move/ownership handling.
- Shallow-copy emission stores nested owner slots directly instead of
  recursively copying their internals.

## Verification

Serial focused verification only; no full suite was run:

- `zig fmt src/codegen.zig src/sab_codegen.zig`.
- `git diff --check`.
- `zig build -j1 --summary all` 7/7.
- Local strict SAB
  `tests/test_unit_sab_stack_aggregate_shallow_copy_arg.sla` 1/1.
- Local SA backend for the same fixture 1/1.
- Official `SA_PLUGIN_DEV=1 sa plugin install --dev .` and
  `SA_PLUGIN_DEV=1 sa sla help`.
- Installed/dev strict SAB fixture 1/1.
- Installed/dev SA fixture 1/1.
- Downstream `/home/vscode/projects/sla_ecs/lib/task_scope_completion.sla`
  strict SAB filters 3/3:
  `scope completion pending first task blocks result drain`,
  `scope completion pending task can finish with panic`,
  `scope completion pending task can finish with failed catch`.
- The same downstream filters pass with generated-SA backend 3/3.
