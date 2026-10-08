# 31 Compound

对标 `tsgosa/demos/21_compound`（`x=10` 起步终值 `1`）。

- `+= |= &=`：词法原生支持（`src/lexer.zig` 有 `plus_equal/pipe_equal/ampersand_equal` token）。
- `-= *= /= %=`：暂无 token（见 POTENTIAL_ISSUES #6），demo 用 `x = x - 3` 脱糖写法，
  语义与 tsgosa 一致。

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/31_compound/main.sla
SA_PLUGIN_DEV=1 sa sla test demos/basic/31_compound/main.sla
```
