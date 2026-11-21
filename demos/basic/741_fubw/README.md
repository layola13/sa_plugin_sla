# 741 fubw

有序 Bell 加权和 `F(n)=sum k!·S(n,k)`（`F(6)=4683`，`F(7)=47293`，`F(8)=545835`）。

- 对标：588_fubini → 低位加权版互补（同式再上三位；745 做三向收束）
- 绕行：`F(8)` 加权八项 `1+254+5796+40824+126000+191520+141120+40320` 手算复核

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/741_fubw/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/741_fubw/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/741_fubw/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/741_fubw/main.sla -o /tmp/basic_741 && /tmp/basic_741
# 期望输出：4683,47293,545835
```
