# 201 Pkg Manifest Basic

This slot keeps the package manifest surface observable as three required fields: name, version, and entry point.

- `main.rs`: Rust reference for the required manifest-field shape.
- `main.sla`: Sla companion for the required manifest-field shape.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/201_pkg_manifest_basic/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/201_pkg_manifest_basic/main.sla --out /tmp/201_pkg_manifest_basic.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/201_pkg_manifest_basic/main.sla
```
