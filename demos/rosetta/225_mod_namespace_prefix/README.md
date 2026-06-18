# 225 Mod Namespace Prefix

This slot keeps namespace-qualified lookup observable as a namespace plus symbol pair.

- `main.rs`: Rust reference for the namespace-plus-symbol lookup pair.
- `main.sla`: Sla companion for the namespace-plus-symbol lookup pair.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/225_mod_namespace_prefix/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/225_mod_namespace_prefix/main.sla --out /tmp/225_mod_namespace_prefix.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/225_mod_namespace_prefix/main.sla
```
