# 617 delannoy_high

Delannoy 高位 `D(5,5)=1683`（`D(4,5)=681` 低位锚；中央列上接 `321`）。

- 对标：611_delannoy_tab → 低位版互补（同式高位复算；618 做高位对峙）
- 绕行：`681+321+681=1683` 三项手算复核（探针三线绿）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/617_delannoy_high/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/617_delannoy_high/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/617_delannoy_high/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/617_delannoy_high/main.sla -o /tmp/basic_617 && /tmp/basic_617
# 期望输出：681,1683
```
