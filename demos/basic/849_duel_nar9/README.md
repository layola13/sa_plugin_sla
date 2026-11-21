# 849 duel_nar9

Narayana 续高位对峙：乘式商式 vs 表式商式（`(9,1)=36` 双锁，`(9,2)=336` 双锁）。

- 对标：846_nar9 → 乘式源（表式版互补；850 做内格对峙）
- 绕行：表首列逐行置 1（835 探针纠偏复用；探针三线绿）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/849_duel_nar9/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/849_duel_nar9/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/849_duel_nar9/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/849_duel_nar9/main.sla -o /tmp/basic_849 && /tmp/basic_849
# 期望输出：36,36,336,336
```
