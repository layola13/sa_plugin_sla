# 282 Ffi Link Static C Lib

This slot keeps static-library linkage observable as one archive member pulled into the final link.

- `main.rs`: Rust reference for one archive member linked from a static C library.
- `main.sla`: Sla companion for one archive member pulled into the final link.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/282_ffi_link_static_c_lib/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/282_ffi_link_static_c_lib/main.sla --out /tmp/282_ffi_link_static_c_lib.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/282_ffi_link_static_c_lib/main.sla
```
