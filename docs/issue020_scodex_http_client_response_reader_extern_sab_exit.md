# issue020: scodex http-client response-reader extern exits direct SAB without diagnostics

Status: fixed/current-non-repro on 2026-07-17; covered by issue031/issue016 scodex revalidation

## Context

While adding the next `scodex` Responses HTTP body-reader slice, a direct
wrapper around the installed `http-client` response-reader ABI caused direct
SAB execution and workspace build to exit with status 1 and no diagnostics.

The failing wrapper called this ABI sequence from
`packages/scodex-runtime/src/http_client_adapter.sla`:

- `sa_http_client_resp_status(resp)`
- `sa_http_client_resp_get_header(resp, &key, key_len, &out_val, &out_len)`
- conditionally `sa_http_client_resp_body_reader(resp, &reader)`
- conditionally `sa_http_client_body_reader_free(reader)`

The repro used a null response pointer fixture so the plugin should fail
closed rather than read network data or block.

## Commands

From `/home/vscode/projects/sla_codex`:

```sh
timeout 180s env SA_PLUGIN_DEV=1 sa sla test packages/scodex-runtime/src/http_client_adapter.sla --test-backend sab --trace-panic
timeout 180s env SA_PLUGIN_DEV=1 sa sla test packages/scodex-cli/src/main.sla --test-backend sab --trace-panic
timeout 180s env SA_PLUGIN_DEV=1 sa sla build-workspace -p scodex-cli -o /tmp/scodex
```

Observed result for each failing command:

```text
exit code 1, no stderr/stdout diagnostics
```

The SA backend passed when the direct extern wrapper was present:

```text
http client adapter response reader abi fails closed without response
test result: ok
```

## Current scodex workaround

`scodex` keeps the additive response-reader ABI shape as a status/planning API
and does not directly call the response-reader externs in the regular gate.
This preserves the existing build/test gate while keeping the successful live
reader execution slice pending.

## Expected behavior

Direct SAB should either:

- compile and execute the null response fail-closed path, or
- emit a precise diagnostic identifying the unsupported extern signature or
  borrow/out-parameter lowering issue.

It should not exit 1 without diagnostics.

## Current Resolution

The historical repro paths moved from `packages/` to `crates/` in `sla_codex`.
Later revalidation recorded in issue031 and issue016 showed that the response
reader surface no longer exits without diagnostics in the tracked current gates:

- `crates/scodex-runtime/src/http_client_adapter.sla` direct SAB passed 16/16
  with the live null-response extern test enabled.
- `crates/scodex-cli/src/main.sla --filter "http response reader abi"` direct
  SAB passed 1/1.
- `crates/scodex-cli/src/main.sla` strict direct SAB passed 78/78.
- `sa sla sab workspace -p scodex-cli` and `sa sla build-workspace -p scodex-cli`
  succeeded.

No compiler source change is associated with this document closure, and no full
suite was run for this closure slice. The current `/home/vscode/projects/sla_codex`
checkout is dirty, so this update records the already-completed issue031/issue016
installed/dev evidence rather than running a fresh broad downstream aggregate.
