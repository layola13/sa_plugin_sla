# 232 Mod Conditional Import

This slot keeps cfg-driven module selection observable as one active platform branch.

- `main.rs`: Rust reference for choosing one active platform branch.
- `main.sla`: Sla companion for choosing one active platform branch.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/232_mod_conditional_import/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/232_mod_conditional_import/main.sla --out /tmp/232_mod_conditional_import.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/232_mod_conditional_import/main.sla
```
