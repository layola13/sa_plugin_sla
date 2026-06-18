# 288 Ffi Cxx Name Mangling

This slot keeps C++ symbol-visibility concerns observable as both a mangled name and an `extern "C"` shim.

- `main.rs`: Rust reference for a mangled C++ name plus an `extern "C"` shim.
- `main.sla`: Sla companion for a mangled C++ name plus an `extern "C"` shim.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/288_ffi_cxx_name_mangling/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/288_ffi_cxx_name_mangling/main.sla --out /tmp/288_ffi_cxx_name_mangling.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/288_ffi_cxx_name_mangling/main.sla
```
