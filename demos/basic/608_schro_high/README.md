# 608 schro_high

Schröder 高位 `S(5)=394`（`S(4)=90` 低位锚；同式高位复算）。

- 对标：606_schroder → 低位版互补（同式高位复算；610 做高位对峙）
- 绕行：卷积和 `304` 中间值域内无溢出（`90+304=394`）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/608_schro_high/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/608_schro_high/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/608_schro_high/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/608_schro_high/main.sla -o /tmp/basic_608 && /tmp/basic_608
# 期望输出：90,394
```
