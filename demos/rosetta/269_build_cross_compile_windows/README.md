# 269 Build Cross Compile Windows

This slot keeps Windows cross-compilation observable as one MSVC target triple.

- `main.rs`: Rust reference for one MSVC Windows target triple.
- `main.sla`: Sla companion for one MSVC Windows target triple.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/269_build_cross_compile_windows/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/269_build_cross_compile_windows/main.sla --out /tmp/269_build_cross_compile_windows.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/269_build_cross_compile_windows/main.sla
```
