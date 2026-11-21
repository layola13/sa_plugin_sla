# 757 delan_row7

Delannoy 第 7 行 `1,15,113,575,2241,7183,19825,48639`（行和 `78592`；循环求和）。

- 对标：756_delan7 → 单格版互补（同式行复算；行和 main 直打）
- 绕行：行和八项手算复核（探针三线绿）；`D(7,0)=1` 左端点守卫

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/757_delan_row7/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/757_delan_row7/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/757_delan_row7/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/757_delan_row7/main.sla -o /tmp/basic_757 && /tmp/basic_757
# 期望输出：15,113,78592
```
