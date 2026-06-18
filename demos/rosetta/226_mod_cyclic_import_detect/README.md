# 226 Mod Cyclic Import Detect

This slot keeps cyclic module import diagnostics observable as one detected cycle.

- `main.rs`: Rust reference for one detected module-import cycle.
- `main.sla`: Sla companion for one detected module-import cycle.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/226_mod_cyclic_import_detect/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/226_mod_cyclic_import_detect/main.sla --out /tmp/226_mod_cyclic_import_detect.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/226_mod_cyclic_import_detect/main.sla
```
