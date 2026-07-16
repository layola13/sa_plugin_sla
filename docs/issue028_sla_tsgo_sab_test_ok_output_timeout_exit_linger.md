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
