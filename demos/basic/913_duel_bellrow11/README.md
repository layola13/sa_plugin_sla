# 913 duel_bellrow11

Bell 行和二对峙：二项递推 vs 二类行和（`n=11：678570` 双锁，`n=12：4213597` 双锁）。

- 对标：912_bell_rowsum11 × 906_bell11 → 行源与递推源合流（783 体例续高位）
- 绕行：无（双实现互锁，探针三线绿）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/913_duel_bellrow11/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/913_duel_bellrow11/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/913_duel_bellrow11/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/913_duel_bellrow11/main.sla -o /tmp/basic_913 && /tmp/basic_913
# 期望输出：678570,678570,4213597,4213597
```
