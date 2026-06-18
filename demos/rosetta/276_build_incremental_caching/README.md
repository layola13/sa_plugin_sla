# 276 Build Incremental Caching

This slot keeps incremental compilation reuse observable as one unchanged module cache hit.

- `main.rs`: Rust reference for one unchanged-module cache hit.
- `main.sla`: Sla companion for one unchanged module cache hit.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/276_build_incremental_caching/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/276_build_incremental_caching/main.sla --out /tmp/276_build_incremental_caching.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/276_build_incremental_caching/main.sla
```
