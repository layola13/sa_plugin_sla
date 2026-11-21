# 785 tri_bell

Bell 三向：二项递推 × Aitken 三角 × 二类行和（`n=9：21147 三锁`）。

- 对标：776_bell9 → 递推源互补（605 三向体例；三算法互锁收束 Bell 续高位族）
- 绕行：三源异构（递推/三角/行和）同值锁定；`bell(8)=4140` 低位陪锁

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/785_tri_bell/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/785_tri_bell/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/785_tri_bell/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/785_tri_bell/main.sla -o /tmp/basic_785 && /tmp/basic_785
# 期望输出：21147,21147,21147
```
