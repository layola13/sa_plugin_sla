# 793 schro_qseq

大 Schröder 商式高位 `qsch(7)=8558`，`qsch(8)=41586`，`qsch(9)=206098`（商式纵深）。

- 对标：789_duel_schro9 → 对峙版互补（商式单列纵深；795 做三向收束）
- 绕行：商式逐项精确整除（596 口径）；`qsch(6)=1806` 小值守卫

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/793_schro_qseq/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/793_schro_qseq/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/793_schro_qseq/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/793_schro_qseq/main.sla -o /tmp/basic_793 && /tmp/basic_793
# 期望输出：8558,41586,206098
```
