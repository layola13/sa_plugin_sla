# 600 duel_narcat

Narayana-商式对峙：行和 `== B(n)/(n+1)`（`n=5`：`42` 对 `42`；`n=6`：`132` 对 `132`）。

- 对标：598_narayana6 × 351_catalan → 两源单实现见各源（286 系对峙体例；600 整关口）
- 绕行：`binom_mul` 双复用（行和侧与商式侧各调，记 README 无复用纠缠）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/600_duel_narcat/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/600_duel_narcat/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/600_duel_narcat/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/600_duel_narcat/main.sla -o /tmp/basic_600 && /tmp/basic_600
# 期望输出：42,42,132,132
```
