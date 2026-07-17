# issue005: direct SAB did not lower switch expression statements

Status: fixed/verified for strict direct SAB switch expression statements.

## Symptom

`switch` used as a standalone statement passed normal `sa sla test` because the
SAB path could fall back, but strict direct SAB failed with:

```text
[sab-direct] stmt expr_stmt failed: UnsupportedSabDirectFeature
```

This blocked pure SLA music code that uses switch-heavy parsing/lowering style,
including `music_pitch_from_degree` and enum-based CLI dispatch.

## Root Cause

`switch_expr` is type-checked as `void` and is currently a statement-level
construct. Direct SAB `genExpr` had no `.switch_expr` lowering and `genStmt`
treated it like a generic expression statement, so strict direct SAB rejected it.

## Fix

- Added direct SAB `genSwitchStatement`.
- Supports scalar/literal equality cases and user enum variant cases.
- Handles optional trailing `default`.
- Preserves branch-local cleanup/merge state with the existing branch snapshot
  helpers used by match/if lowering.
- Routed `.switch_expr` through `genExpr` and through the expression-statement
  path without releasing the sentinel result.

## Regression

- `tests/test_unit_switch_statement_direct.sla`

## Verification

```sh
SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_unit_switch_statement_direct.sla --test-backend sab --jobs 1 --trace-panic
SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 sa sla test tests/test_unit_switch_local_scrutinee_cleanup.sla --test-backend sab --jobs 1 --trace-panic
```
