# 574 euler_sym

Eulerian 对称性 `A(n,d)==A(n,n-1-d)`（`A(5,1)=26` 对 `A(5,3)=26`；`A(4,1)=11` 对 `A(4,2)=11`）。

- 对标：569_euler → 单实现见源（553 对称体例；升降读数镜像）
- 绕行：镜像下标 `n-1-d` 显式传参（记 README 防差一）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/574_euler_sym/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/574_euler_sym/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/574_euler_sym/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/574_euler_sym/main.sla -o /tmp/basic_574 && /tmp/basic_574
# 期望输出：26,26,11,11
```
