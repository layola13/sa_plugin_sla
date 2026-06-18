# 218 Pkg Metadata Custom

This slot keeps custom package metadata observable as owner and category fields.

- `main.rs`: Rust reference for owner and category metadata fields.
- `main.sla`: Sla companion for owner and category metadata fields.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/218_pkg_metadata_custom/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/218_pkg_metadata_custom/main.sla --out /tmp/218_pkg_metadata_custom.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/218_pkg_metadata_custom/main.sla
```
