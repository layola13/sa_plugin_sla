# 224 Mod Reexport Pub Use

This slot keeps public re-export behavior observable as one item surfaced through `pub use`.

- `main.rs`: Rust reference for one item surfaced through `pub use`.
- `main.sla`: Sla companion for one item surfaced through `pub use`.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/224_mod_reexport_pub_use/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/224_mod_reexport_pub_use/main.sla --out /tmp/224_mod_reexport_pub_use.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/224_mod_reexport_pub_use/main.sla
```
