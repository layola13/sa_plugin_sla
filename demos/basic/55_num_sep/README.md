# 55 Num Sep

对标 `tsgosa/demos/164_num_sep`（`1000000 / 1000 = 1000`）。

- 缺口 #11：SLA 词法暂不支持数字分隔符（`1_000` 报
  `found '_000', expected semicolon`，探针见 `/tmp/psep.sla`），
  此处用普通字面量表达同一语义。

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/55_num_sep/main.sla
SA_PLUGIN_DEV=1 sa sla test demos/basic/55_num_sep/main.sla
```
