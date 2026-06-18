# 217 Pkg Profile Debug

This slot keeps debug profile tuning observable as debug info enabled with no optimization.

- `main.rs`: Rust reference for debug info enabled with no optimization.
- `main.sla`: Sla companion for debug info enabled with no optimization.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/217_pkg_profile_debug/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/217_pkg_profile_debug/main.sla --out /tmp/217_pkg_profile_debug.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/217_pkg_profile_debug/main.sla
```
