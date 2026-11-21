# 615 tri_schro

Schröder 三向：迭代建表 × 递归 × 二项商式直和（`n=4：90 三锁`）。
商式 `S(n)=sum C(n,k)·C(n+k,k)/(k+1)`（逐项精确整除：`1,10,30,35,14`）。

- 对标：608_schro_high → 高位源互补（605 三向体例；三算法互锁收束 Schroder 族）
- 绕行：商式逐项先乘后除（596 口径）；`ssch(2)=6` 小值端点守卫

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/615_tri_schro/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/615_tri_schro/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/615_tri_schro/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/615_tri_schro/main.sla -o /tmp/basic_615 && /tmp/basic_615
# 期望输出：90,90,90
```
