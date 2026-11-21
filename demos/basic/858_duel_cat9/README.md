# 858 duel_cat9

Catalan 双实现对峙：卷积 vs 商式（`n=9：4862` 双锁，`n=10：16796` 双锁）。

- 对标：856_cat9 × 857_cat_conv9 → 两源单实现见各源（728 体例续高位）
- 绕行：卷积递归 `n=10` 双后端秒级（探针三线绿）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/858_duel_cat9/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/858_duel_cat9/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/858_duel_cat9/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/858_duel_cat9/main.sla -o /tmp/basic_858 && /tmp/basic_858
# 期望输出：4862,4862,16796,16796
```
