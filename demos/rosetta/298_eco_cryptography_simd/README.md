# 298 Eco Cryptography Simd

This slot keeps cryptography-oriented SIMD work observable as four active lanes.

- `main.rs`: Rust reference for four active cryptography SIMD lanes.
- `main.sla`: Sla companion for four active lanes.

Commands:

```bash
SA_PLUGIN_DEV=1 sa sla check demos/rosetta/298_eco_cryptography_simd/main.sla
SA_PLUGIN_DEV=1 sa sla build demos/rosetta/298_eco_cryptography_simd/main.sla --out /tmp/298_eco_cryptography_simd.sa
SA_PLUGIN_DEV=1 sa sla test demos/rosetta/298_eco_cryptography_simd/main.sla
```
