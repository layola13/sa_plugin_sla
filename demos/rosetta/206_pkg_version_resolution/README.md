# 206 Pkg Version Resolution

This slot keeps version solving observable as the selected patch release.

- `main.rs`: Rust reference for selecting the resolved patch release.
- `main.sla`: Sla companion for selecting the resolved patch release.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/206_pkg_version_resolution/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/206_pkg_version_resolution/main.sla --out /tmp/206_pkg_version_resolution.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/206_pkg_version_resolution/main.sla
```
