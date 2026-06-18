# 223 Mod Visibility Private

This slot keeps private module visibility observable as one internal helper remaining reachable only inside the module.

- `main.rs`: Rust reference for one private helper staying module-local.
- `main.sla`: Sla companion for one private helper staying module-local.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/223_mod_visibility_private/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/223_mod_visibility_private/main.sla --out /tmp/223_mod_visibility_private.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/223_mod_visibility_private/main.sla
```
