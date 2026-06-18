# 280 Build Ci Cd Integration

This slot keeps CI/CD pipeline composition observable as build, test, and publish stages.

- `main.rs`: Rust reference for build, test, and publish pipeline stages.
- `main.sla`: Sla companion for build, test, and publish pipeline stages.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/280_build_ci_cd_integration/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/280_build_ci_cd_integration/main.sla --out /tmp/280_build_ci_cd_integration.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/280_build_ci_cd_integration/main.sla
```
