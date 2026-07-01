# Current Plan

This is the short recovery point for active `sa_plugin_sla` work. Keep `tasks.md` and `progress.md` synchronized with this file before ending a slice or committing.

## Workspace Rules

- Implementation workspace: `/home/vscode/projects/sa_plugins/sa_plugin_sla`.
- Do not switch implementation or planning into `/home/vscode/projects/sla_ecs`; use `/home/vscode/projects/sla_ecs/lib/parallel.sla` only as a host regression target.
- Official CLI evidence must use dev plugin mode: run `sa plugin install --dev .`, then use `SA_PLUGIN_DEV=1 sa sla ...`.
- `./zig-out/bin/sla-local-cli` is allowed only for secondary debugging evidence.
- Preserve the Y shape: `SLA AST/typecheck -> shared frontend/lowering rules/std metadata -> {SA text emitter, direct SAB emitter}`.
- Put semantic decisions in `src/lowering_rules.zig`, shared frontend/typecheck results, `sla_std/std_surface.sla_meta`, or `sa_std`; `src/sab_codegen.zig` should consume those contracts and emit structured SAB.
- Commit only verified completed slices. Do not stage unrelated README, generated `.test.sa` deletions, or unrelated status/docs files.

## Verified State

- Latest committed baseline before this slice: `ecd9570 Share dyn trait coercion lowering`.
- Latest completed slice: Set collection std-surface metadata lowering.
- Current full dev-mode direct SAB no-fallback sweep: 62/69 passing.
- Current global estimates after the sets slice: Y/shared-lowering about 79%; direct SAB fallback-removal about 92%.
- Current feature report: `Feature: Set collection std metadata 100%; Y/shared-lowering: 77% -> 79%; direct SAB fallback-removal: 91% -> 92%; no-fallback sweep: 62/69; host gate: passed; commit: completed slice commit`.

## Completed Active Slice

- Target: `tests/test_unit_sets.sla`.
- Owner phase: Phase 4 std surface metadata generalization.
- Shared/data contract: `sla_std/std_surface.sla_meta` now describes `HashSet::new`, `BTreeSet::new`, `len(HashSet)`, `len(BTreeSet)`, `HashSet.insert`, `HashSet.contains`, `BTreeSet.insert`, and `BTreeSet.contains`, including their required `sa_std` helper dependencies.
- SAB tail: direct SAB consumes the generic std-surface associated/function/method path for set operations instead of adding Set-specific type-name branches.
- Stack slice fix: direct SAB string literals used as set keys are stack-allocated `Slice` values and now enter the existing non-owning register path so generic cleanup does not emit an illegal `release` for stack allocation.

## Verified Gates For Completed Slice

- `zig fmt --check src/sab_codegen.zig` passed.
- `zig build --summary all` passed.
- `zig build test --summary all` passed 60/60.
- `sa plugin install --dev .` passed.
- `SA_PLUGIN_DEV=1 sa sla help` passed earlier in this worktree and the dev plugin was reinstalled before focused gates.
- `SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_sets.sla --test-backend sab --jobs 1 --trace-panic` passed 2/2.
- `SA_PLUGIN_DEV=1 sa sla test tests/test_unit_sets.sla --test-backend sa --jobs 1 --trace-panic` passed 2/2.
- Dev-mode no-fallback guards passed for `tests/test_unit_rc_dyn_trait.sla`, `tests/test_unit_var_comprehensive.sla`, assignment cleanup, field assignment cleanup, `tests/test_unit_pkgjson_codegen.sla`, `tests/test_unit_refcell_struct_payload.sla`, `tests/test_unit_trait_static_dispatch.sla`, and `/home/vscode/projects/sla_ecs/lib/parallel.sla`.
- Full dev-mode no-fallback sweep passed 62/69.
- Disasm guard passed for latest `test_unit_sets` and `parallel.sla` artifacts: `rg 'call .*@[^" ]+\('` returned no matches.

## Remaining 62/69 Sweep Failures

- `tests/test_unit_async_await.sla`.
- `tests/test_unit_derive_semantics.sla`.
- `tests/test_unit_enum_match.sla`.
- `tests/test_unit_for_in_protocol.sla`.
- `tests/test_unit_generic_for_in_protocol.sla`.
- `tests/test_unit_spaceship_cmp.sla`.
- `tests/test_unit_struct_update.sla`.

## Next Active Slice

- Target: `tests/test_unit_struct_update.sla`.
- Owner phase: Phase 5 aggregate, enum, derive, and operator semantics.
- Initial progress: 0% until the unsupported lowering kind is reproduced and assigned to a shared aggregate/update owner.
- Boundary: struct update/copy/drop decisions belong in shared aggregate layout/update rules in `src/lowering_rules.zig` or shared typecheck metadata. SAB should emit structured loads/stores from the plan, not invent separate aggregate update semantics.
- Expected verification: focused dev-mode direct SAB no-fallback, SA-text parity, completed-slice guards including `sets`, full dev-mode no-fallback sweep, `sa plugin install --dev .`, `SA_PLUGIN_DEV=1 sa sla help`, `/home/vscode/projects/sla_ecs/lib/parallel.sla`, disasm guard if calls are touched, docs sync, and `git diff --check`.

## Dirty Worktree Caveat

Do not blindly restore, delete, stage, or commit unrelated/generated changes:

- `README.md` is modified.
- Generated `.test.sa` files are deleted: `tests/test_unit_rc_dyn_trait.test.sa`, `tests/test_unit_sets.test.sa`, `tests/test_unit_smart_pointer_struct_field_cleanup.test.sa`, and `tests/test_unit_var_comprehensive.test.sa`.
- Untracked status/docs files include `COMPLETION_STATUS.md`, `WORK_SESSION_SUMMARY.md`, and `docs/*_cn.md`.
