# 788 schro10

大 Schröder 续高位二 `S(10)=1037718`（`S(9)=206098` 低位锚；卷积和 `831620`）。

- 对标：786_schro9 → `n=9` 版互补（同式再上一位；790 做高位对峙）
- 绕行：十项卷积 `412196+166344+102696+79464+70920=831620` 手算复核（自纠 `832620` 笔误）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/788_schro10/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/788_schro10/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/788_schro10/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/788_schro10/main.sla -o /tmp/basic_788 && /tmp/basic_788
# 期望输出：206098,1037718
```
