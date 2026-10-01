# @slalang/sla

Sla language toolchain as a global `sla` command — no `SA_PLUGIN_DEV` needed.
Standalone binary per platform, powered by the SA compiler.

## Install

```sh
npm install -g @slalang/sla
sla --version   # sla 0.1.3
sla check main.sla
```

Installs `@salang/sa` (the SA host) automatically as a hard dependency and
exactly one platform package via `optionalDependencies`:

| Platform | Package |
|---|---|
| Linux x86_64 | `@slalang/sla-linux-x64` |
| Linux ARM64 | `@slalang/sla-linux-arm64` |
| macOS ARM64 | `@slalang/sla-darwin-arm64` |
| macOS x86_64 | `@slalang/sla-darwin-x64` |
| Windows x86_64 | `@slalang/sla-win32-x64` |
| FreeBSD x86_64 | `@slalang/sla-freebsd-x64` |

The launcher puts a directly-executable `sa` on `PATH` before running `sla`,
so `build-exe` / `build-wasm` / `test` (which shell out to the host) work
without any environment setup.

## Version sync

Follows the `@salang/sa` line (currently 0.1.3): same version, exact pins.

## Source & license

Built from https://github.com/layola13/sa_plugin_sla on top of
https://github.com/layola13/sci. Apache-2.0.
