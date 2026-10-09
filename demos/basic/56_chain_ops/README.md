# 56 Chain Ops

对标 `tsgosa/demos/165_chain`（链式赋值 `a = b = 5`）。

- SLA 不支持链式赋值（`a = b = 5` 报 `found '=', expected semicolon`，
  探针见 `/tmp/pchain.sla`），此处用两条顺序赋值表达同一语义。

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/56_chain_ops/main.sla
SA_PLUGIN_DEV=1 sa sla test demos/basic/56_chain_ops/main.sla
```
