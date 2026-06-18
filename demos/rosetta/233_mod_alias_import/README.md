# 233 Mod Alias Import

This slot keeps import aliasing observable as one service surface reached through an alternate module name.

- `main.rs`: Rust reference for reaching one service through an alias import.
- `main.sla`: Sla companion for reaching one service through an alias import.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/233_mod_alias_import/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/233_mod_alias_import/main.sla --out /tmp/233_mod_alias_import.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/233_mod_alias_import/main.sla
```
