# SAB system_param_table_erased removed_components cleanup MemoryLeak issue

状态：待修复。下游 `sla_ecs` 在把普通 `TableErasedWorld` system-param `AnyOf` wrapper 从 10 扩到 12 后，generated-SA 后端整文件测试通过，但默认/SAB 后端在整文件聚合测试退出清理阶段报告 `removed_components` 仍为 Active。本文只记录 issue，不修改 SLA 编译器源码。

## 下游变更

- repo：`/home/vscode/projects/sla_ecs`
- 文件：`lib/system_param_table_erased.sla`
- 变更：普通 `TableErasedWorld` system-param wrapper 的：
  - `table_erased_run_any_of$N_query_resource_system`
  - `table_erased_run_with_any_of$N_query_resource_system`
  - `table_erased_run_pair_with_any_of$N_query_resource_system`
  从 `@expand_tuple(5, 10, T)` 扩到 `@expand_tuple(5, 12, T)`，并新增 `AnyOf12` / `WithAnyOf12` / `PairWithAnyOf12` resource-param 测试覆盖。

## 复现命令

在 `/home/vscode/projects/sla_ecs`：

```bash
SA_PLUGIN_DEV=1 sa sla check lib/system_param_table_erased.sla
timeout 240s env SA_PLUGIN_DEV=1 sa sla test lib/system_param_table_erased.sla --test-backend sa --jobs 1 --trace-panic
timeout 240s env SA_PLUGIN_DEV=1 sa sla test lib/system_param_table_erased.sla --jobs 1 --trace-panic
```

## 当前结果

`sla check` 通过。

generated-SA 后端通过：

```text
test result: ok. 126 passed; 0 failed; 0 skipped
```

默认/SAB 后端失败：

```text
error[MemoryLeak]: live registers remain at function exit
  register: removed_components
  state: Active
{"trap":"MemoryLeak","trap_code":1012,"file":".sla-cache/sab/system_param_table_erased-630fd12a0f95801b.sab","line":268239,"source_line":0,"column":null,"source_text":null,"original_text":null,"bad_token":null,"context":[],"register":"removed_components","registers":[],"expected_mask":null,"actual_mask":1,"expected_mask_name":null,"actual_mask_name":"Active","upstream_loc":null,"function":null,"is_ffi_wrapper":false,"message":"live registers remain at function exit","hint":null}
```

## 2026-07-07 复测

在 relationship / observer system-param `AnyOf12` 路径已分别通过 generated-SA 和默认/SAB 后，重新复测普通 `TableErasedWorld` system-param 文件，问题仍复现：

```bash
timeout 600s env SA_PLUGIN_DEV=1 sa sla test lib/system_param_table_erased.sla --jobs 1 --trace-panic
```

结果仍为同一处 `removed_components` 清理泄漏：

```text
error[MemoryLeak]: live registers remain at function exit
  register: removed_components
  state: Active
{"trap":"MemoryLeak","trap_code":1012,"file":".sla-cache/sab/system_param_table_erased-630fd12a0f95801b.sab","line":268239,"source_line":0,"column":null,"source_text":null,"original_text":null,"bad_token":null,"context":[],"register":"removed_components","registers":[],"expected_mask":null,"actual_mask":1,"expected_mask_name":null,"actual_mask_name":"Active","upstream_loc":null,"function":null,"is_ffi_wrapper":false,"message":"live registers remain at function exit","hint":null}
```

## 2026-07-07 ParamSet 复测

下游又新增普通 `TableErasedWorld` 两个 disjoint pair-mut query 的 `ParamSet` 写回覆盖。generated-SA 通过，测试数更新为：

```text
test result: ok. 127 passed; 0 failed; 0 skipped
```

默认/SAB 仍复现同一类 `removed_components` 清理泄漏，`.sab` 行号随新增代码更新为 `270247`：

```text
error[MemoryLeak]: live registers remain at function exit
  register: removed_components
  state: Active
{"trap":"MemoryLeak","trap_code":1012,"file":".sla-cache/sab/system_param_table_erased-630fd12a0f95801b.sab","line":270247,"source_line":0,"column":null,"source_text":null,"original_text":null,"bad_token":null,"context":[],"register":"removed_components","registers":[],"expected_mask":null,"actual_mask":1,"expected_mask_name":null,"actual_mask_name":"Active","upstream_loc":null,"function":null,"is_ffi_wrapper":false,"message":"live registers remain at function exit","hint":null}
```

## 2026-07-07 三组 ParamSet 复测

下游继续新增普通 `TableErasedWorld` 三个 disjoint pair-mut query 的 `ParamSet` 写回覆盖。`sa sla check` 通过，generated-SA 后端通过，测试数更新为：

```text
test result: ok. 128 passed; 0 failed; 0 skipped
```

默认/SAB 后端仍复现同一类 `removed_components` 清理泄漏，`.sab` 行号随新增代码更新为 `272691`：

```text
error[MemoryLeak]: live registers remain at function exit
  register: removed_components
  state: Active
{"trap":"MemoryLeak","trap_code":1012,"file":".sla-cache/sab/system_param_table_erased-630fd12a0f95801b.sab","line":272691,"source_line":0,"column":null,"source_text":null,"original_text":null,"bad_token":null,"context":[],"register":"removed_components","registers":[],"expected_mask":null,"actual_mask":1,"expected_mask_name":null,"actual_mask_name":"Active","upstream_loc":null,"function":null,"is_ffi_wrapper":false,"message":"live registers remain at function exit","hint":null}
```

## 判断

该失败目前看起来不是新增 `AnyOf12` 业务逻辑错误：同一 SLA 源文件的类型检查通过，generated-SA 后端 126 个测试全通过，失败发生在 SAB `.sab` 文件尾部附近且无源码定位，寄存器名 `removed_components` 来自 `TableErasedWorld` 字段/导入聚合清理路径。

更像是 SAB 对大型导入聚合文件中 world 字段 cleanup 的整文件 verifier 问题。需要在 SLA 编译器侧检查 SAB lowering/codegen 对聚合字段、导入展开后未直接使用字段、以及函数/测试出口 cleanup 的 register ownership 状态收敛。
