# 677 eulb_row

Eulerian-B 第 4 行 `1,76,230,76,1`（行和 `384=2^4·4!`；循环求和）。

- 对标：676_eulb → 单格版互补（同式行复算；行和 main 直打）
- 绕行：行和恒等 `sum(B(4,m))=2^4·4!` 双锁（684 做公式桥；`B(4,0)=1` 端点守卫）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/677_eulb_row/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/677_eulb_row/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/677_eulb_row/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/677_eulb_row/main.sla -o /tmp/basic_677 && /tmp/basic_677
# 期望输出：76,230,384
```
