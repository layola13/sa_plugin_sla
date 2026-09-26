# issue035: sla_ecs rescan summary repeated field load fails SA with UseAfterMove

Date: 2026-07-16

Status: fixed and verified

## Summary

The generated-SA backend fails while compiling the focused
`sla_ecs` ready-batch rescan test:

```text
error[UseAfterMove]: moved value is no longer usable
  in function @sla__ecs_executor_ready_batch_rescan_summary_deep3(s: ptr, a: p
  line 46147 (expanded 10566): tmp_4387 = load tmp_3969+0 as i64
  register: tmp_3969
  state: expected Consumed, actual Consumed
```

The default backend and `sa sla check` both pass. The failure is in SLA
SA-text code generation, not the ECS scheduling behavior.

## Downstream Repro

From `/home/vscode/projects/sla_ecs`:

```sh
SLA_KEEP_TEST_SA=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_ecs_lib_executor_multi_threaded_deep_isolated.sla \
  --test-backend sa \
  --filter "mt_deep_ready_batch_rescan_records_three_skipped_slots" \
  --jobs 1 --trace-panic
```

## Minimal Compiler Repro

From `/home/vscode/projects/sa_plugins/sa_plugin_sla`:

```sh
SLA_KEEP_TEST_SA=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_unit_sa_assigned_ptr_aggregate_slot.sla \
  --test-backend sa \
  --filter "sa text repeated aggregate alias survives field read" \
  --jobs 1 --trace-panic
```

The generated minimal SA assigns a pointer-backed aggregate to `tmp_39`,
reads one field, then consumes the aggregate before a later branch reads
another field:

```sa
tmp_39 = tmp_50
tmp_51 = load tmp_39+8 as i64
!tmp_39
...
tmp_55 = load tmp_39+0 as ptr
```

The ECS output has the same shape: `tmp_3969` is the resolved local binding
for the mutable rescan summary. A field projection incorrectly treats that
temporary-looking register name as an owned expression result and emits
`!tmp_3969`; later loop iterations still need the binding.

## Root Cause

SA-text field lowering used the generated register name as an ownership
heuristic. Assigned aggregate locals can resolve to generated `tmp_*`
registers, but those registers remain local bindings and must not be released
after each field projection.

This shares the field-base lifetime root cause with issue034, while adding a
downstream loop/rescan reproducer and a small compiler fixture.

## Required Closure

- [x] Distinguish resolved local bindings from true temporary field bases.
- [x] Keep a resolved assigned aggregate binding alive across repeated field
  projections.
- [x] Pass the focused compiler generated-SA regression.
- [x] Pass the focused `sla_ecs` generated-SA regression.
- [x] Confirm the default backend remains green for the focused downstream
  test.

## Resolution

`src/lowering_rules.zig` now owns `fieldBaseResultNeedsRelease()`. The shared
rule keeps a generated `tmp_*` register alive when it is the resolved binding
for an identifier, while preserving release behavior for true temporary field
bases. `src/codegen.zig` uses the rule for tuple fields, manually dropped
struct fields, and ordinary struct fields.

Focused serial verification:

```sh
timeout 120s zig build test \
  -Dtest-filter='shared lowering rules classify call materialization decisions' \
  -j1

timeout 90s env SLA_KEEP_TEST_SA=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_unit_sa_assigned_ptr_aggregate_slot.sla \
  --test-backend sa \
  --filter "sa text repeated aggregate alias survives field read" \
  --jobs 1 --trace-panic

timeout 180s env SLA_KEEP_TEST_SA=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_ecs_lib_executor_multi_threaded_deep_isolated.sla \
  --test-backend sa \
  --filter "mt_deep_ready_batch_rescan_records_three_skipped_slots" \
  --jobs 1 --trace-panic
```

The compiler fixture and downstream ECS fixture each pass 1/1 after the
official dev plugin install. No full compiler or downstream test suite was
run for this slice.
