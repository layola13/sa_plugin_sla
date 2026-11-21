# 661 fine7

Fine 高位二 `F(7)=186`（`F(6)=57` 低位锚；短递推一步 `[26·132-456]/16`）。

- 对标：658_fine_high → 高位版互补（同式再上一位；662 做高位二对峙）
- 绕行：`[3432-456]/16=186` 分子先算后除精确（596 口径）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/661_fine7/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/661_fine7/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/661_fine7/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/661_fine7/main.sla -o /tmp/basic_661 && /tmp/basic_661
# 期望输出：57,186
```
