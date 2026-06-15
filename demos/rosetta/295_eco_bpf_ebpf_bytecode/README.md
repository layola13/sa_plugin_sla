# 295 Eco Bpf Ebpf Bytecode

This directory pairs the original Rust rosetta reference with a Sla companion.

- `main.rs`: copied from `/home/vscode/projects/sci/demos/rosetta/295_eco_bpf_ebpf_bytecode/main.rs`.
- `main.sla`: Sla code for the same catalog slot, kept within the current Sla compiler surface so it can be checked, built, and tested.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/295_eco_bpf_ebpf_bytecode/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/295_eco_bpf_ebpf_bytecode/main.sla --out /tmp/295_eco_bpf_ebpf_bytecode.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/295_eco_bpf_ebpf_bytecode/main.sla
```
