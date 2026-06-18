# 240 Mod Entry Point Override

This slot keeps custom entry-point selection observable as one overridden startup path.

- `main.rs`: Rust reference for selecting a custom startup path.
- `main.sla`: Sla companion for selecting a custom startup path.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/240_mod_entry_point_override/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/240_mod_entry_point_override/main.sla --out /tmp/240_mod_entry_point_override.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/240_mod_entry_point_override/main.sla
```
