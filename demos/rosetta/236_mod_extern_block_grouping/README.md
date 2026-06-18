# 236 Mod Extern Block Grouping

This slot keeps grouped extern-surface exposure observable as two related foreign symbols.

- `main.rs`: Rust reference for two related symbols exposed through one extern surface.
- `main.sla`: Sla companion for two related symbols exposed through one extern surface.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/236_mod_extern_block_grouping/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/236_mod_extern_block_grouping/main.sla --out /tmp/236_mod_extern_block_grouping.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/236_mod_extern_block_grouping/main.sla
```
