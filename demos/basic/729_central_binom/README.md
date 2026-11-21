# 729 central_binom

中央二项 `C(8,4)=70`，`C(10,5)=252`，`C(12,6)=924`（Catalan 商式的分子源）。

- 对标：557_central → 取顶版互补（中央二项纵深；730 做商表对峙）
- 绕行：逐项约分防中间溢出（546 口径）；`C(6,3)=20` 小值守卫

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/729_central_binom/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/729_central_binom/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/729_central_binom/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/729_central_binom/main.sla -o /tmp/basic_729 && /tmp/basic_729
# 期望输出：70,252,924
```
