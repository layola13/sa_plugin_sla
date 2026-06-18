# 222 Mod Absolute Import

This slot keeps absolute import lookup observable as a two-segment crate-root path.

- `main.rs`: Rust reference for the two-segment crate-root path.
- `main.sla`: Sla companion for the two-segment crate-root path.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/222_mod_absolute_import/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/222_mod_absolute_import/main.sla --out /tmp/222_mod_absolute_import.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/222_mod_absolute_import/main.sla
```
