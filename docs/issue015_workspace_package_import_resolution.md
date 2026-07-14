# issue015: workspace package-name imports are not resolved by SLA import expansion

Date: 2026-07-14
Status: source fix added; installed dev check passes; build-workspace acceptance pending

## Summary

`/home/vscode/projects/sla_codex` is organized as an SLA workspace with
crate-like members such as `scodex-protocol`, `scodex-runtime`, and
`scodex-cli`.

Cross-member imports should be able to use package names:

```sla
@import "scodex-protocol/src/protocol.sla"
@import "scodex-runtime/src/capabilities.sla"
```

Before this fix, the import resolver only handled std imports, paths relative to
the importing file, and paths relative to cwd. Package-name imports failed with
`error.FileNotFound`, which forced brittle paths such as
`../../scodex-protocol/...` or workspace-root paths such as
`packages/scodex-protocol/...`.

## Environment

```text
sa --version: 0.0.4
mode: SA_PLUGIN_DEV=1
project: /home/vscode/projects/sla_codex
sla plugin source: /home/vscode/projects/sa_plugins/sa_plugin_sla
```

Installed plugins observed:

```text
db, http-server, tui, deno, http-client, sla, node
```

## Repro

```sh
cd /home/vscode/projects/sla_codex
SA_PLUGIN_DEV=1 sa sla check -p scodex-cli
```

With package-name imports in `packages/scodex-cli/src/main.sla`, the currently
installed `sa sla` command reports:

```text
Import Error: failed to expand @import SLA sources: error.FileNotFound
```

## Expected

When an import path is neither absolute, relative, globbed, nor a std import,
the first path segment should be treated as a workspace package-name candidate.
If it matches a member manifest package name, the remaining path should resolve
inside that member root.

Example:

```text
base:   /workspace/packages/scodex-cli/src
import: scodex-protocol/src/protocol.sla
target: /workspace/packages/scodex-protocol/src/protocol.sla
```

The `ResolvedImport.output_path` should preserve the package import string so
generated output remains stable and independent of the local checkout path.

## Source Fix

Updated:

```text
/home/vscode/projects/sa_plugins/sa_plugin_sla/src/plugin_imports.zig
```

The import resolver now:

- skips std, absolute, explicit relative, and glob imports;
- resolves the nearest workspace from the importing file directory;
- loads workspace members from `sa.mod`;
- matches the first import segment against each member `package_name`;
- reads the import from the matched member root while preserving the original
  package-name output path.

The same change also fixed a small leak in `readImportFromRoot`, exposed by the
new resolver test.

## Verification

Compiler source test:

```sh
cd /home/vscode/projects/sa_plugins/sa_plugin_sla
zig fmt --check src/plugin_imports.zig
zig build test -Dtest-filter="resolve import by workspace package name"
```

Result:

```text
2/2 tests passed
```

`scodex` checked and built with the source-built local CLI, without installing
or refreshing the system SLA plugin:

```sh
cd /home/vscode/projects/sla_codex
/home/vscode/projects/sa_plugins/sa_plugin_sla/.zig-cache/o/46a6f502a29f8c5d420aa2da1334926f/sla-local-cli sla check -p scodex-cli
/home/vscode/projects/sa_plugins/sa_plugin_sla/.zig-cache/o/46a6f502a29f8c5d420aa2da1334926f/sla-local-cli sla build-workspace -p scodex-cli -o /tmp/scodex
/tmp/scodex
tools/verify_no_rust.sh
```

Result:

```text
Sla Compiler: Successfully parsed and verified syntax and types of /home/vscode/projects/sla_codex/packages/scodex-cli/src/main.sla.
scodex: SLA-native bootstrap ok
scodex no-rust gate ok
```

## Acceptance Gate

After the dev plugin binary is refreshed, this should pass through the normal
dev command:

```sh
cd /home/vscode/projects/sla_codex
SA_PLUGIN_DEV=1 sa sla check -p scodex-cli
SA_PLUGIN_DEV=1 sa sla build-workspace -p scodex-cli -o /tmp/scodex
/tmp/scodex
```

## 2026-07-14 Follow-up

The dev plugin was refreshed and the package-name import resolver source test
was rerun:

```sh
cd /home/vscode/projects/sa_plugins/sa_plugin_sla
zig build test -j1 -Dtest-filter="resolve import by workspace package name" --summary all
SA_PLUGIN_DEV=1 sa plugin install --dev .
SA_PLUGIN_DEV=1 sa sla help
```

Result: source filter passed 2/2 and the installed command surface refreshed.

The normal dev command now accepts the `scodex-cli` workspace package:

```sh
cd /home/vscode/projects/sla_codex
SA_PLUGIN_DEV=1 sa sla check -p scodex-cli
```

Result:

```text
Sla Compiler: Successfully parsed and verified syntax and types of /home/vscode/projects/sla_codex/packages/scodex-cli/src/main.sla.
```

`build-workspace -p scodex-cli` remains pending because an external
`sla_tsgo` `sa sla test` scan was occupying the test/build queue during this
verification slice.
