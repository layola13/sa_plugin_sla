# 798 eul8

Eulerian 第 8 行高位 `E(8,1)=247`，`E(8,2)=4293`，`E(8,3)=15619`（同式再上一位）。

- 对标：796_eul7 → `n=7` 版互补（同式再上一位；800 做高位对峙）
- 绕行：`6·120+3·1191=4293` 双项手算复核（探针三线绿）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/798_eul8/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/798_eul8/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/798_eul8/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/798_eul8/main.sla -o /tmp/basic_798 && /tmp/basic_798
# 期望输出：247,4293,15619
```
