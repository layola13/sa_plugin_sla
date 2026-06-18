# 279 Build Artifact Caching Remote

This slot keeps remote artifact cache reuse observable as one downloaded build artifact.

- `main.rs`: Rust reference for one downloaded remote-cache artifact.
- `main.sla`: Sla companion for one downloaded remote-cache artifact.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/279_build_artifact_caching_remote/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/279_build_artifact_caching_remote/main.sla --out /tmp/279_build_artifact_caching_remote.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/279_build_artifact_caching_remote/main.sla
```
