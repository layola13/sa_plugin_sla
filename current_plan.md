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

- Latest committed baseline before this slice: `6bcfb6d udpate`.
- Latest completed slices (verified with dev-mode SAB no-fallback + SA-text parity where applicable): `struct_update`, `enum_match`, `spaceship_cmp`, `for_in_protocol`, `generic_for_in_protocol`, `derive_semantics`, and `vec_index_assign`/nested Vec field assignment.
- Current full dev-mode direct SAB no-fallback sweep: 68/69 passing.
- Current global estimates: Y/shared-lowering about 87%; direct SAB fallback-removal about 98% by feature track, with corpus pass rate now 68/69.
- Current feature report: `vec_index_assign 100%; nested Vec field/index assignment 100%; no-fallback sweep is 68/69; only async_await remains; commit pending`.
- Remaining failure: `tests/test_unit_async_await.sla`.

## Recently Completed Slices

- `struct_update`: direct SAB struct literals route explicit/update fields through `lowering_rules.planStructLiteralField`; scalar-field update is complete, pointer-backed update stays an explicit follow-up.
- `enum_match`: shared enum tag/payload layout lives in `src/lowering_rules.zig`; SAB `genEnumLiteral`/`genMatch` consume it.
- `spaceship_cmp`: shared numeric/Ordering helpers feed SAB `genSpaceship`.
- `for_in_protocol`: SAB `genForOverProtocol` lowers iter_len/iter_at counted loops; `TypeChecker.methodForType` is public for this path.
- `generic_for_in_protocol`: tracked generic protocol fixture now passes direct SAB no-fallback and SA-text parity.
- `derive_semantics`: tracked derive fixture now passes; `debug()` emits structured direct SAB formatting calls plus `FORMAT_PUSH_BYTES` rather than nested text macro expansion.
- `vec_index_assign` and nested Vec field/index assignment: std-surface macro fragment emission now treats `elem_ty` as a literal type token while keeping register args as placeholders, so `VEC_SET_TYPED` can flatten/encode without an invalid placeholder type.

## Verified Gates For Recent Slices

- `zig fmt --check src/sab_codegen.zig` passed.
- `zig build --summary all` passed.
- `zig build test --summary all` passed 62/62.
- `sa plugin install --dev .` passed (dev plugin reinstalled from `sa_plugin_sla` dir).
- `SA_PLUGIN_DEV=1 sa sla help` passed.
- Focused dev-mode SAB no-fallback and SA-text parity passed for `tests/test_unit_struct_update.sla`, `tests/test_unit_enum_match.sla`, `tests/test_unit_spaceship_cmp.sla`, `tests/test_unit_for_in_protocol.sla`, `tests/test_unit_generic_for_in_protocol.sla`, and `tests/test_unit_derive_semantics.sla`.
- Dev-mode no-fallback regression guards passed for `tests/test_unit_sets.sla` and `/home/vscode/projects/sla_ecs/lib/parallel.sla`.
- Focused dev-mode SAB no-fallback and SA-text parity passed for `tests/test_unit_vec_index_assign.sla` and `tests/test_unit_field_compare_and_nested_len.sla`.
- Full dev-mode no-fallback sweep passed 68/69.

## Remaining 68/69 Sweep Failure

- `tests/test_unit_async_await.sla` — not started; still the last Phase 8 async/Future state-machine gap.

### SCI Boundary Note

The generic std-macro fragment naming problem is still a real SCI-boundary task: `flatten/encode` should eventually provide one authoritative mechanism for placeholder args, embedded hygiene-token replacement, call-body text remap, and extern/export declaration preservation. Do not keep adding plugin-side fixture hacks for that class. Plugin-side work is acceptable only where the SAB emitter is naturally more structured anyway; `debug()` now follows that rule by formatting primitive debug fields through direct structured `sa_fmt_*_into` calls plus the shared `FORMAT_PUSH_BYTES` path.

## Next Active Slice

- Target: `tests/test_unit_async_await.sla` direct SAB no-fallback support.
- Owner boundary: keep async/Future/task semantics in shared frontend/lowering rules and std-surface metadata. Do not add SAB-only fixture branches for the async test.
- Expected verification: focused dev-mode no-fallback and SA-text parity for async, completed-slice guards (`vec_index_assign`, nested field/index assignment, `derive_semantics`, `generic_for_in_protocol`, `enum_match`, `spaceship_cmp`, `for_in_protocol`, `struct_update`, `sets`), `/home/vscode/projects/sla_ecs/lib/parallel.sla`, `sa plugin install --dev .`, `SA_PLUGIN_DEV=1 sa sla help`, full sweep, docs sync, and `git diff --check`.

## Dirty Worktree Caveat

Do not blindly restore, delete, stage, or commit unrelated/generated changes:

- `README.md` is modified.
- Generated `.test.sa` files are deleted: `tests/test_unit_enum_match.test.sa`, `tests/test_unit_for_in_protocol.test.sa`, `tests/test_unit_generic_for_in_protocol.test.sa`, and `tests/test_unit_spaceship_cmp.test.sa`.
- Untracked docs currently include `docs/struct_update_sab_review_cn.md`.
