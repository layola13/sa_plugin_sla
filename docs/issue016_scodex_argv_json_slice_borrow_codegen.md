# issue016: argv JSON string slice parsing hits borrow/codegen limits

Date: 2026-07-14
Status: reproduced from `scodex`, no source fix yet

## Summary

`/home/vscode/projects/sla_codex` now models CLI routing from real argv JSON:

```sla
fn cli_route_from_argv_json(data_ref: &ptr, data_len: u64, source_code: u8) -> CliRoute
```

The implementation parses a JSON array, reads argv element 1 as the command
name, and maps it to `exec`, `app-server`, `tui`, `capabilities`, `help`, and
`doctor`.

The package type-checks and the workspace builds, but executing the focused
argv JSON tests exposes backend limitations around borrowed JSON string
pointers and imported string macros.

## Environment

```text
project: /home/vscode/projects/sla_codex
compiler source: /home/vscode/projects/sa_plugins/sa_plugin_sla
mode: source-built sla-local-cli, no dev plugin install
```

## Repro

```sh
cd /home/vscode/projects/sla_codex
/home/vscode/projects/sa_plugins/sa_plugin_sla/.zig-cache/o/787cd19cd9444b68e4e13a2a80362c04/sla-local-cli \
  sla test packages/scodex-cli/src/args.sla --test-backend sab --jobs 1 --trace-panic

/home/vscode/projects/sa_plugins/sa_plugin_sla/.zig-cache/o/787cd19cd9444b68e4e13a2a80362c04/sla-local-cli \
  sla test packages/scodex-cli/src/args.sla --test-backend sa --jobs 1 --trace-panic
```

## Current Passing Comparison

```sh
cd /home/vscode/projects/sla_codex
/home/vscode/projects/sa_plugins/sa_plugin_sla/.zig-cache/o/787cd19cd9444b68e4e13a2a80362c04/sla-local-cli \
  sla check -p scodex-cli

/home/vscode/projects/sa_plugins/sa_plugin_sla/.zig-cache/o/787cd19cd9444b68e4e13a2a80362c04/sla-local-cli \
  sla build-workspace -p scodex-cli -o /tmp/scodex

/tmp/scodex
tools/verify_no_rust.sh
```

Result:

```text
Sla Compiler: Successfully parsed and verified syntax and types of /home/vscode/projects/sla_codex/packages/scodex-cli/src/main.sla.
scodex: SLA-native bootstrap ok
scodex no-rust gate ok
```

## SAB Failure

The direct SAB backend exits with `UseAfterMove` while lowering the argv JSON
string/slice path. Earlier variants reproduced the same class of problem with:

- a local `ptr` returned by `sa_json_string_ptr`;
- a temporary `*sa_json_string_ptr(command_node)` argument;
- manual byte reads through repeated `PTR_BYTE_ADD`;
- route-level double parsing of the same argv pointer.

After reducing the route to a single JSON scan and borrowed input pointer, SAB
still fails during execution of the focused tests.

## SA Backend Failure

The SA backend fails during codegen for imported macro arguments when the argv
command string is turned into a string slice and compared:

```text
Codegen Error: failed to generate SA code: error.CodegenError
src/codegen.zig:8724 in genImportedMacroArg
```

A previous attempt to use `sa_str_eq_ignore_ascii_case` instead of `STR_EQ`
avoided imported string macros but failed verification with:

```text
error[InteriorPtrEscape]: interior pointers cannot cross FFI boundaries
```

That suggests the compiler/runtime needs a stable way to compare a JSON string
node slice to a literal without treating the borrowed JSON string pointer as an
escaping FFI-owned pointer.

## Expected

The following pattern should be valid in both SA and direct SAB backends:

```sla
let root = sa_json_parse(data_ref, data_len);
let command_node = ... argv[1] ...;
let command_len = sa_json_string_len(command_node);
let command_ptr = *sa_json_string_ptr(command_node);
let command_slice = STR_FROM_PARTS(command_ptr, command_len);
return STR_EQ(command_slice, "exec");
```

Equivalent direct byte reads from a borrowed string pointer should also not
produce use-after-move cleanup traps.

## Impact

`scodex` can now type-check and build with the argv JSON route model in place,
but cannot promote argv JSON parsing to an execution gate until this backend
borrow/codegen issue is fixed.

## 2026-07-14 Update

The `scodex` side was adjusted to avoid changing the existing `sa_std`
JSON ABI. `sci/sa_std/encoding/json.sa` now adds a macro-only helper:

```sa
[MACRO] JSON_STRING_PTR %out_ptr, %node
    %out_ptr = call @sa_json_string_ptr(%node)
[END_MACRO]
```

This keeps `@extern sa_json_string_ptr(node: ptr) -> &ptr` unchanged and avoids
adding a new runtime symbol that would require rebuilding `libsa_std.a`.

With the current source-built local CLI:

```sh
cd /home/vscode/projects/sla_codex
SA_PLUGIN_DEV=1 \
SA_STD_DIR=/home/vscode/projects/sci/sa_std \
/home/vscode/projects/sa_plugins/sa_plugin_sla/.zig-cache/o/787cd19cd9444b68e4e13a2a80362c04/sla-local-cli \
  sla test packages/scodex-cli/src/args.sla --test-backend sa --jobs 1 --trace-panic
```

passes:

```text
7 passed; 0 failed; 0 skipped
```

The same file with direct SAB still exits nonzero without diagnostics:

```sh
SA_PLUGIN_DEV=1 \
SA_STD_DIR=/home/vscode/projects/sci/sa_std \
/home/vscode/projects/sa_plugins/sa_plugin_sla/.zig-cache/o/787cd19cd9444b68e4e13a2a80362c04/sla-local-cli \
  sla test packages/scodex-cli/src/args.sla --test-backend sab --jobs 1 --trace-panic
```

Observed result:

```text
exit=1
```

No trap JSON or verifier message was emitted in that run. The updated expected
compiler behavior is:

- SA-text and SAB should both support imported macro wrappers around borrowed
  JSON string pointers.
- SAB test execution should emit a diagnostic if the compiled SAB test exits
  nonzero.

## 2026-07-14 Update 2

`scodex` no longer depends on `sa_json_string_ptr` for CLI argv routing. The
current implementation in
`/home/vscode/projects/sla_codex/packages/scodex-cli/src/args.sla` uses a
conservative ASCII scanner over the original argv JSON bytes:

- count top-level JSON string values;
- take the second string as the command name;
- compare that borrowed slice to known command literals;
- return `help` when fewer than two argv strings are present.

This is intentionally a local argv snapshot compatibility layer, not a
replacement for the general JSON ABI.

Current result with the source-built local CLI:

```sh
cd /home/vscode/projects/sla_codex
SA_PLUGIN_DEV=1 \
SA_STD_DIR=/home/vscode/projects/sci/sa_std \
/home/vscode/projects/sa_plugins/sa_plugin_sla/.zig-cache/o/787cd19cd9444b68e4e13a2a80362c04/sla-local-cli \
  sla test packages/scodex-cli/src/args.sla --test-backend sa --jobs 1 --trace-panic
```

passes:

```text
7 passed; 0 failed; 0 skipped
```

The direct SAB backend still exits with code 1 and no diagnostic:

```sh
SA_PLUGIN_DEV=1 \
SA_STD_DIR=/home/vscode/projects/sci/sa_std \
/home/vscode/projects/sa_plugins/sa_plugin_sla/.zig-cache/o/787cd19cd9444b68e4e13a2a80362c04/sla-local-cli \
  sla test packages/scodex-cli/src/args.sla --test-backend sab --jobs 1 --trace-panic
```

Observed output:

```text
<empty stdout/stderr>
exit=1
```

Updated interpretation:

- The original borrowed JSON string pointer issue remains valid for general
  JSON/string ABI usage.
- `scodex` has a working SA-backend workaround for CLI argv routing.
- Direct SAB still needs either a control-flow/ptr-scan fix or at minimum a
  diagnostic when a focused test binary exits nonzero.

## 2026-07-15 Update

Current installed dev-mode `sa` still reproduces the backend split:

```sh
cd /home/vscode/projects/sla_codex
SA_PLUGIN_DEV=1 sa sla test packages/scodex-cli/src/args.sla \
  --test-backend sa --jobs 1 --trace-panic
```

passes with 8 tests after adding an additive metadata fallback test.

```sh
SA_PLUGIN_DEV=1 sa sla test packages/scodex-cli/src/args.sla \
  --test-backend sab --jobs 1 --trace-panic
```

still exits 1 with empty stdout/stderr when the pointer-based argv JSON scanner
tests are included.

`scodex` now has a route-around for direct SAB execution:

```sla
fn cli_route_from_argv_metadata(argc: u64, command_code: u8, source_code: u8, argv_json_len: u64) -> CliRoute
fn cli_argv_route_fallback_plan_codes(source_code: u8, backend_code: u8, argc: u64, command_code: u8, argv_json_len: u64, json_scan_requested: bool) -> CliArgvRouteFallbackPlan
```

The filtered SAB fallback test passes:

```sh
SA_PLUGIN_DEV=1 sa sla test packages/scodex-cli/src/args.sla \
  --test-backend sab --jobs 1 --trace-panic \
  --filter "cli routes argv metadata"
```

and top-level `packages/scodex-cli/src/main.sla` SAB coverage imports the
fallback through the workspace successfully. This does not close the compiler
issue: SAB still needs a fix for pointer JSON scanning or at least diagnostics
when the generated test exits nonzero.

## 2026-07-15 App-Server Slice Repro

The same class of direct SAB no-diagnostic exit appears outside argv JSON when
`scodex` executes app-server HTTP method/path slice classification.

Known existing repro:

```sh
cd /home/vscode/projects/sla_codex
SA_PLUGIN_DEV=1 sa sla test packages/scodex-app-server-protocol/src/protocol_v2.sla \
  --test-backend sab --trace-panic
```

Observed result:

```text
<empty stdout/stderr>
exit=1
```

While adding `http-server` accept/respond bridge planning, an additive
`from_slices` API was SA-verified:

```sh
SA_PLUGIN_DEV=1 sa sla test packages/scodex-runtime/src/http_server_adapter.sla \
  --test-backend sa --trace-panic --filter "method path slices"
SA_PLUGIN_DEV=1 sa sla test packages/scodex-model/src/app_server_turn.sla \
  --test-backend sa --trace-panic --filter "derives persistence route from slices"
SA_PLUGIN_DEV=1 sa sla test packages/scodex-cli/src/main.sla \
  --test-backend sa --trace-panic --filter "slice bridge"
```

Each focused SA test passed. The equivalent direct SAB executions exited 1 with
empty output, even after replacing the bridge-local classifier with fixed ASCII
`PTR_READ_U8` comparisons instead of `STR_FROM_PARTS`/`STR_EQ`.

`scodex` therefore keeps the slice APIs type-checked and SA-verified but does
not include those pointer/slice execution tests in the regular SAB gate yet.
This issue remains the tracking item for pointer/slice SAB execution and for
surfacing diagnostics when the generated test exits nonzero.

## 2026-07-15 Config/Auth Compatibility Repro

While adding additive Codex compatibility scanners for `~/.codex/config.toml`
and `$CODEX_HOME/auth.json` in `packages/scodex-config/src/config.sla`, the same
backend split still reproduces.

Reference crates used for the compatibility surface:

- `/home/vscode/projects/codex/codex-rs/utils/home-dir`
- `/home/vscode/projects/codex/codex-rs/config`
- `/home/vscode/projects/codex/codex-rs/login`

Passing SA-text checks:

```sh
cd /home/vscode/projects/sla_codex
SA_PLUGIN_DEV=1 sa sla test packages/scodex-config/src/config.sla \
  --test-backend sa --trace-panic
SA_PLUGIN_DEV=1 sa sla test packages/scodex-cli/src/main.sla \
  --test-backend sa --trace-panic
SA_PLUGIN_DEV=1 sa sla check -p scodex-cli
SA_PLUGIN_DEV=1 sa sla build packages/scodex-cli/src/main.sla --out /tmp/scodex.sa
```

All of the above pass. The config tests include pointer scanning via
`PTR_BYTE_ADD`, slice construction through `STR_FROM_PARTS`, and imported
`STR_PTR`/`STR_LEN` literals.

Failing direct SAB commands:

```sh
SA_PLUGIN_DEV=1 sa sla test packages/scodex-config/src/config.sla \
  --test-backend sab --trace-panic
SA_PLUGIN_DEV=1 sa sla test packages/scodex-cli/src/main.sla \
  --test-backend sab --trace-panic
SA_PLUGIN_DEV=1 sa sla sab workspace -p scodex-cli --sab-out /tmp/scodex.sab
SA_PLUGIN_DEV=1 sa sla build-workspace -p scodex-cli -o /tmp/scodex
```

Observed result for each direct SAB path:

```text
<empty stdout/stderr>
exit=1
```

This is not treated as a `scodex` test skip: SA-text coverage is kept, and this
issue remains the compiler-side tracking item for pointer/string scanning under
direct SAB plus missing diagnostics when the generated SAB path exits nonzero.

## 2026-07-15 Config/Auth File-Read Wrapper Repro

`scodex` now adds caller-path file-read wrappers around the same config/auth
scanners:

```sla
fn codex_config_toml_file_compat_scan(path_ptr: ptr, path_len: u64, max_bytes: u64) -> CodexConfigTomlFileCompatScan
fn codex_auth_json_file_compat_scan(path_ptr: ptr, path_len: u64, max_bytes: u64) -> CodexAuthJsonFileCompatScan
```

The wrappers use `sa_fs_read_to_string`, `FS_READ_BUFFER_DATA`, and
`FS_READ_BUFFER_LEN`, scan the returned buffer, then call
`sa_fs_read_buffer_free`.

Passing SA-text coverage:

```sh
cd /home/vscode/projects/sla_codex
SA_PLUGIN_DEV=1 sa sla test packages/scodex-config/src/config.sla \
  --test-backend sa --trace-panic
SA_PLUGIN_DEV=1 sa sla test packages/scodex-cli/src/main.sla \
  --test-backend sa --trace-panic
SA_PLUGIN_DEV=1 sa sla check -p scodex-cli
SA_PLUGIN_DEV=1 sa sla build packages/scodex-cli/src/main.sla --out /tmp/scodex.sa
```

The config package now has successful temp-file read tests for both
`config.toml` and `auth.json`, plus missing-file fail-closed coverage. Auth test
data is synthetic and the public result remains redacted metadata only.

Direct SAB still exits 1 with empty stdout/stderr:

```sh
SA_PLUGIN_DEV=1 sa sla test packages/scodex-config/src/config.sla \
  --test-backend sab --trace-panic
```

This keeps issue016 open for pointer/string scanner execution under direct SAB
and for the no-diagnostic failure mode.
