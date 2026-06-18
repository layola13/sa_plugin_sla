# 213 Pkg Default Features

This slot keeps default feature enablement observable as the standard shared feature set.

- `main.rs`: Rust reference for the standard default feature set.
- `main.sla`: Sla companion for the standard default feature set.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/213_pkg_default_features/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/213_pkg_default_features/main.sla --out /tmp/213_pkg_default_features.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/213_pkg_default_features/main.sla
```
