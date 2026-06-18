# 263 Build Asset Bundling

This slot keeps build-time asset bundling observable as manifest, shader, and config artifacts packaged together.

- `main.rs`: Rust reference for bundling manifest, shader, and config artifacts.
- `main.sla`: Sla companion for packaging manifest, shader, and config artifacts.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/263_build_asset_bundling/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/263_build_asset_bundling/main.sla --out /tmp/263_build_asset_bundling.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/263_build_asset_bundling/main.sla
```
