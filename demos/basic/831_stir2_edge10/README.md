# 831 stir2_edge10

Stirling 二类边值 `S(10,1)=1`，`S(10,10)=1`，`S(10,9)=45=C(10,2)`（次对角三角数恒等）。

- 对标：827_stir2_row10 → 行源互补（边恒等 `S(n,n-1)=n(n-1)/2` 双值连验；835 做三向）
- 绕行：`9·8/2=36` 三角数手算复核（探针三线绿）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/831_stir2_edge10/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/831_stir2_edge10/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/831_stir2_edge10/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/831_stir2_edge10/main.sla -o /tmp/basic_831 && /tmp/basic_831
# 期望输出：1,1,45
```
