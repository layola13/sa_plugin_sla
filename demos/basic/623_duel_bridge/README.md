# 623 duel_bridge

桥对峙：Schröder 递推 vs Delannoy 差式（`n=4：90 对 90`；`n=5：394 对 394`）。

- 对标：622_schro_delan → 桥源互补（608 高位源合流；跨族双边锁定）
- 绕行：差式天然避负数字面量坑（436 口径：恒等式断言只用正数差）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/623_duel_bridge/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/623_duel_bridge/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/623_duel_bridge/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/623_duel_bridge/main.sla -o /tmp/basic_623 && /tmp/basic_623
# 期望输出：90,90,394,394
```
