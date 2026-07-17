# issue028: strict SAB test prints ok result but outer command exits by timeout

Date: 2026-07-15

## Summary

A focused `sla_tsgo` strict SAB test can print a complete passing result, but the process does not exit before the outer `timeout` kills it, so the shell exit code is `124` even though all test assertions passed.

## Repro

From `/home/vscode/projects/mnt/sla_tsgo`:

```sh
timeout 90s env SLA_SAB_NO_FALLBACK=1 SA_PLUGIN_DEV=1 \
  sa sla test tests/test_real_ts_project_reference_flow.sla \
  --test-backend sab --jobs 1 --trace-panic
```

Observed output before timeout termination:

```text
[PASS] real project reference flow resolves declaration, emits app js, and keeps diagnostics clean
[PASS] real project reference flow redirects source and declaration parse paths
----
test result: ok. 2 passed; 0 failed; 0 skipped
```

Observed shell status: `124`.

No matching test process remained afterward.

## Impact

This makes automation treat an otherwise passing strict SAB test as failed. It also forces manual interpretation of output for focused `sla_tsgo` tests that compile slowly.

## Expected

After printing `test result: ok`, the `sa sla test ... --test-backend sab` process should exit with status `0`.

## 2026-07-17 Selection Passthrough Mitigation

Static runner analysis found a related information-loss bug in
`sa_plugin_sla`: after compiling an SLA test input to `.sab` or `.test.sa`, the
plugin removed `--filter` before invoking the child `sa test` process. That
meant the child `.sab` runner could not see explicit test selection, so SCI's
selected-test SAB path could not prune by selected tests or use its selected
test verification mode. The SLA compiler had already pruned the source test
set, but the child runner still benefits from seeing the original test
selection.

The plugin now preserves `--filter` / `--filter=...` in compiled-test
passthrough arguments while still stripping the plugin-private
`--test-backend` option. This is a mitigation for filtered strict-SAB tests
on the same runner path; it does **not** close the original unfiltered
`test_real_ts_project_reference_flow.sla` timeout by itself.

Current focused repro state: a 60s profiled rerun in the dirty
`/home/vscode/projects/mnt/sla_tsgo` checkout reached direct SAB codegen and
then timed out while the nested `sa test <generated.sab>` phase was still
running, before the pass summary. The generated SAB was about 5.2 MiB. Further
closure still needs a serial direct `sa test <generated.sab>` check after
external test processes are idle, to distinguish child-runner post-summary
linger from parent plugin cleanup.
