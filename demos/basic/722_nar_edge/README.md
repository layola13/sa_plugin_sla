# 722 nar_edge

Narayana 边恒等 `N(n,1)=C(n,2)`：`N(7,1)=21`，`N(8,1)=28`（边值恒等单锁）。

- 对标：716_nar7 → 内格版互补（边值恒等复算；725 做三向收束）
- 绕行：`binom(8,2)=28` 同值陪锁（546 二项体例复用；商式边值天然三角数）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/722_nar_edge/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/722_nar_edge/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/722_nar_edge/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/722_nar_edge/main.sla -o /tmp/basic_722 && /tmp/basic_722
# 期望输出：21,28,28
```
