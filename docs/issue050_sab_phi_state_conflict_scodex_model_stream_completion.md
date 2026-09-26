# issue050: SAB backend PhiStateConflict in stream completion aggregate test

Status: fixed/verified on 2026-07-18.

The direct-SAB failure was traced to imported macro address-slot lowering in
`http_client_sse_external_responses_reader_chunk_status`, not to the stream
completion aggregate itself. A branch-local `STR_PTR("application/json")`
borrow temporary was stored into a stack slot for an imported macro `&%value`
argument, but no SAB-visible consume marker was emitted, so the branch merge
observed `tmp_429` as `Composite` on the then path and `Uninitialized` on the
else path. Direct SAB now emits a visible `move_` for raw pointer borrow temps
stored into borrowed stack slots or imported macro materialized slots, while
not moving stack-allocated string slice values.

Focused verification passed serially with no full suite:

```sh
zig fmt --check src/sab_codegen.zig
zig build -j1 --summary all
./zig-out/bin/sla-local-cli sla test tests/test_unit_stream_completion_aggregate_phi_direct.sla --test-backend sab --jobs 1 --trace-panic
./zig-out/bin/sla-local-cli sla test tests/test_unit_stream_completion_aggregate_phi_direct.sla --test-backend sa --jobs 1 --trace-panic
timeout 120s ./zig-out/bin/sla-local-cli sla test /home/vscode/projects/sla_codex/crates/scodex-model/src/responses_live.sla --filter 'responses live external api stream completion requires eof cleanup and db commit' --test-backend sab --jobs 1 --trace-panic
```

## Summary

`scodex-model/src/responses_live.sla` passes the SA test backend, but the SAB
test backend reports `PhiStateConflict` after adding a test that invokes the
external stream completion aggregate. The source-level test location is not
provided by the generated `.sab` diagnostic.

## Reproduction

```sh
cd /home/vscode/projects/sla_codex
SA_PLUGIN_DEV=1 SA_PLUGINS_PATH="..." \
  sa sla test crates/scodex-model/src/responses_live.sla --test-backend sab
```

## Observed

```text
error[PhiStateConflict]: incoming control-flow states do not agree
register: tmp_668
expected Uninitialized, actual Composite
source_line: 0
```

The same source passes the SA backend with the new stream completion test. The
test uses ordinary struct field assertions and does not alter public
JSON/status types.

## Expected

SAB should either execute the test like SA or report a stable source-level
location and owning function for the conflicting register.
