# 94 Nested Template

对标 `tsgosa/demos/105_nested_tpl`（`sum=7 prod=12`）。

- 模板断言用 `str_eq`；打印走 `format` 赋值后打印（嵌套直打只出换行，
  见 `POTENTIAL_ISSUES.md` #4b；`check` 侧多插值已修复，见 #4）。

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/94_nested_tpl/main.sla
SA_PLUGIN_DEV=1 sa sla test demos/basic/94_nested_tpl/main.sla
```
