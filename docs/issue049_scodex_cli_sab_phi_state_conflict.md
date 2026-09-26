# issue049: scodex CLI SAB test PhiStateConflict

Status: fixed/current-non-repro for the external Responses CLI Phi family on
2026-07-18. The full 114-test CLI file was not rerun because this workstream is
limited to `docs/issue*.md` focused checks and avoids broad downstream suites.
The issue050 raw pointer imported-macro address-slot fix covers the current
known external Responses CLI shape: focused serial strict-SAB filters pass for
the single stream-completion test and the 9-test `scodex cli imports external
responses` group.

Verification used the source-built local CLI only, with no concurrent tests:

```sh
timeout 120s ./zig-out/bin/sla-local-cli sla test /home/vscode/projects/sla_codex/crates/scodex-cli/src/main.sla --filter 'scodex cli imports external responses stream completion through workspace' --test-backend sab --jobs 1 --trace-panic
timeout 120s ./zig-out/bin/sla-local-cli sla test /home/vscode/projects/sla_codex/crates/scodex-cli/src/main.sla --filter 'scodex cli imports external responses' --test-backend sab --jobs 1 --trace-panic
```

Results: 1/1 and 9/9 passed. No full CLI suite, full repo suite, or dev-plugin
install was run in this slice.

## Summary

`scodex` 的 CLI 文件在 SA 后端测试通过，但同一入口切到 SAB 后端时，
checker 在生成的 `.sab` 上报 `PhiStateConflict`，且没有可用源码定位。

## Reproduction

```sh
cd /home/vscode/projects/sla_codex
SA_PLUGIN_DEV=1 \
SA_PLUGINS_PATH="/home/vscode/.local/share/sa_plugins/installed/sla/current/libsla.so:/home/vscode/.local/share/sa_plugins/installed/db/current/libdb.so:/home/vscode/.local/share/sa_plugins/installed/http-server/current/libhttp-server.so:/home/vscode/.local/share/sa_plugins/installed/http-client/current/libhttp-client.so:/home/vscode/.local/share/sa_plugins/installed/tui/current/libtui.so:/home/vscode/.local/share/sa_plugins/installed/deno/current/libdeno.so:/home/vscode/.local/share/sa_plugins/installed/node/current/libnode.so:/home/vscode/projects/sa_plugins/sa_plugin_codex_exec/zig-out/lib/libcodex-exec.so" \
sa sla test /home/vscode/projects/sla_codex/crates/scodex-cli/src/main.sla \
  --test-backend sab --trace-panic
```

## Observed

```text
error[PhiStateConflict]: incoming control-flow states do not agree
  register: tmp_1354
  state: expected Uninitialized, actual Composite
{"trap":"PhiStateConflict","trap_code":1015,"file":".sla-cache/sab/main-85eda3adbe931771.sab","line":4280,...}
```

The generated `.sab` location is binary-like and does not include a useful
source location (`source_line: 0`). The same file passes:

```sh
SA_PLUGIN_DEV=1 SA_PLUGINS_PATH=... \
sa sla test /home/vscode/projects/sla_codex/crates/scodex-cli/src/main.sla \
  --test-backend sa --trace-panic
```

Current SA result: `114 passed; 0 failed; 0 skipped`.

## Expected

SAB backend test execution should either pass like SA, or report a stable
source-level location and owning function for the conflicting register state.

## Notes

The failure persisted after removing an early-return clean-root helper from the
latest `scodex` external Responses event append slice, so the immediate
workaround is to keep the focused verification on the SA backend and track this
as a SAB checker/codegen diagnostic gap.
