# 579 duel_risefall

升降对峙：`rising(n,1) == falling(n,n) == n!`（`n=4`：`24` 对 `24`；`n=5`：`120` 对 `120`）。

- 对标：577_rising × 578_falling → 两源单实现见各源（286 系对峙体例）
- 绕行：双签名皆（项数，起点），对峙点取同形传参（578 同例教训内化）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/579_duel_risefall/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/579_duel_risefall/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/579_duel_risefall/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/579_duel_risefall/main.sla -o /tmp/basic_579 && /tmp/basic_579
# 期望输出：24,24,120,120
```
