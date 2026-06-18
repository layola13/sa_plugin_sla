# 221 Mod Relative Import

This slot keeps relative module lookup observable as one sibling-module hop.

- `main.rs`: Rust reference for one sibling-module lookup hop.
- `main.sla`: Sla companion for one sibling-module lookup hop.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/221_mod_relative_import/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/221_mod_relative_import/main.sla --out /tmp/221_mod_relative_import.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/221_mod_relative_import/main.sla
```
