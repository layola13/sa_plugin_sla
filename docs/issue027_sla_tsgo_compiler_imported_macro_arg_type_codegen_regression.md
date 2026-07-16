# issue027: sla_tsgo compiler-importing tests fail SA codegen with importedMacroArgType

Date: 2026-07-15

## Summary

`sla_tsgo` compiler-importing tests type-check and pass under strict SAB, but the SA backend fails during codegen with:

```text
Codegen Error: failed to generate SA code: error.CodegenError
.../sa_plugin_sla/src/codegen.zig:9084:53 in importedMacroArgType
return self.resolvedTypeForExpr(arg) orelse return CodegenError.CodegenError;
```

The error has no SLA source location, making it hard to isolate the source expression. The stack usually continues through `genImportedMacroArg`, `genImportedMacroCall`, and either a branch condition or a while-body expression.

## Resolution

Fixed on 2026-07-16.

Imported macro expression outputs now use the shared result-kind classifier in
`src/lowering_rules.zig`, so SA-text type recovery covers compiler helper
macros instead of relying on an incomplete emitter-local list. A second
failure exposed by the same downstream contract was an SA-text assigned
aggregate alias bug: after a shadowed/redeclared parser-state binding had been
lowered through an assigned value slot, identifier lowering returned the slot
address instead of loading the aggregate value from `slot+0`.

`src/codegen.zig` now checks `assigned_value_slots` after resolving a binding
alias and emits the typed slot load before returning the expression result.
`tests/test_unit_sa_assigned_ptr_aggregate_slot.sla` covers the
redeclared-and-reassigned parser-state return shape.

## Repro

From `/home/vscode/projects/mnt/sla_tsgo`:

```sh
SA_PLUGIN_DEV=1 sa sla check tests/test_real_ts_project_reference_flow.sla
SA_PLUGIN_DEV=1 sa sla test tests/test_compiler_contract.sla --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test tests/test_compile_ts_to_js_text_contract.sla --test-backend sa --jobs 1 --trace-panic
```

Observed:

- `sa sla check tests/test_real_ts_project_reference_flow.sla` succeeds.
- strict SAB `tests/test_compiler_contract.sla` succeeds.
- The original SA backend imported-macro type error no longer reproduces.
- `SA_PLUGIN_DEV=1 sa sla test tests/test_compiler_contract.sla --test-backend sa --jobs 1 --trace-panic`
  passes 41/41.
- `tests/test_compile_ts_to_js_text_contract.sla` now gets past imported macro
  type recovery and stops later at an independent SA-text loop-state
  `PhiStateConflict` in `emit_js_emit_enum`. That follow-up is tracked as
  `docs/issue032_sla_tsgo_emit_js_emit_enum_sa_phi_state_conflict.md`.

## Impact

This blocks using the SA backend as a secondary verifier for compiler-heavy `sla_tsgo` tests. The current project policy can continue using strict SAB, but the SA error needs a source span or a successful codegen path.

## Notes

During investigation, passing struct-field-derived path pointers through imported macro-heavy helpers such as path byte comparison and output path resolution made this error easier to trigger. The same source type-checks successfully, so the failure appears to be in backend type recovery for imported macro arguments rather than frontend typing.

Focused serial verification:

- `zig fmt --check src/codegen.zig`
- `git diff --check`
- `zig build -j1 --summary all` (7/7)
- local SA-text and strict direct-SAB
  `tests/test_unit_sa_assigned_ptr_aggregate_slot.sla` (2/2 each)
- official dev plugin install/help
- downstream `tests/test_compiler_contract.sla` SA backend (41/41)

No full test suite was run.
