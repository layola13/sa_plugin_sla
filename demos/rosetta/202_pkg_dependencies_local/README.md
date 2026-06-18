# 202 Pkg Dependencies Local

This slot keeps local path dependency resolution observable as a single linked local package.

- `main.rs`: Rust reference for one linked local path dependency.
- `main.sla`: Sla companion for one linked local path dependency.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/202_pkg_dependencies_local/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/202_pkg_dependencies_local/main.sla --out /tmp/202_pkg_dependencies_local.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/202_pkg_dependencies_local/main.sla
```
