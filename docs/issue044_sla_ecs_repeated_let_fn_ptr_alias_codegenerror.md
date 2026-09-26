# issue044: sla_ecs repeated `let` function-pointer alias fails lowering

Date: 2026-07-17

Status: fixed

## Summary

The default and generated-SA backends fail before execution while compiling
the existing `sla_ecs` parallel runner:

```text
SAB Error: failed to lower SLA through SA-compatible SAB path: error.CodegenError
```

The generated-SA path identifies the first failing monomorphized function as:

```text
ecs_parallel_task_pool_scope_run_tasks_shared_serial_i32_i32
```

## Downstream Repro

From `/home/vscode/projects/sla_ecs`:

```sh
SA_PLUGIN_DEV=1 sa sla test \
  tests/test_ecs_parallel_runner_scope_executor_isolated.sla \
  --filter "sharing scope executor ticks scope" \
  --jobs 1 --trace-panic
```

An existing regression also fails at the same lowering stage:

```sh
SA_PLUGIN_DEV=1 sa sla test tests/test_ecs_mut_parallel.sla \
  --filter "task pool scoped task set external only stays off pool" \
  --jobs 1 --trace-panic
```

## Minimal Compiler Repro

From `/home/vscode/projects/sa_plugins/sa_plugin_sla`:

```sh
./zig-out/bin/sla-local-cli sla test \
  tests/test_unit_fn_ptr_repeated_let_alias_direct.sla \
  --test-backend sa --jobs 1 --trace-panic
```

The fixture indexes function pointers from a `Vec`, binds each pointer through
`let run = runs[i]` in two loops, and invokes `run(...)`.

## Root Cause

Repeated `let` bindings are lowered through generated binding aliases. The
function-pointer call path looked up `local_binding_types` using the original
source name directly. The inferred function-pointer type was registered under
the active alias, so the lookup returned `null` and lowering emitted a bare
`CodegenError`.

The compiler already has `localBindingTypeForName`, which checks the source
name and then resolves the active binding alias. Function-pointer call
lowering must use that helper.

After that lookup was fixed, the generated-SA fixture exposed a second
lifecycle error:

```text
error[MemoryLeak]: live registers remain at function exit
register: tmp_44
state: Composite
```

The generated register holds a function-pointer vtable address passed to
`Vec.push`. The specialized `vec(...)` and `Vec.push(...)` lowering paths used
`callArgNeedsRelease`, which only sees that the source AST node is an
identifier. It therefore missed that lowering the function identifier
materialized a temporary register. These paths must use
`callArgResultTempNeedsRelease`, consistent with generic call lowering.

## Resolution

- Commit `adf98e2` resolves function-pointer call types through the alias-aware
  local binding lookup.
- Commit `e2406dc` releases generated function-pointer temporaries after
  copy-style `vec(...)` and `Vec.push(...)` insertion.
- The direct-SAB and generated-SA paths now both accept the repeated-alias
  fixture.

## Verification

- `timeout 180s zig build -j1 --summary all`: 7/7 steps succeeded, peak RSS
  about 1.14 GiB.
- Strict direct SAB minimal fixture: 1 passed / 0 failed with `--jobs 1`.
- Generated-SA minimal fixture: 1 passed / 0 failed with `--jobs 1`.
- Downstream `sla_ecs` exact regression
  `task pool scoped task set external only stays off pool`: 1 passed / 0 failed
  on both the default and generated-SA backends.
- The development plugin was reinstalled before downstream verification.
