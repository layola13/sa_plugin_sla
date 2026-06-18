# 215 Pkg Patch Override

This slot keeps patch override application observable as a replaced package source.

- `main.rs`: Rust reference for replacing a package source via patching.
- `main.sla`: Sla companion for replacing a package source via patching.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/215_pkg_patch_override/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/215_pkg_patch_override/main.sla --out /tmp/215_pkg_patch_override.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/215_pkg_patch_override/main.sla
```
