# 208 Pkg Dev Dependencies

This slot keeps development-only dependency wiring observable as one test-only package.

- `main.rs`: Rust reference for a test-only dependency.
- `main.sla`: Sla companion for a test-only dependency.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/208_pkg_dev_dependencies/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/208_pkg_dev_dependencies/main.sla --out /tmp/208_pkg_dev_dependencies.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/208_pkg_dev_dependencies/main.sla
```
