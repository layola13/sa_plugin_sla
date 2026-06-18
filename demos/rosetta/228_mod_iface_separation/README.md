# 228 Mod Iface Separation

This slot keeps interface and implementation separation observable as two distinct module layers.

- `main.rs`: Rust reference for the interface and implementation module layers.
- `main.sla`: Sla companion for the interface and implementation module layers.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/228_mod_iface_separation/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/228_mod_iface_separation/main.sla --out /tmp/228_mod_iface_separation.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/228_mod_iface_separation/main.sla
```
