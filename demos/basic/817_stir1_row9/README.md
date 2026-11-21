# 817 stir1_row9

Stirling 一类第 9 行 `40320,109584,118124,67284,22449,4536,546,36,1`（行和 `362880=9!`）。

- 对标：816_stir19 → 单格版互补（同式行复算；行和 main 直打）
- 绕行：行和九项手算复核（探针三线绿）；`c(9,9)=1` 对角端点守卫

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/817_stir1_row9/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/817_stir1_row9/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/817_stir1_row9/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/817_stir1_row9/main.sla -o /tmp/basic_817 && /tmp/basic_817
# 期望输出：40320,109584,362880
```
