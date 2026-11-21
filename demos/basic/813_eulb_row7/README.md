# 813 eulb_row7

Eulerian-B 第 7 行 `1,2179,60657,259723,259723,60657,2179,1`（行和 `645120=2^7·7!`）。

- 对标：807_eulb_row6 → 低位行互补（同式高位行复算；行和恒等再锁）
- 绕行：行和八项手算复核（探针三线绿）；`B(7,0)=1` 左端点守卫

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/813_eulb_row7/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/813_eulb_row7/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/813_eulb_row7/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/813_eulb_row7/main.sla -o /tmp/basic_813 && /tmp/basic_813
# 期望输出：2179,60657,645120
```
