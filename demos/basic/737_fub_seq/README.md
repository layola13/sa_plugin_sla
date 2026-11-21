# 737 fub_seq

有序 Bell 序列前 8 项 `1,1,3,13,75,541,4683,47293`（前缀和 `fseq(7)=52610`；循环求和）。

- 对标：736_fub7 → 单值版互补（同式序列复算；和 main 直打）
- 绕行：`fseq(5)=634` 小值守卫；`F(0)=F(1)=1` 双端点守卫

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/737_fub_seq/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/737_fub_seq/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/737_fub_seq/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/737_fub_seq/main.sla -o /tmp/basic_737 && /tmp/basic_737
# 期望输出：1,1,52610
```
