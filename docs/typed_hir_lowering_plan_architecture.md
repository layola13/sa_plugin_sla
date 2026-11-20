# Typed HIR / LoweringPlan Single Source of Semantic Truth Architecture

> This is the English counterpart of the Chinese document [Typed HIR / LoweringPlan 单一语义来源架构](./typed_hir_lowering_plan_architecture_cn.md).

Status: The target architecture is confirmed and the migration is in progress. Currently `lowering_rules.zig` already hosts several shared plans, but the SA-text and direct-SAB emitters still retain high-level semantic decisions; this file is not a completion declaration.

## Final Pipeline

```text
Parser
  -> Typed HIR
  -> LoweringPlan
       -> SA debug/text serializer
       -> SAB binary serializer
```

`Typed HIR` must pin down symbol binding, concrete types, call targets, layout, and capability semantics. `LoweringPlan` must pin down argument materialization, borrow/move, temporaries, release, aggregate transfer, control-flow merging, and call-result shape. The two emitters may only allocate backend names/numbers and serialize the plan; they must not re-decide any of these semantics.

## Mandatory Invariants

- A single AST/HIR node produces only one semantic plan; SA and SAB must not independently derive ownership or ABI behavior.
- Emitters must not reclassify borrows, moves, Copy, temporaries, and releases based on local strings, register availability, or output format.
- ABI layout comes from the shared typed layout; maintaining separate field/aggregate offset decisions in the two emitters is forbidden.
- namespace/module symbol identity is resolved in Typed HIR and must not rely on the first-wins compatibility behavior of raw names after flattening.
- direct SAB maintains direct structured output and does not route through SA text as an intermediary.

## Phased Migration

1. `CallLoweringPlan`: consolidate static call targets, aliases, argument semantics, result shape, and post-call lifecycle. This round has added `StaticCallLoweringPlan` and made SA/direct-SAB share the `void` result decision; the full argument plan remains open.
2. `AggregateLoweringPlan`: unify struct/tuple/array/enum layout, field transfer, update, Copy/move/deep-copy, and cleanup.
3. `ControlFlowLoweringPlan`: unify capability state, phi cleanup, early exit, and result transfer for branch/loop/try/match.
4. `Typed HIR` persistence: the TypeChecker emits stable typed symbol/layout/call/lifecycle annotations, gradually removing the emitters' high-level semantic queries against the AST.
5. Emitter purification: establish an audit rule forbidding new semantic branches in the two emitters, and remove duplicated logic by category.

## Zeroing Out Cross-Repository Source Imports

Final acceptance requirement: the `sa_plugin_sla` build must not directly compile `src/*` from other repositories via relative or absolute paths. The current `build.zig` still references `../../sci/src/plugin_bridge.zig` directly, so this goal is not yet complete.

Migration direction: turn the SCI bridge/SAB API into a versioned standalone package or an installed SDK interface, with dependencies declared by a manifest/lockfile; `sa_plugin_sla` consumes only public APIs/libraries and versioned `sa_std` artifacts, and does not read sibling repository source code.

Acceptance search:

```bash
rg -n '\.\./\.\./[^ ]*/src|/home/vscode/projects/.*/src|root_source_file = .*\.\./' build.zig src tools
```

The expected number of cross-repository source hits is 0. If test fixtures or one-off generation tools need external inputs, they must be explicitly marked as dev-only and must not enter the plugin's normal build graph.

## Completion Criteria

- Representative paths in four categories — calls, temporaries, ownership release, and aggregate layout — are all driven by shared plans and have SA/SAB parity regressions.
- `codegen.zig` and `sab_codegen.zig` no longer contain independent classification functions or synonymous branches for the above semantics.
- The cross-repository source import search returns 0 hits, and a clean environment can build, test, and perform a dev install based solely on declared dependencies.
- The real `sla_ecs` profile, the docs issue serial gate, the official dev install/help, and the strict SAB no-fallback corpus all pass.
