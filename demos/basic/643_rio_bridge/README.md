# 643 rio_bridge

Motzkin–Riordan 桥序 `R(n)=M(n-1)-R(n-1)`（`R(4)=3`，`R(5)=6`，`R(6)=15`）。

- 对标：636_riordan × 626_motzkin → 两族桥接（差序单锁；645 做三向收束）
- 绕行：`M(5)-R(5)=21-6=15` 差式天然避负数字面量坑（436 口径）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/643_rio_bridge/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/643_rio_bridge/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/643_rio_bridge/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/643_rio_bridge/main.sla -o /tmp/basic_643 && /tmp/basic_643
# 期望输出：3,6,15
```
