# 284 Ffi Pkg Config Integration

This slot keeps `pkg-config` integration observable as include and library search paths.

- `main.rs`: Rust reference for include and library search paths from `pkg-config`.
- `main.sla`: Sla companion for include and library search paths.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/284_ffi_pkg_config_integration/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/284_ffi_pkg_config_integration/main.sla --out /tmp/284_ffi_pkg_config_integration.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/284_ffi_pkg_config_integration/main.sla
```
