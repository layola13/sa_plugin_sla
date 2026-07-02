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

- Latest committed baseline after this slice: filtered std-dep closure committed in `/home/vscode/projects/sa_plugins/sa_plugin_sla` as `c26a2e2` (`Preserve filtered std dependency closure`); SCI embedded symbol-token/call-body remap committed in `/home/vscode/projects/sci` as `1beccde` (`Remap fragment embedded symbol text`).
- Latest completed slices (verified with dev-mode SAB no-fallback + SA-text parity where applicable): `struct_update`, `enum_match`, `spaceship_cmp`, `for_in_protocol`, `generic_for_in_protocol`, `derive_semantics`, `vec_index_assign`/nested Vec field assignment, and the ready-future async/await subset.
- Current full dev-mode direct SAB no-fallback sweep: 69/69 passing.
- Current global estimates: Y/shared-lowering about 92%; direct SAB fallback-removal is 100% for the tracked unit corpus, with corpus pass rate now 69/69.
- Current feature report: `async_await ready-future subset 100%; no-fallback sweep is 69/69; committed`.
- Current SCI boundary sub-slice: embedded symbol-token/call-body remap is implemented in `/home/vscode/projects/sci/src/flattener.zig` and verified. This is a completed subfeature, not full SCI boundary closure; extern/export ordering hardening and plugin-side cleanup remain open.
- Remaining tracked unit failures: none.

## Recently Completed Slices

- `struct_update`: direct SAB struct literals route explicit/update fields through `lowering_rules.planStructLiteralField`; scalar-field update is complete, pointer-backed update stays an explicit follow-up.
- `enum_match`: shared enum tag/payload layout lives in `src/lowering_rules.zig`; SAB `genEnumLiteral`/`genMatch` consume it.
- `spaceship_cmp`: shared numeric/Ordering helpers feed SAB `genSpaceship`.
- `for_in_protocol`: SAB `genForOverProtocol` lowers iter_len/iter_at counted loops; `TypeChecker.methodForType` is public for this path.
- `generic_for_in_protocol`: tracked generic protocol fixture now passes direct SAB no-fallback and SA-text parity.
- `derive_semantics`: tracked derive fixture now passes; `debug()` emits structured direct SAB formatting calls plus `FORMAT_PUSH_BYTES` rather than nested text macro expansion.
- `vec_index_assign` and nested Vec field/index assignment: std-surface macro fragment emission now treats `elem_ty` as a literal type token while keeping register args as placeholders, so `VEC_SET_TYPED` can flatten/encode without an invalid placeholder type.
- `async_await`: tracked ready-future async subset now passes through shared async return/await plans; async functions return pointer ABI ready-state values and `.await` consumes `FUTURE_READY_STATE_INTO_INNER`.
- `sci_embedded_token_remap`: SCI fragment cloning now remaps symbol tokens embedded in `.text`, `raw_text`, atomic text, and native text through the same source-symbol/remap/target-symbol table used by structured operands; `__sla_macro_arg_N` placeholders remain opaque, and string/comment text is left untouched.

## Verified Gates For Recent Slices

- `zig fmt --check src/sab_codegen.zig` passed.
- `zig build --summary all` passed.
- `zig build test --summary all` passed 62/62.
- `sa plugin install --dev .` passed (dev plugin reinstalled from `sa_plugin_sla` dir).
- `SA_PLUGIN_DEV=1 sa sla help` passed.
- Focused dev-mode SAB no-fallback and SA-text parity passed for `tests/test_unit_struct_update.sla`, `tests/test_unit_enum_match.sla`, `tests/test_unit_spaceship_cmp.sla`, `tests/test_unit_for_in_protocol.sla`, `tests/test_unit_generic_for_in_protocol.sla`, and `tests/test_unit_derive_semantics.sla`.
- Dev-mode no-fallback regression guards passed for `tests/test_unit_sets.sla` and `/home/vscode/projects/sla_ecs/lib/parallel.sla`.
- Focused dev-mode SAB no-fallback and SA-text parity passed for `tests/test_unit_vec_index_assign.sla` and `tests/test_unit_field_compare_and_nested_len.sla`.
- Focused dev-mode SAB no-fallback and SA-text parity passed for `tests/test_unit_async_await.sla`.
- Full dev-mode no-fallback sweep passed 69/69.
- Filtered std-dep closure sub-slice passed: `appendDecodedModuleFiltered` now includes same-module direct-call dependencies in original decoded-module order and skips duplicate selected helper names. This keeps verifier-visible helper signatures/bodies coherent for std helpers such as HashSet/BTreeSet dependencies.
- SCI focused tests passed: `zig test src/flattener.zig --test-filter "frontend cache clone remaps embedded call text tokens with operands"`, `zig test src/flattener.zig --test-filter "frontend cache clone remaps instruction symbols and owned metadata"`, `zig test src/flattener.zig --test-filter "frontend cache append fragment remaps and merges end to end"`, and `zig test src/sab.zig --test-filter "disasmModule separates call target from call args"`.
- SCI `zig fmt --check src/flattener.zig` passed. SCI full `zig build test --summary all` was attempted but hit an environment/plugin-state failure in `plugin_host_smoke.test.runtime blocks privileged installed plugins outside dev mode` because a dev plugin is installed; no flattener failure was observed.
- After the SCI remap change, `sa_plugin_sla` `zig build --summary all` passed, `zig build test --summary all` passed 62/62, `sa plugin install --dev .` passed, `SA_PLUGIN_DEV=1 sa sla help` passed, focused macro/fragment guards passed, `/home/vscode/projects/sla_ecs/lib/parallel.sla` passed, full dev-mode no-fallback sweep stayed 69/69, and the parallel SAB disasm illegal-call-target guard returned no matches.

## Remaining Tracked Unit Failures

- None in `tests/test_unit_*.sla` under dev-mode direct SAB no-fallback.
- Broader hardening remains: generic SCI fragment naming, pointer-backed struct-update fields, and full async/Future state-machine support beyond the ready-future subset.

### SCI Boundary Note

The generic std-macro fragment naming problem is still a real SCI-boundary task: `flatten/encode` should eventually provide one authoritative mechanism for placeholder args, embedded hygiene-token replacement, call-body text remap, and extern/export declaration preservation. Do not keep adding plugin-side fixture hacks for that class. Plugin-side work is acceptable only where the SAB emitter is naturally more structured anyway; `debug()` now follows that rule by formatting primitive debug fields through direct structured `sa_fmt_*_into` calls plus the shared `FORMAT_PUSH_BYTES` path.

## Next Active Slice

- Target: SCI extern/export declaration ordering hardening plus plugin-side fragment cleanup audit.
- Owner boundary: implement the generic fix in `/home/vscode/projects/sci` flatten/encode where token structure, register remap, call-body text, and extern/export ordering are still authoritative. Keep `sa_plugin_sla` plugin-side changes limited to docs or genuinely structured lowering; do not add fixture-specific macro string rewrites in `src/sab_codegen.zig`.
- Scope: keep imported extern/export declarations available in verifier-safe order, then audit whether `sa_plugin_sla`'s fragment text-remap/placeholder code can become a thin consumer of SCI-owned behavior instead of a parallel implementation. Embedded token/call-body remap is already completed in SCI for `appendFlattenFragment`.
- Expected verification before commit: SCI build/tests or focused flattener/SAB encode tests, `sa plugin install --dev .`, `SA_PLUGIN_DEV=1 sa sla help`, focused plugin guards (`derive_semantics`, `generic_for_in_protocol`, `vec_index_assign`, `async_await`), `/home/vscode/projects/sla_ecs/lib/parallel.sla`, full dev-mode no-fallback sweep 69/69, disasm guard for illegal visible `@func(arg)` call targets, docs sync, and `git diff --check`.
- Current progress: 55% for extern/export ordering and plugin cleanup audit. Completed sub-slice: focused filtered-std-dep closure regression added; `appendDecodedModuleFiltered` includes same-module direct-call dependencies in original declaration order and de-duplicates repeated selected helper names. Verified with `zig fmt --check src/sab_codegen.zig`, `zig build --summary all`, `zig build test --summary all` (63/63), `sa plugin install --dev .`, `SA_PLUGIN_DEV=1 sa sla help`, focused host no-fallback guards (`derive_semantics`, `generic_for_in_protocol`, `vec_index_assign`, `async_await`, `sets`, and `/home/vscode/projects/sla_ecs/lib/parallel.sla`), full host no-fallback sweep 69/69, and explicit sets/parallel SAB disasm guards with no illegal visible `@func(arg)` call targets. Completed subfeature: SCI embedded token/call-body remap 100%; broader SCI boundary convergence about 65%; existing direct SAB tracked-corpus fallback removal remains 100% (69/69); broader Y/shared-lowering is about 92%.

## Dirty Worktree Caveat

Do not blindly restore, delete, stage, or commit unrelated/generated changes:

- Generated `.test.sa` files are deleted: `tests/test_unit_enum_match.test.sa`, `tests/test_unit_field_compare_and_nested_len.test.sa`, `tests/test_unit_for_in_protocol.test.sa`, `tests/test_unit_generic_for_in_protocol.test.sa`, `tests/test_unit_spaceship_cmp.test.sa`, and `tests/test_unit_vec_index_assign.test.sa`.
- Untracked docs currently include `docs/struct_update_sab_review_cn.md`.
