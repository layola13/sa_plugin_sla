# 216 Pkg Profile Release

This slot keeps release profile tuning observable as the selected optimization level.

- `main.rs`: Rust reference for the selected release optimization level.
- `main.sla`: Sla companion for the selected release optimization level.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/216_pkg_profile_release/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/216_pkg_profile_release/main.sla --out /tmp/216_pkg_profile_release.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/216_pkg_profile_release/main.sla
```
