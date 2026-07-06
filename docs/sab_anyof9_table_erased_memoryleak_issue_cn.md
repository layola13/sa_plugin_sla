# SAB AnyOf9 table-erased world query cleanup MemoryLeak issue

## 状态
- 发现日期: 2026-07-06
- 发现仓库: `/home/vscode/projects/sla_ecs`
- 仅报告 issue, 未修改 SLA 编译器源码。

## 复现命令
```bash
cd /home/vscode/projects/sla_ecs
SA_PLUGIN_DEV=1 sa sla check lib/world_table_erased.sla
SA_PLUGIN_DEV=1 sa sla check lib/system_param_table_erased.sla

timeout 120s env SA_PLUGIN_DEV=1 sa sla test lib/world_table_erased.sla \
  --filter "anyof nested" --test-backend sa --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test lib/system_param_table_erased.sla \
  --filter "filtered pair mut system params" --test-backend sa --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test lib/world_table_erased.sla \
  --filter "anyof nested" --jobs 1 --trace-panic

timeout 120s env SA_PLUGIN_DEV=1 sa sla test lib/system_param_table_erased.sla \
  --filter "filtered pair mut system params" --jobs 1 --trace-panic
```

## 现象
- `sa sla check lib/world_table_erased.sla`: 通过。
- `sa sla check lib/system_param_table_erased.sla`: 通过。
- generated-SA backend focused tests 通过:
  - `[PASS] table erased anyof nested in tuple query data`
  - `[PASS] table erased filtered pair mut system params`
- 默认/SAB backend world focused test 失败:

```text
error[MemoryLeak]: live registers remain at function exit
  register: first_type_id
  state: Active
{"trap":"MemoryLeak","trap_code":1012,"file":".sla-cache/sab/world_table_erased-65069546a795855e.sab","line":25946,"source_line":0,"column":null,"source_text":null,"original_text":null,"bad_token":null,"context":[],"register":"first_type_id","registers":[],"expected_mask":null,"actual_mask":1,"expected_mask_name":null,"actual_mask_name":"Active","upstream_loc":null,"function":null,"is_ffi_wrapper":false,"message":"live registers remain at function exit","hint":null}
```

- 默认/SAB backend system-param focused test 也失败, 同一个寄存器未清理:

```text
error[MemoryLeak]: live registers remain at function exit
  register: first_type_id
  state: Active
{"trap":"MemoryLeak","trap_code":1012,"file":".sla-cache/sab/system_param_table_erased-df993dcd8b07e36f.sab","line":32112,"source_line":0,"column":null,"source_text":null,"original_text":null,"bad_token":null,"context":[],"register":"first_type_id","registers":[],"expected_mask":null,"actual_mask":1,"expected_mask_name":null,"actual_mask_name":"Active","upstream_loc":null,"function":null,"is_ffi_wrapper":false,"message":"live registers remain at function exit","hint":null}
```

## 最小触发上下文
`sla_ecs` 在 `lib/world_table_erased.sla` 中把 direct `TableErasedAnyOf` / `table_erased_world_query_any_of$N` 生成范围从 `AnyOf5..8` 扩到 `AnyOf5..9`, 并在测试 `"table erased anyof nested in tuple query data"` 中实例化:

```sla
table_erased_world_query_any_of9_auto<
  TableErasedPos, TableErasedVel, TableErasedMarker, TableErasedTag,
  TableErasedAux, TableErasedExtra, TableErasedMore, TableErasedBonus,
  TableErasedPrime, TableErasedTime, TableErasedEvent
>(...)
```

同一增量还在 `lib/system_param_table_erased.sla` 中把 direct `table_erased_run_any_of$N_query_resource_system` 生成范围扩到 `AnyOf9`; generated-SA backend 可执行通过, 说明 SLA 源级类型检查和 generated-SA cleanup 路径能承载该用例。默认/SAB 后端在 world query 与 system-param runner 两条路径的函数出口都未释放 `first_type_id`。

## 期望
默认/SAB backend 应与 generated-SA backend 一致通过该 focused 测试, 并在含 9 分支 generic `AnyOf` 展开/调用的函数出口正确清理所有形参/局部寄存器。

## 规避
当前 ECS 代码可继续以 generated-SA 验证该增量。SAB 默认路径在该用例上暂不可作为通过证据；后续需要 SAB cleanup 修复后重新验证。
