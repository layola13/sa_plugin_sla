# 853 duel_narcol29

Narayana 列对峙：乘式商式 vs 表式商式（`(8,2)=196` 双锁，`(9,2)=336` 双锁）。

- 对标：852_nar_col29 → 列源互补（乘表双实现锁定；849 高位对峙体例合流）
- 绕行：表首列逐行置 1（835 探针纠偏复用；探针三线绿）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/853_duel_narcol29/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/853_duel_narcol29/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/853_duel_narcol29/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/853_duel_narcol29/main.sla -o /tmp/basic_853 && /tmp/basic_853
# 期望输出：196,196,336,336
```
