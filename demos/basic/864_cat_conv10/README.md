# 864 cat_conv10

Catalan 卷积再高位 `C(10)=16796`，`C(11)=58786`（同式再上两位；734 体例高位）。

- 对标：857_cat_conv9 → `n=9` 版互补（卷积扇出 `n=11` 双后端秒级；865 做三向收束）
- 绕行：商式交叉确证 `58786`（探针三线绿）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/864_cat_conv10/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/864_cat_conv10/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/864_cat_conv10/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/864_cat_conv10/main.sla -o /tmp/basic_864 && /tmp/basic_864
# 期望输出：16796,58786,4862
```
