# 859 central18

中央二项 `C(18,9)=48620`，`C(20,10)=184756`（Catalan 商式的分子源，同式再上两档）。

- 对标：729_central_binom → 低位版互补（分子源纵深两值锁定；860 做商表对峙）
- 绕行：`C(14,7)=3432` 商式 C(7) 分子连验（探针三线绿）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/859_central18/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/859_central18/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/859_central18/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/859_central18/main.sla -o /tmp/basic_859 && /tmp/basic_859
# 期望输出：48620,184756
```
