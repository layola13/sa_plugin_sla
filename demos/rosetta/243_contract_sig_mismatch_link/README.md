# 243 Contract Sig Mismatch Link

This slot keeps contract signature drift observable as one missing argument at link time.

- `main.rs`: Rust reference for one missing argument at link time.
- `main.sla`: Sla companion for one missing argument at link time.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/243_contract_sig_mismatch_link/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/243_contract_sig_mismatch_link/main.sla --out /tmp/243_contract_sig_mismatch_link.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/243_contract_sig_mismatch_link/main.sla
```
