# 844 lah9_right

Lah 第 9 行右部 `L(9,7)=2016`，`L(9,8)=72`，`L(9,9)=1`（836 左部版互补，全行覆盖）。

- 对标：836_lah9 → 左部版互补（左右合流全行 `362880,1451520,1693440,846720,211680,28224,2016,72,1`）
- 绕行：`21·40320/720=1176` 商式手算复核（探针三线绿）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/844_lah9_right/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/844_lah9_right/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/844_lah9_right/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/844_lah9_right/main.sla -o /tmp/basic_844 && /tmp/basic_844
# 期望输出：2016,72,1
```
