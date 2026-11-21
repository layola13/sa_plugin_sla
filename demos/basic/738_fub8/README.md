# 738 fub8

有序 Bell 高位 `F(8)=545835`（`F(7)=47293` 低位锚；同式再上一位）。

- 对标：736_fub7 → `n=7` 版互补（同式再上一位；740 做高位对峙）
- 绕行：二项递推八项和手算复核（探针三线绿；递归深度止 `8`）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/738_fub8/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/738_fub8/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/738_fub8/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/738_fub8/main.sla -o /tmp/basic_738 && /tmp/basic_738
# 期望输出：47293,545835
```
