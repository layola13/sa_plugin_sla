# 231 Mod Directory Module

This slot keeps directory-backed module wiring observable as two exported routes.

- `main.rs`: Rust reference for two routes exported from a directory-backed module.
- `main.sla`: Sla companion for two routes exported from a directory-backed module.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/231_mod_directory_module/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/231_mod_directory_module/main.sla --out /tmp/231_mod_directory_module.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/231_mod_directory_module/main.sla
```
