# 549 vander

Vandermonde 恒等式 `Σ_k C(r,k)·C(s,n-k) = C(r+s,n)`（`(4,4,4)→70`；`(3,5,4)→70`）。

- 对标：548_hockey → 单表对角版互补（此处为双表卷积；552 做查表对峙）
- 绕行：`k/j` 越界守卫三层（`k≤r`、`j≥0`、`j≤s`；`n-k` 无负数字面量，375 同例精神）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/549_vander/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/549_vander/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/549_vander/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/549_vander/main.sla -o /tmp/basic_549 && /tmp/basic_549
# 期望输出：70,70
```
