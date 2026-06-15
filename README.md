# sa_plugin_sla

Sla compiler and tools plugin for Safe ASM (SA).

## Overview
This is the standalone Sla compiler plugin, providing Sla-to-SA compilation capabilities. It exposes the following skills and CLI commands to the host SA environment:
- `sa sla build <file>`: Compile a `.sla` source file into a verified `.sa` assembly file.
- `sa sla check <file>`: Lex, parse, and type-check a `.sla` source file without emitting final SA assembly.
- `sa sla test <file>`: Compile a `.sla` test file and run it through `sa test`.

Sla source uses compiler-managed lifetime cleanup by default. User-facing `.sla` code should not need explicit `!x;` releases; generated `.sa` may still contain `!` instructions because that is SA's ownership primitive. Sla intentionally does not add a `drop` keyword or `drop()` function.

## Standard Library Imports
Sla imports SA's top-level `sa_std` package directly:

```sla
@import "sa_std/io/print.sai"
```

The Sla compiler loads imported `.sai` and `.sal` contracts before type checking, so extern functions from imported std contracts are available to Sla code. By default it resolves `sa_std/...` from `SA_STD_DIR` when set, then from `$HOME/projects/sci/sa_std`.

## Build
To build the Sla compiler plugin:
```bash
zig build
```
This produces the plugin manifest and dynamic library:
- `zig-out/lib/sap.json`
- `zig-out/lib/libsla.so`

## Installation
Once built, the plugin can be registered into the SA environment using the package manager:
```bash
SA_PLUGIN_DEV=1 sa plugin install --dev /home/vscode/projects/sa_plugins/sa_plugin_sla
```

Run dev-plugin commands with `SA_PLUGIN_DEV=1`, for example:
```bash
SA_PLUGIN_DEV=1 sa sla check tests/test_unit_basic.sla
SA_PLUGIN_DEV=1 sa sla build tests/test_unit_basic.sla --out /tmp/test_unit_basic.sa
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_basic.sla
```

## Rosetta Demos
The `demos/rosetta` tree mirrors the Rust references under `/home/vscode/projects/sci/demos/rosetta` with Sla companions and per-demo Rust/Sla comparison notes. The demos are intended to be checked manually for semantic equivalence, not only for matching final output.

Typical commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/01_hello_world/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/01_hello_world/main.sla --out /tmp/01_hello_world.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/01_hello_world/main.sla
```
