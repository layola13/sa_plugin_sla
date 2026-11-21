# 539 qgrow

互异分拆增长段（`q(8..10)=6,8,10`；526 的高位延续，540/541 做 Euler 交叉核对）。

- 对标：526_distinct → 低位版互补
- 绕行：初版手算漏 `[5,4]`/`[6,4]`（panic 53902 定位，`7→8`、`9→10` 修正，记 README）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/539_qgrow/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/539_qgrow/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/539_qgrow/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/539_qgrow/main.sla -o /tmp/basic_539 && /tmp/basic_539
# 期望输出：6,8,10
```
