# 748 motz10

Motzkin 续高位二 `M(10)=2188`（`M(9)=835` 低位锚；卷积和 `1353`）。

- 对标：746_motz9 → `n=9` 版互补（同式再上一位；750 做高位对峙）
- 绕行：九项卷积 `323+127+102+84+81+84+102+127+323=1353` 手算复核（自纠 `88` 笔误）

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/748_motz10/main.sla
# SAB 已密封（sab-sealed-2026-11-15），--test-backend sab 仅为显式 opt-in；生产路径是 SA 文本（默认 auto / --test-backend sa）。
SA_PLUGIN_DEV=1 sa sla test demos/basic/748_motz10/main.sla --test-backend sab
SA_PLUGIN_DEV=1 sa sla test demos/basic/748_motz10/main.sla --test-backend sa
SA_PLUGIN_DEV=1 sa sla build-exe demos/basic/748_motz10/main.sla -o /tmp/basic_748 && /tmp/basic_748
# 期望输出：835,2188
```
