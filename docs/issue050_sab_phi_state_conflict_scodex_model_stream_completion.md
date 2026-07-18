# issue050: SAB backend PhiStateConflict in stream completion aggregate test

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
