# 655 tri_ballot

Ballot 三向：拍扁建表 × 商式 × 反射差式（`(4,2)：9 三锁`）。

- 对标：648_ballot_high → 高位源互补（605 三向体例；三算法互锁收束 Ballot 族）
- 绕行：三源异构（递推/商/差）同值锁定；`bref(5,3)=28` 高位端点守卫

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/655_tri_ballot/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/655_tri_ballot/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/655_tri_ballot/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/655_tri_ballot/main.sla -o /tmp/basic_655 && /tmp/basic_655
# 期望输出：9,9,9
```
