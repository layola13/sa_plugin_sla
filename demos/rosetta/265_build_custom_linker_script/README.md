# 265 Build Custom Linker Script

This slot keeps linker-script customization observable as distinct text and data sections.

- `main.rs`: Rust reference for distinct text and data sections.
- `main.sla`: Sla companion for distinct text and data sections.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/265_build_custom_linker_script/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/265_build_custom_linker_script/main.sla --out /tmp/265_build_custom_linker_script.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/265_build_custom_linker_script/main.sla
```
