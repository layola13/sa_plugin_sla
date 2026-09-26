# issue042: stack_alloc constant expression size falls back to 16

Status: fixed

## Symptom

SLA source that passes a constant expression into `stack_alloc` can be compiled
with the wrong allocation size:

```sla
const ARG_SIZE: int = 16;
const ARG_COUNT: int = 4;

fn make_argv() -> ptr {
    let argv = stack_alloc(ARG_SIZE * ARG_COUNT);
    return argv;
}
```

Expected generated SA:

```text
argv = stack_alloc 64
```

Observed before the fix:

```text
argv = stack_alloc 16
```

This can under-allocate stack memory and later crash at runtime when the caller
writes past the first 16 bytes.

## Cause

The SA-text codegen helper only read integer literal arguments:

```zig
stack_alloc(64)
```

Any identifier, alias, or binary expression fell through to the default size
`16`, even when top-level scalar constants had already been folded elsewhere in
codegen. The direct SAB backend had the same literal-only helper.

## Fix

`src/lowering_rules.zig` now owns shared integer constant-expression evaluation
for `stack_alloc` arguments, and both codegen backends consume that helper:

- integer literals
- scalar const identifiers and aliases
- casts around integer constants
- integer binary operators used by the existing scalar const folder

Unsupported or omitted sizes keep the existing default of `16`.

## Verification

- `zig fmt --check src/lowering_rules.zig src/codegen.zig src/sab_codegen.zig`
- `zig test src/lowering_rules.zig --test-filter "shared integer constant expression value resolves aliases and arithmetic"` 1/1
- `zig test src/codegen.zig --test-filter "stack_alloc uses integer constant expression size"` 1/1
- `zig build test -j1 -Dtest-filter="direct sab stack_alloc uses integer constant expression size" --summary all` 2/2
- `zig build -j1 --summary all` 7/7
- `SA_PLUGIN_DEV=1 sa plugin install --dev .`
- `SA_PLUGIN_DEV=1 sa sla help`

No full test suite was run.
