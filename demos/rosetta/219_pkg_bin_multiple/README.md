# 219 Pkg Bin Multiple

This slot keeps multiple binary targets observable as a CLI plus worker executable pair.

- `main.rs`: Rust reference for the CLI-plus-worker binary pair.
- `main.sla`: Sla companion for the CLI-plus-worker binary pair.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/219_pkg_bin_multiple/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/219_pkg_bin_multiple/main.sla --out /tmp/219_pkg_bin_multiple.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/219_pkg_bin_multiple/main.sla
```
