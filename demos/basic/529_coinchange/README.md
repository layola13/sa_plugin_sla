# 529 coinchange

换零钱计数：硬币 `{1,2,5}` 凑出 `n` 的方案数（`6→5` 种，`10→10` 种）。

- 对标：527_oddpart → 同为完全背包 DP（527 硬币为奇数列，此处为有限面值集）
- 绕行：三面值分三段直写（避 `Vec<i32>` 元素与 int 循环变量混算的类型坑）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/529_coinchange/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/529_coinchange/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/529_coinchange/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/529_coinchange/main.sla -o /tmp/basic_529 && /tmp/basic_529
# 期望输出：5,10
```
