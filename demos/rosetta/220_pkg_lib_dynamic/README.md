# 220 Pkg Lib Dynamic

This slot keeps library output selection observable as both static and dynamic artifacts.

- `main.rs`: Rust reference for static and dynamic library outputs.
- `main.sla`: Sla companion for static and dynamic library outputs.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/220_pkg_lib_dynamic/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/220_pkg_lib_dynamic/main.sla --out /tmp/220_pkg_lib_dynamic.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/220_pkg_lib_dynamic/main.sla
```
