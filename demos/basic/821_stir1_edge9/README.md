# 821 stir1_edge9

Stirling 一类次对角续 `c(7,6)=21`，`c(8,7)=28`，`c(9,8)=36`（三角数恒等续高位）。

- 对标：693_stir1_edge → 低位次对角版互补（边值恒等复算；825 做三向收束）
- 绕行：`binom(9,2)=36` 同值陪锁（546 二项体例复用；`28+8·1=36` 单步守卫）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/821_stir1_edge9/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/821_stir1_edge9/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/821_stir1_edge9/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/821_stir1_edge9/main.sla -o /tmp/basic_821 && /tmp/basic_821
# 期望输出：21,28,36
```
