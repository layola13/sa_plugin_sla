# 239 Mod Version Suffix Isolation

This slot keeps version-suffixed module coexistence observable as two isolated codec variants.

- `main.rs`: Rust reference for two isolated version-suffixed codec variants.
- `main.sla`: Sla companion for two isolated version-suffixed codec variants.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/239_mod_version_suffix_isolation/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/239_mod_version_suffix_isolation/main.sla --out /tmp/239_mod_version_suffix_isolation.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/239_mod_version_suffix_isolation/main.sla
```
