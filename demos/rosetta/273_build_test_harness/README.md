# 273 Build Test Harness

This directory pairs the original Rust rosetta reference with a Sla companion.

- `main.rs`: copied from `/home/vscode/projects/sci/demos/rosetta/273_build_test_harness/main.rs`.
- `main.sla`: Sla code for the same catalog slot, kept within the current Sla compiler surface so it can be checked, built, and tested.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/273_build_test_harness/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/273_build_test_harness/main.sla --out /tmp/273_build_test_harness.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/273_build_test_harness/main.sla
```
