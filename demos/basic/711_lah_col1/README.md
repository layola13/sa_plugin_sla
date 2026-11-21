# 711 lah_col1

Lah 首列即阶乘：`L(6,1)=720`，`L(7,1)=5040`，`L(8,1)=40320`（首列恒等单锁）。

- 对标：706_lah7 → 内格版互补（首列恒等复算；712 做首列对峙）
- 绕行：首列阶乘建表自然导出（免预填，706 口径）；`L(5,1)=120` 小值守卫

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/711_lah_col1/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/711_lah_col1/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/711_lah_col1/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/711_lah_col1/main.sla -o /tmp/basic_711 && /tmp/basic_711
# 期望输出：720,5040,40320
```
