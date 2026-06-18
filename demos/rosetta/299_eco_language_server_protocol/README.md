# 299 Eco Language Server Protocol

This slot keeps language-server message flow observable as request and response kinds.

- `main.rs`: Rust reference for request and response message kinds.
- `main.sla`: Sla companion for request and response kinds.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/299_eco_language_server_protocol/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/299_eco_language_server_protocol/main.sla --out /tmp/299_eco_language_server_protocol.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/299_eco_language_server_protocol/main.sla
```
