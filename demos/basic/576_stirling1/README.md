# 576 stirling1

第一类 Stirling 数（无符号）：`c(n,k)=c(n-1,k-1)+(n-1)·c(n-1,k)`。
`c(4,*)=6,11,6,1`；`c(5,2)=50`。

- 对标：531_stirling2 → 第二类版互补（此处权为 `n-1`；580 做行值）
- 绕行：上界 `kk ≤ nn` 收窄（上三角恒零区不写，532 同例）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/576_stirling1/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/576_stirling1/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/576_stirling1/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/576_stirling1/main.sla -o /tmp/basic_576 && /tmp/basic_576
# 期望输出：6,11,6,50
```
