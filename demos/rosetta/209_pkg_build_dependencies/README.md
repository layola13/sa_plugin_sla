# 209 Pkg Build Dependencies

This slot keeps build-script dependency wiring observable as one build-time package.

- `main.rs`: Rust reference for a build-time dependency.
- `main.sla`: Sla companion for a build-time dependency.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/209_pkg_build_dependencies/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/209_pkg_build_dependencies/main.sla --out /tmp/209_pkg_build_dependencies.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/209_pkg_build_dependencies/main.sla
```
