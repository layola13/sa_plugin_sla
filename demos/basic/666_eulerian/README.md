# 666 eulerian

Eulerian 三角建表 `E(n,m)=(n-m)·E(n-1,m-1)+(m+1)·E(n-1,m)`（546 范式）。
`E(3,1)=4`，`E(4,1)=11`，`E(4,2)=11`。

- 对标：646_ballot → 同为三角建表（此处为加权双系数；669 做建表/交错和对峙）
- 绕行：首列留 `1`（`E(n,0)=1`；546 同式）；`E(2,1)=1` 小值端点守卫

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/666_eulerian/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/666_eulerian/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/666_eulerian/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/666_eulerian/main.sla -o /tmp/basic_666 && /tmp/basic_666
# 期望输出：4,11,11
```
