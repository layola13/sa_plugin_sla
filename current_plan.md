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

- Previous committed baseline before the Rc dyn trait slice: `f31051b Share loop-control scoped var cleanup`.
- Latest completed slice: Rc dyn trait coercion/dispatch through shared lowering rules.
- Current full dev-mode direct SAB no-fallback sweep: 61/69 passing.
- Current global estimates after the Rc dyn trait slice: Y/shared-lowering about 77%; direct SAB fallback-removal about 91%.
- Current feature report: `Feature: Rc dyn trait coercion/dispatch 100%; Y/shared-lowering: 75% -> 77%; direct SAB fallback-removal: 90% -> 91%; no-fallback sweep: 61/69; host gate: passed; commit: completed slice commit`.

## Completed Active Slice

- Target: `tests/test_unit_rc_dyn_trait.sla`.
- Owner phases: Phase 3 call/materialization plus Phase 4 std metadata.
- Shared contract: `src/lowering_rules.zig` owns `DynCoercionPlan` plus dyn-dispatch receiver planning for direct dyn receivers and `Rc<dyn>` receivers that must materialize an inner fat pointer.
- SA-text tail: `src/codegen.zig` consumes the shared dyn coercion and receiver plans instead of directly branching on `dyn_box_coercions`, `dyn_rc_coercions`, and Rc receiver shape at call sites.
- SAB tail: `src/sab_codegen.zig` consumes the same plans; `Rc::new(T) -> Rc<dyn Trait>` constructs a `Dyn` fat pointer before metadata-driven `RC_NEW`; `Box::new(T) -> Box<dyn Trait>` becomes a direct dyn fat pointer; `Rc<dyn>.method()` materializes the inner fat pointer through std surface `get`.
- Recursion fix: Box dyn coercion lowers the underlying Box expression without re-entering dyn coercion, avoiding the prior signal 139 recursion through `genExpr(expr)` on the same marked node.

## Verified Gates For Completed Slice

- `zig build test --summary all` passed 60/60.
- `zig build --summary all` passed.
- `sa plugin install --dev .` passed.
- `SA_PLUGIN_DEV=1 sa sla help` passed.
- `SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_rc_dyn_trait.sla --test-backend sab --jobs 1 --trace-panic` passed 3/3.
- `SA_PLUGIN_DEV=1 sa sla test tests/test_unit_rc_dyn_trait.sla --test-backend sa --jobs 1 --trace-panic` passed 3/3.
- Dev-mode no-fallback guards passed for `tests/test_unit_var_comprehensive.sla`, assignment cleanup, field assignment cleanup, `tests/test_unit_pkgjson_codegen.sla`, `tests/test_unit_refcell_struct_payload.sla`, `tests/test_unit_trait_static_dispatch.sla`, and `/home/vscode/projects/sla_ecs/lib/parallel.sla`.
- Disasm guard passed for latest `rc_dyn_trait` and `parallel.sla` artifacts: `rg 'call .*@[^" ]+\('` returned no matches.

## Remaining 61/69 Sweep Failures

- `tests/test_unit_async_await.sla`.
- `tests/test_unit_derive_semantics.sla`.
- `tests/test_unit_enum_match.sla`.
- `tests/test_unit_for_in_protocol.sla`.
- `tests/test_unit_generic_for_in_protocol.sla`.
- `tests/test_unit_sets.sla`.
- `tests/test_unit_spaceship_cmp.sla`.
- `tests/test_unit_struct_update.sla`.

## Next Active Slice

- Target: `tests/test_unit_sets.sla`.
- Owner phase: Phase 4 std surface metadata generalization.
- Initial progress: 0% until the unsupported lowering kind is reproduced and assigned to a shared metadata/rule owner.
- Boundary: Set/BTreeSet facts belong in `sla_std/std_surface.sla_meta` plus `sa_std` macros or shared std metadata rules. Do not add Set-specific type-name semantics directly in `src/sab_codegen.zig`.
- Expected verification: focused dev-mode direct SAB no-fallback, SA-text parity, completed-slice guards including `rc_dyn_trait`, full dev-mode no-fallback sweep, `sa plugin install --dev .`, `SA_PLUGIN_DEV=1 sa sla help`, `/home/vscode/projects/sla_ecs/lib/parallel.sla`, disasm guard if calls are touched, docs sync, and `git diff --check`.

## Dirty Worktree Caveat

Do not blindly restore, delete, stage, or commit unrelated/generated changes:

- `README.md` is modified.
- Generated `.test.sa` files are deleted: `tests/test_unit_rc_dyn_trait.test.sa`, `tests/test_unit_smart_pointer_struct_field_cleanup.test.sa`, and `tests/test_unit_var_comprehensive.test.sa`.
- Untracked status/docs files include `COMPLETION_STATUS.md`, `WORK_SESSION_SUMMARY.md`, and `docs/*_cn.md`.
