# 906 bell11

Bell 续高位三 `B(11)=678570`（二项递推，同式再上一位）。

- 对标：778_bell10 → `n=10` 版互补（同式再上一位；908 做递推/三角对峙）
- 绕行：`sum C(10,k)B(k)` 十一项手算复核（探针三线绿）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/906_bell11/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/906_bell11/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/906_bell11/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/906_bell11/main.sla -o /tmp/basic_906 && /tmp/basic_906
# 期望输出：678570,115975
```
