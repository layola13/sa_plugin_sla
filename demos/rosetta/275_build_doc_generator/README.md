# 275 Build Doc Generator

This slot keeps generated documentation observable as both API and guide pages.

- `main.rs`: Rust reference for generated API and guide pages.
- `main.sla`: Sla companion for generated API and guide pages.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/275_build_doc_generator/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/275_build_doc_generator/main.sla --out /tmp/275_build_doc_generator.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/275_build_doc_generator/main.sla
```
