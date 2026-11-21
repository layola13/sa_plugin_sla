# 845 tri_lah9

Lah 续三向：建表行和 × 商式行和 × 递归行和（`n=9：4596553` 三锁）。

- 对标：837_lah_row9 → 行源互补（三实现互锁；715 三向体例收束 Lah 续三行族）
- 绕行：商式首列逐行置 1（835 探针纠偏复用）；行和手算误加已 python 复核（837 记账）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/845_tri_lah9/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/845_tri_lah9/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/845_tri_lah9/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/845_tri_lah9/main.sla -o /tmp/basic_845 && /tmp/basic_845
# 期望输出：4596553,4596553,4596553
```
