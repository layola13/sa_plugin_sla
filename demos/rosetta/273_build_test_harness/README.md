# 273 Build Test Harness

This slot keeps the build test harness observable as separate unit and integration test cases.

- `main.rs`: Rust reference for separate unit and integration test cases.
- `main.sla`: Sla companion for separate unit and integration test cases.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/273_build_test_harness/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/273_build_test_harness/main.sla --out /tmp/273_build_test_harness.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/273_build_test_harness/main.sla
```
