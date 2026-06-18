# 293 Eco Embedded No Os

This slot keeps bare-metal embedded startup observable as one reset-handler hook without an OS runtime.

- `main.rs`: Rust reference for one reset-handler hook without an OS runtime.
- `main.sla`: Sla companion for one reset-handler hook without an OS runtime.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/293_eco_embedded_no_os/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/293_eco_embedded_no_os/main.sla --out /tmp/293_eco_embedded_no_os.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/293_eco_embedded_no_os/main.sla
```
