# 262 Build Bindgen C Header

This slot keeps C-header bindgen output observable as one type declaration plus one function declaration.

- `main.rs`: Rust reference for one type plus one function declaration.
- `main.sla`: Sla companion for one type plus one function declaration.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/262_build_bindgen_c_header/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/262_build_bindgen_c_header/main.sla --out /tmp/262_build_bindgen_c_header.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/262_build_bindgen_c_header/main.sla
```
