# issue012: scodex plugin extern calls fail direct SAB capability validation

Date: 2026-07-14
Status: fixed/current-non-repro for CapabilityMismatch

## Summary

`/home/vscode/projects/sla_codex` uses SA optional plugins through local `.sai`
contracts. The same adapter tests historically passed on the SA-text backend but
failed on direct SAB with `CapabilityMismatch`.

This blocks using plugin-backed HTTP, Deno, and Node adapters as production
direct-SAB gates for `scodex`.

## Environment

```text
sa --version: 0.0.4
mode: SA_PLUGIN_DEV=1
project: /home/vscode/projects/sla_codex
sla plugin: /home/vscode/projects/sa_plugins/sa_plugin_sla
installed plugins observed: db, http-server, tui, deno, http-client, sla, node
```

No SA/SLA rebuild or install is required to reproduce. Use the dev plugin path
selected by `SA_PLUGIN_DEV=1`.

## Repro

```sh
cd /home/vscode/projects/sla_codex

SA_PLUGIN_DEV=1 sa sla test src/runtime/node_adapter.sla \
  --test-backend sab --jobs 1 --trace-panic

SA_PLUGIN_DEV=1 sa sla test src/runtime/deno_adapter.sla \
  --test-backend sab --jobs 1 --trace-panic

SA_PLUGIN_DEV=1 sa sla test src/runtime/http_client_adapter.sla \
  --test-backend sab --jobs 1 --trace-panic
```

Known passing comparison:

```sh
SA_PLUGIN_DEV=1 sa sla test src/runtime/node_adapter.sla \
  --test-backend sa --jobs 1 --trace-panic

SA_PLUGIN_DEV=1 sa sla test src/runtime/deno_adapter.sla \
  --test-backend sa --jobs 1 --trace-panic

SA_PLUGIN_DEV=1 sa sla test src/runtime/http_client_adapter.sla \
  --test-backend sa --jobs 1 --trace-panic
```

## Actual

Direct SAB fails with:

```text
error[CapabilityMismatch]: call-site capability prefix does not match the callee contract
```

Observed for `node_adapter.sla` and `deno_adapter.sla` at SAB line 23, and for
`http_client_adapter.sla` under the same plugin extern pattern.

## Expected

Direct SAB should preserve the plugin extern contract capability metadata for
calls imported from local `.sai` files and accept the same calls that SA-text
accepts.

## Root Cause

The direct SAB path preserves `.sai` extern parameter capability metadata in the
generated extern declaration, but it dropped the borrow prefix at the call site.

Example from the failing `node_adapter.sla` direct SAB disassembly:

```text
@extern sa_node_plugin_process_pid(&out_pid: ptr) -> u32
call r12,"@sa_node_plugin_process_pid","tmp_3"
```

The corresponding SA-text lowering emits a borrow-prefixed operand for the same
source shape:

```text
tmp_5 = call @sa_node_plugin_process_pid(&&tmp_4)
```

The verifier is therefore correct to report `CapabilityMismatch`: the callee
expects a borrow-capability argument, while the direct SAB call operand is
unprefixed.

## Source Fix Candidate

Updated:

```text
/home/vscode/projects/sa_plugins/sa_plugin_sla/src/sab_codegen.zig
```

The direct SAB planned-call lowering now preserves an explicit borrow operand
prefix for `.sai` extern borrow parameters. Focused source-level tests were
added for:

- contract extern parameter cap preservation;
- borrow call operand prefix insertion without double-prefixing.

Verification run from the compiler plugin source tree:

```sh
zig fmt --check src/sab_codegen.zig
zig build test -Dtest-filter="direct sab extern" --summary all
```

Result:

```text
Build Summary: 4/4 steps succeeded; 2/2 tests passed
```

`SA_PLUGIN_DEV=1 sa sla help` confirms the current dev command surface, but the
installed `sla/current` entry contains a prebuilt `libsla.so`, not a source
symlink. No `sa plugin install --dev .` or compiler rebuild was run during this
scodex pass, per user direction. Therefore the acceptance gate below still
requires refreshing the dev plugin binary before it can pass through `sa sla`.

## Impact

`scodex` can continue modeling protocol, CLI, config, and tool-loop logic in
SAB. The direct-SAB capability-prefix compiler issue is fixed; any remaining
plugin adapter runtime ABI failure should be tracked separately from this
capability metadata issue.

Temporary SA-text adapter tests are useful diagnostics only. They should not be
treated as final production acceptance for `scodex exec`.

## 2026-07-14 Follow-up

After rebuilding and refreshing the dev plugin:

```sh
cd /home/vscode/projects/sa_plugins/sa_plugin_sla
zig build test -j1 -Dtest-filter="direct sab extern" --summary all
SA_PLUGIN_DEV=1 sa plugin install --dev .
SA_PLUGIN_DEV=1 sa sla help
```

The focused source tests pass 2/2 and the installed command surface is refreshed.
`/home/vscode/projects/sla_codex` has moved the repro files to:

- `packages/scodex-runtime/src/node_adapter.sla`
- `packages/scodex-runtime/src/deno_adapter.sla`
- `packages/scodex-runtime/src/http_client_adapter.sla`

All three compile to SAB successfully. Disassembly proves the original
CapabilityMismatch root cause is fixed:

```text
call r12,"@sa_node_plugin_process_pid","&tmp_3"
call r15,"@sa_node_plugin_process_ppid","&tmp_4"
call r85,"@sa_node_plugin_process_argv_json","&tmp_25, &tmp_26"
call r36,"@sa_deno_plugin_now_ms","&tmp_16"
call r39,"@sa_deno_plugin_now_ns","&tmp_17"
call r139,"@sa_http_client_new","tmp_55, &tmp_53"
```

The follow-on acceptance gap was no longer verifier `CapabilityMismatch`:
running `sa test` on the generated SAB files exited with RC 139 / segmentation
fault for node, deno, and http-client adapters. Treat that historical result as
a separate runtime/plugin ABI issue; do not reopen this capability-prefix issue
unless a disassembly again shows an unprefixed call operand for a borrow extern
param.

## 2026-07-17 Reconciliation

Later scodex revalidation recorded in issue031/issue016 shows that the current
HTTP client adapter direct-SAB gate now passes:

- `crates/scodex-runtime/src/http_client_adapter.sla` direct SAB passed 16/16.
- `crates/scodex-cli/src/main.sla --filter "http response reader abi"` direct
  SAB passed 1/1.
- `crates/scodex-cli/src/main.sla` strict direct SAB passed 78/78.

No fresh node/deno adapter rerun was used for this reconciliation because the
current `/home/vscode/projects/sla_codex` checkout is dirty. This issue remains
closed for the compiler-owned CapabilityMismatch root cause; node/deno runtime
adapter behavior should be verified under a separate clean downstream slice if
it becomes a release gate again.
