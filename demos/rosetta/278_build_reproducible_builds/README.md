# 278 Build Reproducible Builds

This slot keeps reproducible build output observable as one deterministic hash match.

- `main.rs`: Rust reference for one deterministic hash match.
- `main.sla`: Sla companion for one deterministic hash match.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/278_build_reproducible_builds/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/278_build_reproducible_builds/main.sla --out /tmp/278_build_reproducible_builds.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/278_build_reproducible_builds/main.sla
```
