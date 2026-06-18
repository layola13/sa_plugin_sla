# 204 Pkg Dependencies Registry

This slot keeps registry dependency selection observable as one resolved package from the shared registry.

- `main.rs`: Rust reference for one resolved registry package.
- `main.sla`: Sla companion for one resolved registry package.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/204_pkg_dependencies_registry/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/204_pkg_dependencies_registry/main.sla --out /tmp/204_pkg_dependencies_registry.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/204_pkg_dependencies_registry/main.sla
```
