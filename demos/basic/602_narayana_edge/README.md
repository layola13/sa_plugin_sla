# 602 narayana_edge

Narayana 边值 `N(n,1)=C(n,2)`（`n=4→6`，`n=5→10`，`n=6→15`）。

- 对标：596_narayana → 全表版互补（此处边列单序列；582 首列体例，603 做对峙）
- 绕行：边值即三角数（组合解释记 README：单峰 Dyck 路选峰位）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/602_narayana_edge/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/602_narayana_edge/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/602_narayana_edge/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/602_narayana_edge/main.sla -o /tmp/basic_602 && /tmp/basic_602
# 期望输出：6,10,15
```
