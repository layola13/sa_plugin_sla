# 569 euler

Eulerian 数 `A(n,d)`（0 起降序数）：`A(n,d)=(n-d)·A(n-1,d-1)+(d+1)·A(n-1,d)`。
`A(4,1)=11`，`A(4,2)=11`，`A(5,2)=66`，`A(5,3)=26`。

- 对标：531_stirling2 → 同为拍扁加权三角（此处双权和式；570 做行和）
- 绕行：`dd=0` 首项守卫（`A(n-1,-1)` 负下标不存在，`if dd > 0` 护栏）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/569_euler/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/569_euler/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/569_euler/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/569_euler/main.sla -o /tmp/basic_569 && /tmp/basic_569
# 期望输出：11,11,66,26
```
