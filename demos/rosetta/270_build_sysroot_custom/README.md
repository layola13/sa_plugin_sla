# 270 Build Sysroot Custom

This slot keeps custom sysroot composition observable as both core and std layers.

- `main.rs`: Rust reference for the core and std sysroot layers.
- `main.sla`: Sla companion for the core and std sysroot layers.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/270_build_sysroot_custom/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/270_build_sysroot_custom/main.sla --out /tmp/270_build_sysroot_custom.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/270_build_sysroot_custom/main.sla
```
