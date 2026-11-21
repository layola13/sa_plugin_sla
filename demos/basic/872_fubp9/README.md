# 872 fubp9

有序 Bell 表版高位 `F(9)=7087261`（742 体例续高位，同式再上一位）。

- 对标：744_fubp8 → `n=8` 版互补（表版纵深三值锁定；875 做三向收束）
- 绕行：表首列逐行置 1（835 探针纠偏复用；探针三线绿）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/872_fubp9/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/872_fubp9/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/872_fubp9/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/872_fubp9/main.sla -o /tmp/basic_872 && /tmp/basic_872
# 期望输出：7087261,545835
```
