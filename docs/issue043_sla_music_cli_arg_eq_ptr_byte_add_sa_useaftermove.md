# issue043: SLA music `cli_arg_eq` SA backend raw pointer byte-add UseAfterMove

## Status

Open. Discovered while hardening `/home/vscode/projects/sla_music_cli` CLI
argument scanning on 2026-07-16.

## Reproduction

In `/home/vscode/projects/sla_music_cli`, a focused main-module test that calls
`music_cli_arg_is_output_flag`, which delegates to `cli_arg_eq`, fails under the
SA backend:

```sh
SA_PLUGIN_DEV=1 sa sla test src/main.sla --test-backend sa --jobs 1 --trace-panic
```

Observed trap:

```text
error[UseAfterMove]: moved value is no longer usable
  in function @sla__cli_arg_eq(&arg: ptr, lit_ptr: ptr, lit_len: u64) -> u8:
  source_text: store left_p+0, tmp_12 as ptr
  register: tmp_12
  state: expected Consumed, actual Consumed
```

Relevant source shape:

```sla
fn cli_arg_eq(arg: &CliArg, lit_ptr: ptr, lit_len: u64) -> bool {
    ...
    let left_p = PTR_BYTE_ADD(arg.ptr, i);
    let right_p = PTR_BYTE_ADD(lit_ptr, i);
    let left = PTR_READ_U8(left_p);
    let right = PTR_READ_U8(right_p);
    ...
}
```

The failing music-side test passed a `CliArg` whose pointer was backed by
`STR_PTR("-o")`, so the path exercises raw pointer byte-add temporaries and
read-only pointer comparison inside a loop.

## Expected

`PTR_BYTE_ADD` results used as read-only pointer operands for `PTR_READ_U8`
should not be double-consumed or left with a stale move state. The same helper
is used by real CLI argument parsing and should remain testable under the SA
fallback backend.

## Impact

The regular `sla_music_cli` gate does not currently run `src/main.sla` as a
test module, and `SA_PLUGIN_DEV=1 sa sla check src/main.sla` still passes.
However, this blocks focused unit coverage for CLI argument helpers and is a
general raw pointer temporary lifetime bug for SA-text generated code.

## Current workaround

The music repo keeps the CLI scan hardening in ordinary checked code but avoids
leaving a focused `src/main.sla` test that exercises the failing backend shape.
Re-enable that focused test after the compiler fix lands.
