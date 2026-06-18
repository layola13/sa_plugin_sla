# 281 Ffi Link System Libc

This slot keeps system-libc linkage observable as one imported `puts`-style symbol.

- `main.rs`: Rust reference for one imported `puts`-style libc symbol.
- `main.sla`: Sla companion for one imported `puts`-style libc symbol.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/281_ffi_link_system_libc/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/281_ffi_link_system_libc/main.sla --out /tmp/281_ffi_link_system_libc.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/281_ffi_link_system_libc/main.sla
```
