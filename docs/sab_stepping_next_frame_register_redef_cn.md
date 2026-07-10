# SAB RegisterRedefition Trap — schedule_stepping next_frame

## Symptom
Default/SAB backend whole-file compile of `tests/test_ecs_lib_schedule_stepping_isolated.sla` fails with `RegisterRedefinition` trap on the `ecs_stepping_deep_next_frame` function.

```
trap_code: 1006
register: lbl  (and si)
function: @sla__ecs_stepping_deep_next_frame
message: register is already live
```

The same bit also manifests as `PhiStateConflict` (trap_code 1015) for `si` when the `let si` declaration is untreated to the function top.

## Root cause
`ecs_stepping_deep_next_frame` has a)])

long update match loop with 5 independent `if u.variant == ...` branches, each with its own block-local `let lbl = u.action_or_label;` (and 3 of them with `let si = ecs_stepping_deep_state_index(...)`).

SAB treats these as function-scope register allocations and detects overlap across branches, even though they are lexically disjoint blocks.

The SA backend accepts this pattern (53 tests pass). The SAB code-gen for this specific function form breaks.

## Scope
Only `ecs_stepping_deep_next_frame` triggers. All other functions in `lib/schedule_stepping.sla` plus the 23 existing tests pass.

Attempted fix: lift `let lbl` / `let si` to the top of the function.
Actually worked for `RegisterRedefinition` but exposed `PhiStateConflict` because the top-level declaration always runs but never gets consumed on the RunAll skip path.

Reverting to block-local `let` works on SA backend.

## Workaround
- Use `--test-backend sa` for the schedule_stepping isolated suite (golden path).
- Documented here per the dev workflow. Do not fix the SA compiler.

## Files
- `/home/vscode/projects/sla_ecs/lib/schedule_stepping.sla` — ecs_stepping_deep_next_frame
