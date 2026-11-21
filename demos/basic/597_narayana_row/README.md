# 597 narayana_row

Narayana 行：`n=4` 行 `1,6,6,1`（和 `14=C(4)`）；`N(5,0)=1` 左端点。

- 对标：596_narayana → 单格版互补（532 行和体例；行和 main 直打）
- 绕行：行和表达式内联（`1+6+6+1=14` 手算复核，记 README）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/597_narayana_row/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/597_narayana_row/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/597_narayana_row/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/597_narayana_row/main.sla -o /tmp/basic_597 && /tmp/basic_597
# 期望输出：1,6,6,1,14
```
