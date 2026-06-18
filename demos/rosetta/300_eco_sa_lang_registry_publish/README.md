# 300 Eco Sa Lang Registry Publish

This slot keeps SA language-registry publication observable as package, checksum, and index update steps.

- `main.rs`: Rust reference for package, checksum, and index-update publish steps.
- `main.sla`: Sla companion for package, checksum, and index-update steps.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/300_eco_sa_lang_registry_publish/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/300_eco_sa_lang_registry_publish/main.sla --out /tmp/300_eco_sa_lang_registry_publish.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/300_eco_sa_lang_registry_publish/main.sla
```
