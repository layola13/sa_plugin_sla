# 609 duel_schro

Schröder 双实现对峙：迭代建表 vs 递归（`n=3：22 对 22`；`n=4：90 对 90`）。

- 对标：606_schroder → 迭代源（递归版互补；286 系对峙体例，双边同值锁定）
- 绕行：递归双基 `rsch(0)=1`、`rsch(1)=2`（无默认参数 #8 口径，显式双返回）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/609_duel_schro/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/609_duel_schro/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/609_duel_schro/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/609_duel_schro/main.sla -o /tmp/basic_609 && /tmp/basic_609
# 期望输出：22,22,90,90
```
