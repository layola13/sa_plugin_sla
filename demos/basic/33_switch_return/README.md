# 33 Switch Return

对标 `tsgosa/demos/111_switch_fn`。

与 `13_enum_switch`（语句赋值式）互补：此处一臂直接 `return`、其余臂赋值
（见 `tests/test_unit_switch_statement_direct.sla` 的混合写法）。
纯全 `return` 臂在 check/SAB 两端互斥，详见 POTENTIAL_ISSUES #7。

```bash
SA_PLUGIN_DEV=1 sa sla check demos/basic/33_switch_return/main.sla
SA_PLUGIN_DEV=1 sa sla test demos/basic/33_switch_return/main.sla
```
