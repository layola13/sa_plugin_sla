# 238 Mod Path Resolution Order

This slot keeps path-priority rules observable as a root item winning over a local module path in the final score.

- `main.rs`: Rust reference for root-item priority over a local module path.
- `main.sla`: Sla companion for root-item priority over a local module path.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/238_mod_path_resolution_order/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/238_mod_path_resolution_order/main.sla --out /tmp/238_mod_path_resolution_order.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/238_mod_path_resolution_order/main.sla
```
