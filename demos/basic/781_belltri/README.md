# 781 belltri

Bell Aitken 三角 `T(n,0)=T(n-1,n-1)`（`B(8)=4140`，`B(9)=21147`，`B(10)=115975`）。

- 对标：776_bell9 → 递推版互补（异构三角单锁；785 做三向收束）
- 绕行：对角线回绕传播（左列即 Bell；`bt(7)=877` 小值守卫）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/781_belltri/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/781_belltri/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/781_belltri/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/781_belltri/main.sla -o /tmp/basic_781 && /tmp/basic_781
# 期望输出：4140,21147,115975
```
