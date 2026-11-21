# 648 ballot_high

Ballot 高位 `B(5,3)=28`（`B(5,5)=42` 对角锚；同式高位复算）。

- 对标：646_ballot → 低位版互补（同式高位复算；650 做高位对峙）
- 绕行：`B(5,2)=14` 低位锚守卫；`B(5,5)=Catalan(5)` 对角恒等

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/648_ballot_high/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/648_ballot_high/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/648_ballot_high/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/648_ballot_high/main.sla -o /tmp/basic_648 && /tmp/basic_648
# 期望输出：28,42
```
