# 295 Eco Bpf Ebpf Bytecode

This slot keeps eBPF-style program structure observable as load and return instruction kinds.

- `main.rs`: Rust reference for load and return eBPF instruction kinds.
- `main.sla`: Sla companion for load and return instruction kinds.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/295_eco_bpf_ebpf_bytecode/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/295_eco_bpf_ebpf_bytecode/main.sla --out /tmp/295_eco_bpf_ebpf_bytecode.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/295_eco_bpf_ebpf_bytecode/main.sla
```
