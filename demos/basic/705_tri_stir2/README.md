# 705 tri_stir2

Stirling 二类三向：建表行和 × 递归行和 × Bell 数（`n=7：877 三锁`）。

- 对标：697_stir2_row7 → 行源互补（605 三向体例；三算法互锁收束二类续高位族）
- 绕行：`bsum(6)=203` 低位陪锁（Bell(6) 六项和；递归行和扇出探针同形 8s 级）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/705_tri_stir2/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/705_tri_stir2/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/705_tri_stir2/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/705_tri_stir2/main.sla -o /tmp/basic_705 && /tmp/basic_705
# 期望输出：877,877,877
```
