# issue031: scodex main direct-SAB workspace import aggregate MemoryLeak

Date: 2026-07-16

## Summary

While restoring direct `http-client` null-response fail-closed extern coverage
in `scodex`, the focused runtime SAB test and the filtered top-level CLI SAB
test pass, but the full `crates/scodex-cli/src/main.sla` direct-SAB aggregate
still fails before assertions with a verifier `MemoryLeak`.

This looks backend-owned rather than a response-reader ABI failure:

- `crates/scodex-runtime/src/http_client_adapter.sla` passes direct SAB with
  the live null-response extern test enabled.
- `crates/scodex-cli/src/main.sla --filter "http response reader abi"` passes
  direct SAB.
- The unfiltered top-level CLI aggregate fails with a live register leak.

## Repro

From `/home/vscode/projects/sla_codex`:

```sh
timeout 180s env SA_PLUGIN_DEV=1 sa sla test crates/scodex-cli/src/main.sla --test-backend sab --trace-panic
```

Observed:

```text
error[MemoryLeak]: live registers remain at function exit
  register: tmp_10000
  state: Active
{"trap":"MemoryLeak","trap_code":1012,"file":".sla-cache/sab/main-d49840f9a8d45013.sab","line":31005,"source_line":0,"column":null,"source_text":null,"original_text":null,"bad_token":null,"context":[],"register":"tmp_10000","registers":[],"expected_mask":null,"actual_mask":1,"expected_mask_name":null,"actual_mask_name":"Active","upstream_loc":null,"function":null,"is_ffi_wrapper":false,"message":"live registers remain at function exit","hint":null}
```

## Passing adjacent gates

```sh
timeout 180s env SA_PLUGIN_DEV=1 sa sla test crates/scodex-runtime/src/http_client_adapter.sla --test-backend sab --trace-panic
```

Result: `16 passed; 0 failed; 0 skipped`.

```sh
timeout 120s env SA_PLUGIN_DEV=1 sa sla test crates/scodex-cli/src/main.sla --test-backend sab --trace-panic --filter "http response reader abi"
```

Result: `1 passed; 0 failed; 0 skipped`.

```sh
timeout 180s env SA_PLUGIN_DEV=1 sa sla test crates/scodex-cli/src/main.sla --test-backend sa --trace-panic
```

Result: `59 passed; 0 failed; 0 skipped`.

## Impact

`scodex` can now execute the direct null-response fail-closed extern path in
focused SAB gates, but cannot promote the full top-level CLI direct-SAB
aggregate to a required gate until this workspace import/test aggregate leak is
diagnosed or mapped to source.
