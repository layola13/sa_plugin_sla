# 812 eulb_alt67

Eulerian-B 交错续高位 `eba(6,3)=23548`，`eba(7,2)=60657`，`eba(7,3)=259723`（交错纵深）。

- 对标：682_eulb_alt → 低位交错版互补（同式再上两位；815 做三向收束）
- 绕行：`(7,2)` 交错三项 `78125-17496+28=60657` 手算复核（探针三线绿）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/812_eulb_alt67/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/812_eulb_alt67/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/812_eulb_alt67/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/812_eulb_alt67/main.sla -o /tmp/basic_812 && /tmp/basic_812
# 期望输出：23548,60657,259723
```
