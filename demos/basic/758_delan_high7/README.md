# 758 delan_high7

Delannoy 续中央 `D(7,7)=48639`（`D(7,6)=19825` 低位锚；三法会师值）。

- 对标：624_delannoy6 → `D(6,6)` 版互补（同式再上一位；759 做建表/直和对峙）
- 绕行：初算 `47737` 系上三角链串值（对称校验证伪，重走会师 `48639`，JEV 100% 采信）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/758_delan_high7/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/758_delan_high7/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/758_delan_high7/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/758_delan_high7/main.sla -o /tmp/basic_758 && /tmp/basic_758
# 期望输出：19825,48639
```
