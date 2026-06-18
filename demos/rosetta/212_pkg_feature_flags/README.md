# 212 Pkg Feature Flags

This slot keeps feature activation observable as one default feature plus one explicit feature.

- `main.rs`: Rust reference for one default feature plus one explicit feature.
- `main.sla`: Sla companion for one default feature plus one explicit feature.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/212_pkg_feature_flags/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/212_pkg_feature_flags/main.sla --out /tmp/212_pkg_feature_flags.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/212_pkg_feature_flags/main.sla
```
