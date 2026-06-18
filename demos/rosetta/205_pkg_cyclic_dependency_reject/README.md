# 205 Pkg Cyclic Dependency Reject

This slot keeps cycle detection observable as a rejected package graph.

- `main.rs`: Rust reference for cycle detection in the package graph.
- `main.sla`: Sla companion for cycle detection in the package graph.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/205_pkg_cyclic_dependency_reject/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/205_pkg_cyclic_dependency_reject/main.sla --out /tmp/205_pkg_cyclic_dependency_reject.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/205_pkg_cyclic_dependency_reject/main.sla
```
