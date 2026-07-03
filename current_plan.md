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

- Latest committed baseline after this slice: async task-state runtime inspection is committed in `/home/vscode/projects/sa_plugins/sa_plugin_sla` as `942f5fc` (`Expose task state runtime surface`); async while-let future queue and pending-future task polling are committed as `bc1c29b` (`Extend async Future task runtime coverage`); SCI embedded symbol-token/call-body remap is committed in `/home/vscode/projects/sci` as `1beccde` (`Remap fragment embedded symbol text`).
- Latest completed slices (verified with dev-mode SAB no-fallback + SA-text parity where applicable): scalar and pointer-backed `struct_update`, formatted `println` direct SAB lowering, `enum_match`, `spaceship_cmp`, `for_in_protocol`, `generic_for_in_protocol`, `derive_semantics`, `vec_index_assign`/nested Vec field assignment, the ready-future async/await subset, the ready Future/task runtime surface, direct `block_on` over ready futures with fallible std-time externs, direct `while let Some(task) = queue.pop()` over a `Vec<future<T>>` queue, pending-future task polling through `future::pending::<T>()`, and `task::state(task)` runtime state inspection.
- Current full dev-mode direct SAB no-fallback sweep: 77/77 passing (added `tests/test_unit_async_task_state_runtime.sla`).
- Current global estimates: Y/shared-lowering about 98%; direct SAB fallback-removal is 100% for the tracked unit corpus, with corpus pass rate now 77/77.
- Current feature report: `async task state runtime direct SAB 100%; no-fallback sweep is 77/77; committed as 942f5fc`.
- Current SCI boundary sub-slice: embedded symbol-token/call-body remap is implemented in `/home/vscode/projects/sci/src/flattener.zig` and verified. Extern/export ordering is now closed as no-repro (stress probe + exported-helper ordering regression), and the plugin-side fragment cleanup audit concluded the plugin decode-time adapter is not a duplicate of SCI's flatten-time remap. Broader SCI boundary convergence is about 80%; full generic fragment naming remains a longer-term SCI task.
- Remaining tracked unit failures: none.

## Recently Completed Slices

- `async_task_state_runtime`: direct SAB and SA-text now expose `task::state(task)` over `Task<T>` values. Shared `TaskRuntimeCallPlan` classification lives in `src/lowering_rules.zig`; the type checker validates the argument is `Task<T>` and returns `u64`; SA-text emits `EXPAND TASK_STATE`, and SAB consumes the shared task runtime plan to emit the `TASK_STATE` macro fragment. `tests/test_unit_async_task_state_runtime.sla` covers ready-task state changing after `task::poll` and pending-task state staying not-ready.
- `async_pending_task_runtime`: direct SAB and SA-text now expose `future::pending::<T>()` as a pending future state that can be polled through the existing task runtime. Shared `FutureRuntimeCallPlan` classification lives in `src/lowering_rules.zig`; type checking accepts the flattened turbofish spelling, and both emitters consume the shared future runtime call plan to emit `FUTURE_PENDING_STATE_NEW`.
- `async_while_let_future_queue_direct`: direct SAB now lowers `while let Some(task) = queue.pop()` over `Vec<future<T>>` without fallback. Shared `WhileLetPatternPlan`/pattern classification and generic `Option`/`Result`/`Vec` helpers live in `src/lowering_rules.zig`; SAB consumes them for enum-pattern `while let`, direct `vec(...)` construction, and direct `Vec::pop()` via `sa_vec_try_pop`, with std deps preloaded for the special direct vector paths.
- `async_block_on_direct`: direct SAB now passes `future<T>` values through the shared pointer-backed ABI, and imported `.sai` contracts preserve fallible return markers (`i32!`) in direct SAB extern signatures. This lets rosetta `09_async_await` lower and run a small `block_on` over ready futures while calling the std time sleep macro without fallback.
- `println_direct`: direct SAB now treats `println` as compiler builtin print formatting instead of an ordinary static call, consuming shared `lowering_rules.planPrintlnArg` classification and emitting structured `sa_print_bytes`/`sa_fmt_*` calls. SA-text literal string `println` now uses a borrowed const label, matching the print extern contract.
- `struct_update`: direct SAB and SA-text struct literals route explicit/update fields through shared `lowering_rules.planStructLiteralField` plus the shared field transfer policy; scalar update, copy-struct deep-copy, and pointer-backed field move/deep-copy paths are complete for the tracked fixtures.
- `enum_match`: shared enum tag/payload layout lives in `src/lowering_rules.zig`; SAB `genEnumLiteral`/`genMatch` consume it.
- `spaceship_cmp`: shared numeric/Ordering helpers feed SAB `genSpaceship`.
- `for_in_protocol`: SAB `genForOverProtocol` lowers iter_len/iter_at counted loops; `TypeChecker.methodForType` is public for this path.
- `generic_for_in_protocol`: tracked generic protocol fixture now passes direct SAB no-fallback and SA-text parity.
- `derive_semantics`: tracked derive fixture now passes; `debug()` emits structured direct SAB formatting calls plus `FORMAT_PUSH_BYTES` rather than nested text macro expansion.
- `vec_index_assign` and nested Vec field/index assignment: std-surface macro fragment emission now treats `elem_ty` as a literal type token while keeping register args as placeholders, so `VEC_SET_TYPED` can flatten/encode without an invalid placeholder type.
- `async_await`: tracked ready-future async subset now passes through shared async return/await plans; async functions return pointer ABI ready-state values and `.await` consumes `FUTURE_READY_STATE_INTO_INNER`.
- `async_task_runtime`: ready futures can now flow through `future::ready`, `task::new`, `task::poll`, `task::is_ready`, and `task::result` in both SA-text and direct SAB. This covers ready-state task polling, not full async state-machine/executor lowering.
- `sci_embedded_token_remap`: SCI fragment cloning now remaps symbol tokens embedded in `.text`, `raw_text`, atomic text, and native text through the same source-symbol/remap/target-symbol table used by structured operands; `__sla_macro_arg_N` placeholders remain opaque, and string/comment text is left untouched.

## Verified Gates For Recent Slices

- `zig fmt --check src/type_checker.zig src/codegen.zig src/sab_codegen.zig` passed.
- `zig build --summary all` passed.
- `zig build test --summary all` passed 63/63.
- `sa plugin install --dev .` passed (dev plugin reinstalled from `sa_plugin_sla` dir).
- `SA_PLUGIN_DEV=1 sa sla help` passed.
- Focused dev-mode SAB no-fallback and SA-text parity passed for `tests/test_unit_struct_update.sla`, `tests/test_unit_enum_match.sla`, `tests/test_unit_spaceship_cmp.sla`, `tests/test_unit_for_in_protocol.sla`, `tests/test_unit_generic_for_in_protocol.sla`, and `tests/test_unit_derive_semantics.sla`.
- Dev-mode no-fallback regression guards passed for `tests/test_unit_sets.sla` and `/home/vscode/projects/sla_ecs/lib/parallel.sla`.
- Focused dev-mode SAB no-fallback and SA-text parity passed for `tests/test_unit_vec_index_assign.sla` and `tests/test_unit_field_compare_and_nested_len.sla`.
- Focused dev-mode SAB no-fallback and SA-text parity passed for `tests/test_unit_async_await.sla`.
- Focused dev-mode SAB no-fallback and SA-text parity passed for `tests/test_unit_async_task_runtime.sla`.
- Full dev-mode no-fallback sweep passed 73/73 after adding `tests/test_unit_println_direct.sla`.
- Formatted `println` slice passed: `zig fmt --check src/lowering_rules.zig src/sab_codegen.zig src/codegen.zig`; `zig build --summary all`; `zig build test --summary all` (64/64); local and host SAB no-fallback plus SA-text parity for `tests/test_unit_println_direct.sla`; host SAB no-fallback for rosetta `75_async_bridge`, `134_join_all_futures`, and `140_yield_now_suspend`; host `/home/vscode/projects/sla_ecs/lib/parallel.sla`; local and host full no-fallback sweeps 73/73; disasm guard clean for the print fixture, the three rosetta demos, and parallel.
- Async `block_on` ready-future slice passed: `zig fmt --check src/contract_parser.zig src/lowering_rules.zig src/sab_codegen.zig`; `zig build --summary all`; `zig build test --summary all` (65/65); focused parser/lowering Zig tests; local and host SAB no-fallback plus SA-text parity for `tests/test_unit_async_block_on_direct.sla` and rosetta `09_async_await`; host SAB no-fallback for async rosetta guards `75`, `133`, `134`, `135`, `139`, and `140`; host `/home/vscode/projects/sla_ecs/lib/parallel.sla`; local and host full no-fallback sweeps 74/74; disasm guard clean for the new fixture, rosetta `09`, and parallel, with `sa_time_sleep_ns` preserved as `i32!`; `git diff --check`.
- Async `while let` future queue slice passed: `zig fmt --check src/lowering_rules.zig src/sab_codegen.zig`; `zig build --summary all`; `zig build test --summary all` (67/67); local focused SA backend and SAB no-fallback for `tests/test_unit_async_while_let_future_queue_direct.sla`; local focused SA backend and SAB no-fallback for rosetta `136_executor_task_queue`; local SAB guard batch for async/Option/Vec regressions; `sa plugin install --dev .`; `SA_PLUGIN_DEV=1 sa sla help`; host SAB no-fallback for `tests/test_unit_async_while_let_future_queue_direct.sla`, rosetta `136_executor_task_queue`, and `/home/vscode/projects/sla_ecs/lib/parallel.sla`; local and host full no-fallback sweeps 75/75; disasm guard clean for the queue fixture, rosetta `136`, and parallel.
- Async pending-future task poll slice passed: `zig fmt --check src/lowering_rules.zig src/type_checker.zig src/codegen.zig src/sab_codegen.zig`; `zig build --summary all`; `zig build test --summary all` (68/68); local SA backend and SAB no-fallback for `tests/test_unit_async_pending_task_runtime.sla`; local async guard batch for ready task polling, async await, block_on, while-let queue, rosetta `09`, and rosetta `136`; local full no-fallback sweep 76/76; `sa plugin install --dev .`; `SA_PLUGIN_DEV=1 sa sla help`; host SAB no-fallback and SA-text parity for the pending fixture; host SAB no-fallback for `tests/test_unit_async_task_runtime.sla` and `/home/vscode/projects/sla_ecs/lib/parallel.sla`; host full no-fallback sweep 76/76; disasm guard clean for the pending fixture and parallel.
- Async task-state runtime slice passed: `zig fmt --check src/lowering_rules.zig src/type_checker.zig src/codegen.zig src/sab_codegen.zig`; `zig build --summary all`; `zig build test --summary all` (68/68); local SA backend and SAB no-fallback for `tests/test_unit_async_task_state_runtime.sla`; local async guard batch for task-state, pending task polling, ready task polling, async await, block_on, while-let queue, rosetta `09`, and rosetta `136`; local full no-fallback sweep 77/77; `sa plugin install --dev .`; `SA_PLUGIN_DEV=1 sa sla help`; host SAB no-fallback and SA-text parity for the task-state fixture; host SAB no-fallback for `/home/vscode/projects/sla_ecs/lib/parallel.sla`; host full no-fallback sweep 77/77; disasm guard clean for the task-state fixture and parallel.
- Filtered std-dep closure sub-slice passed: `appendDecodedModuleFiltered` now includes same-module direct-call dependencies in original decoded-module order and skips duplicate selected helper names. This keeps verifier-visible helper signatures/bodies coherent for std helpers such as HashSet/BTreeSet dependencies.
- SCI focused tests passed: `zig test src/flattener.zig --test-filter "frontend cache clone remaps embedded call text tokens with operands"`, `zig test src/flattener.zig --test-filter "frontend cache clone remaps instruction symbols and owned metadata"`, `zig test src/flattener.zig --test-filter "frontend cache append fragment remaps and merges end to end"`, and `zig test src/sab.zig --test-filter "disasmModule separates call target from call args"`.
- SCI `zig fmt --check src/flattener.zig` passed. SCI full `zig build test --summary all` was attempted but hit an environment/plugin-state failure in `plugin_host_smoke.test.runtime blocks privileged installed plugins outside dev mode` because a dev plugin is installed; no flattener failure was observed.
- After the SCI remap change, `sa_plugin_sla` `zig build --summary all` passed, `zig build test --summary all` passed 62/62, `sa plugin install --dev .` passed, `SA_PLUGIN_DEV=1 sa sla help` passed, focused macro/fragment guards passed, `/home/vscode/projects/sla_ecs/lib/parallel.sla` passed, full dev-mode no-fallback sweep stayed 69/69, and the parallel SAB disasm illegal-call-target guard returned no matches.

## Remaining Tracked Unit Failures

- None in `tests/test_unit_*.sla` under dev-mode direct SAB no-fallback.
- Broader hardening remains: generic SCI fragment naming and full async/Future state-machine support beyond the ready-future/task-runtime subset.

### SCI Boundary Note

The generic std-macro fragment naming problem is still a real SCI-boundary task: `flatten/encode` should eventually provide one authoritative mechanism for placeholder args, embedded hygiene-token replacement, call-body text remap, and extern/export declaration preservation. Do not keep adding plugin-side fixture hacks for that class. Plugin-side work is acceptable only where the SAB emitter is naturally more structured anyway; `debug()` now follows that rule by formatting primitive debug fields through direct structured `sa_fmt_*_into` calls plus the shared `FORMAT_PUSH_BYTES` path.

## Next Active Slice

- Just completed: direct SAB and SA-text `task::state(task)` support for task runtime state inspection. Shared task runtime call planning now classifies `task::new`, `task::poll`, `task::is_ready`, `task::result`, and `task::state`; type checking validates `Task<T>` and returns `u64`; both emitters lower state inspection through `TASK_STATE`. `tests/test_unit_async_task_state_runtime.sla` passes direct SAB no-fallback and SA-text parity.
- Next target candidates (pick per plan priority when resuming): full async/Future state-machine support beyond the ready-future/task-runtime subset, or generic SCI fragment naming if a concrete failing fixture reappears.
- Owner boundary: keep future semantics in `src/lowering_rules.zig`, shared frontend/typecheck, `sla_std/std_surface.sla_meta`, or `sa_std`; do not add fixture-specific macro string rewrites in `src/sab_codegen.zig`.
- Expected verification before the next commit remains: `zig fmt --check`, `zig build --summary all`, `zig build test --summary all`, `sa plugin install --dev .`, `SA_PLUGIN_DEV=1 sa sla help`, focused plugin guards, `/home/vscode/projects/sla_ecs/lib/parallel.sla`, full dev-mode no-fallback sweep, disasm guard for illegal visible `@func(arg)` call targets, docs sync, and `git diff --check`.
- Current progress: async task-state runtime direct SAB 100%. Verified with `zig fmt --check src/lowering_rules.zig src/type_checker.zig src/codegen.zig src/sab_codegen.zig`, `zig build --summary all`, `zig build test --summary all` (68/68), `sa plugin install --dev .`, `SA_PLUGIN_DEV=1 sa sla help`, focused local/host SAB no-fallback plus SA-text parity for `tests/test_unit_async_task_state_runtime.sla`, local async regression batch, host `/home/vscode/projects/sla_ecs/lib/parallel.sla`, local and host full no-fallback sweeps 77/77, and clean disasm guards for task-state/parallel artifacts. Broader Y/shared-lowering about 98%; direct SAB tracked-corpus fallback removal remains 100% (77/77).

## Dirty Worktree Caveat

`git status --short` was clean at the start of this slice. Continue to inspect status before staging; do not restore, delete, stage, or commit unrelated/generated changes if they appear while working.
