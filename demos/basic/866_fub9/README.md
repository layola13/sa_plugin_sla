# 866 fub9

有序 Bell 续高位 `F(9)=7087261`（二项递推，同式再上一位）。

- 对标：738_fub8 → `n=8` 版互补（同式再上一位；868 做递推/加权对峙）
- 绕行：`sum C(9,k)F(k)` 九项手算复核（探针三线绿）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/866_fub9/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/866_fub9/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/866_fub9/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/866_fub9/main.sla -o /tmp/basic_866 && /tmp/basic_866
# 期望输出：7087261,545835
```
