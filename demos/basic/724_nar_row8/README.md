# 724 nar_row8

Narayana 第 8 行 `1,28,196,490,490,196,28,1`（行和 `1430=Catalan(8)`；循环求和）。

- 对标：717_nar_row7 → 低位行互补（同式高位行复算；行和恒等再锁）
- 绕行：行和八项手算复核（探针三线绿）；`N(8,0)=1` 左端点守卫

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/724_nar_row8/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/724_nar_row8/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/724_nar_row8/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/724_nar_row8/main.sla -o /tmp/basic_724 && /tmp/basic_724
# 期望输出：28,196,1430
```
