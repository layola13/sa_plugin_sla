# 235 Mod Transitive Dependency

This slot keeps transitive module reachability observable as one leaf export propagated through an intermediate module.

- `main.rs`: Rust reference for a leaf export propagated through an intermediate module.
- `main.sla`: Sla companion for a leaf export propagated through an intermediate module.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/235_mod_transitive_dependency/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/235_mod_transitive_dependency/main.sla --out /tmp/235_mod_transitive_dependency.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/235_mod_transitive_dependency/main.sla
```
