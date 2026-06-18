# 229 Mod Layout Injection

This slot keeps module-provided layout metadata observable as one injected field.

- `main.rs`: Rust reference for one module-injected layout field.
- `main.sla`: Sla companion for one module-injected layout field.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/229_mod_layout_injection/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/229_mod_layout_injection/main.sla --out /tmp/229_mod_layout_injection.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/229_mod_layout_injection/main.sla
```
