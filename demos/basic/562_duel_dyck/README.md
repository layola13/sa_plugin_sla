# 562 duel_dyck

Dyck 对峙：网格 DP `==` 卷积递推（`n=4`：`14` 对 `14`；`n=5`：`42` 对 `42`）。

- 对标：559_dyck × 556_cat_conv → 两源单实现见各源（286 系对峙体例）
- 绕行：双表各自独立（534 同例）；几何与代数双视角互锁

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/562_duel_dyck/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/562_duel_dyck/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/562_duel_dyck/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/562_duel_dyck/main.sla -o /tmp/basic_562 && /tmp/basic_562
# 期望输出：14,14,42,42
```
