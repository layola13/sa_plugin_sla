# 234 Mod Unused Import Lint

This slot keeps unused-import diagnostics observable as one imported symbol left unreferenced.

- `main.rs`: Rust reference for one imported symbol left unreferenced.
- `main.sla`: Sla companion for one imported symbol left unreferenced.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/234_mod_unused_import_lint/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/234_mod_unused_import_lint/main.sla --out /tmp/234_mod_unused_import_lint.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/234_mod_unused_import_lint/main.sla
```
