# 708 lah8

Lah 第 8 行高位 `L(8,2)=141120`，`L(8,3)=141120`，`L(8,4)=58800`（同式再上一位）。

- 对标：706_lah7 → `n=7` 版互补（同式再上一位；710 做高位对峙）
- 绕行：`15120+10·12600=141120` 双项手算复核（探针三线绿）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/708_lah8/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/708_lah8/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/708_lah8/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/708_lah8/main.sla -o /tmp/basic_708 && /tmp/basic_708
# 期望输出：141120,141120,58800
```
