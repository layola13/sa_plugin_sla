# 662 duel_fine7

Fine 高位二对峙：短递推 vs 卷积（`n=6：57 对 57`；`n=7：186 对 186`）。
卷积 `F(n)=sum C(k-1)·F(n-k)`（`n=7：18+12+10+14+0+132=186`）。

- 对标：661_fine7 → 高位源互补（卷积版合流；跨算法双边锁定）
- 绕行：卷积递归两后端 8s 级（探针 sab 5.6s / sa 8.2s 含全组断言）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/662_duel_fine7/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/662_duel_fine7/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/662_duel_fine7/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/662_duel_fine7/main.sla -o /tmp/basic_662 && /tmp/basic_662
# 期望输出：57,57,186,186
```
