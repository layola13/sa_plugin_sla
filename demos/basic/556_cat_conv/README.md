# 556 cat_conv

Catalan 卷积递推（Segner）：`C(n+1)=Σ C(i)·C(n-i)`（`C(4..6)=14,42,132`）。

- 对标：351_catalan → 商式版互补（此处走卷积；561 做对峙）
- 绕行：`c[j]*c[m-1-j]` 同型相乘（549 同例）；`C(3)=5` 端点守卫

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/556_cat_conv/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/556_cat_conv/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/556_cat_conv/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/556_cat_conv/main.sla -o /tmp/basic_556 && /tmp/basic_556
# 期望输出：14,42,132
```
