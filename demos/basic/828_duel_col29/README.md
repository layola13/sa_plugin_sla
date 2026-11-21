# 828 duel_col29

Stirling 二类列对峙：建表 vs `2^(n-1)-1`（`(8,2)=127`，`(9,2)=255`，`(10,2)=511` 三档互锁）。

- 对标：701_stir2_col → 低位列互补（列恒等 `S(n,2)=2^(n-1)-1` 纵深三值锁定）
- 绕行：无（纯整数恒等，探针三线绿）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/828_duel_col29/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/828_duel_col29/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/828_duel_col29/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/828_duel_col29/main.sla -o /tmp/basic_828 && /tmp/basic_828
# 期望输出：127,127,255,255,511
```
