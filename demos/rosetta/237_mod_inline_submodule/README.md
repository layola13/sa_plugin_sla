# 237 Mod Inline Submodule

This slot keeps inline child-module wiring observable as one nested layer.

- `main.rs`: Rust reference for one nested inline child module.
- `main.sla`: Sla companion for one nested inline child module.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/237_mod_inline_submodule/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/237_mod_inline_submodule/main.sla --out /tmp/237_mod_inline_submodule.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/237_mod_inline_submodule/main.sla
```
