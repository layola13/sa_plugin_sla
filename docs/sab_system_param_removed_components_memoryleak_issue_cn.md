# SAB system_param_table_erased removed_components cleanup MemoryLeak issue

状态：编译器侧聚焦修复已验证，仍待下游整文件复测。下游 `sla_ecs` 在把普通 `TableErasedWorld` system-param `AnyOf` wrapper 从 10 扩到 12 后，generated-SA 后端整文件测试通过，但默认/SAB 后端在整文件聚合测试退出清理阶段报告 `removed_components` 仍为 Active。

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

## 2026-07-07 四组 ParamSet 复测

下游继续新增普通 `TableErasedWorld` 四个 disjoint pair-mut query 的 `ParamSet` 写回覆盖。`sa sla check` 通过，generated-SA 后端通过，测试数更新为：

```text
test result: ok. 129 passed; 0 failed; 0 skipped
```

默认/SAB 后端仍复现同一类 `removed_components` 清理泄漏，`.sab` 行号随新增代码更新为 `275575`：

```text
error[MemoryLeak]: live registers remain at function exit
  register: removed_components
  state: Active
{"trap":"MemoryLeak","trap_code":1012,"file":".sla-cache/sab/system_param_table_erased-630fd12a0f95801b.sab","line":275575,"source_line":0,"column":null,"source_text":null,"original_text":null,"bad_token":null,"context":[],"register":"removed_components","registers":[],"expected_mask":null,"actual_mask":1,"expected_mask_name":null,"actual_mask_name":"Active","upstream_loc":null,"function":null,"is_ffi_wrapper":false,"message":"live registers remain at function exit","hint":null}
```

## 2026-07-07 五组 ParamSet 复测

下游继续新增普通 `TableErasedWorld` 五个 disjoint pair-mut query 的 `ParamSet` 写回覆盖。`sa sla check` 通过，generated-SA 后端通过，测试数更新为：

```text
test result: ok. 130 passed; 0 failed; 0 skipped
```

默认/SAB 后端仍复现同一类 `removed_components` 清理泄漏，`.sab` 行号随新增代码更新为 `278903`：

```text
error[MemoryLeak]: live registers remain at function exit
  register: removed_components
  state: Active
{"trap":"MemoryLeak","trap_code":1012,"file":".sla-cache/sab/system_param_table_erased-630fd12a0f95801b.sab","line":278903,"source_line":0,"column":null,"source_text":null,"original_text":null,"bad_token":null,"context":[],"register":"removed_components","registers":[],"expected_mask":null,"actual_mask":1,"expected_mask_name":null,"actual_mask_name":"Active","upstream_loc":null,"function":null,"is_ffi_wrapper":false,"message":"live registers remain at function exit","hint":null}
```

## 2026-07-07 六组 ParamSet 复测

下游继续新增普通 `TableErasedWorld` 六个 disjoint pair-mut query 的 `ParamSet` 写回覆盖。`sa sla check` 通过，generated-SA 后端通过，测试数更新为：

```text
test result: ok. 131 passed; 0 failed; 0 skipped
```

默认/SAB 后端仍复现同一类 `removed_components` 清理泄漏，`.sab` 行号随新增代码更新为 `282679`：

```text
error[MemoryLeak]: live registers remain at function exit
  register: removed_components
  state: Active
{"trap":"MemoryLeak","trap_code":1012,"file":".sla-cache/sab/system_param_table_erased-630fd12a0f95801b.sab","line":282679,"source_line":0,"column":null,"source_text":null,"original_text":null,"bad_token":null,"context":[],"register":"removed_components","registers":[],"expected_mask":null,"actual_mask":1,"expected_mask_name":null,"actual_mask_name":"Active","upstream_loc":null,"function":null,"is_ffi_wrapper":false,"message":"live registers remain at function exit","hint":null}
```

## 2026-07-07 七组 ParamSet 复测

下游继续新增普通 `TableErasedWorld` 七个 disjoint pair-mut query 的 `ParamSet` 写回覆盖。`sa sla check` 通过，generated-SA 后端通过，测试数更新为：

```text
test result: ok. 132 passed; 0 failed; 0 skipped
```

默认/SAB 后端仍复现同一类 `removed_components` 清理泄漏，`.sab` 行号随新增代码更新为 `287823`：

```text
error[MemoryLeak]: live registers remain at function exit
  register: removed_components
  state: Active
{"trap":"MemoryLeak","trap_code":1012,"file":".sla-cache/sab/system_param_table_erased-630fd12a0f95801b.sab","line":287823,"source_line":0,"column":null,"source_text":null,"original_text":null,"bad_token":null,"context":[],"register":"removed_components","registers":[],"expected_mask":null,"actual_mask":1,"expected_mask_name":null,"actual_mask_name":"Active","upstream_loc":null,"function":null,"is_ffi_wrapper":false,"message":"live registers remain at function exit","hint":null}
```

## 判断

该失败目前看起来不是新增 `AnyOf12` 业务逻辑错误：同一 SLA 源文件的类型检查通过，generated-SA 后端 126 个测试全通过，失败发生在 SAB `.sab` 文件尾部附近且无源码定位，寄存器名 `removed_components` 来自 `TableErasedWorld` 字段/导入聚合清理路径。

更像是 SAB 对大型导入聚合文件中 world 字段 cleanup 的整文件 verifier 问题。需要在 SLA 编译器侧检查 SAB lowering/codegen 对聚合字段、导入展开后未直接使用字段、以及函数/测试出口 cleanup 的 register ownership 状态收敛。

## 2026-07-07 编译器侧聚焦修复

用缓存 SAB 反汇编定位到失败函数形态后，最小根因收敛为 direct-SAB 对字段赋值的 owner RHS 没有在 `store` 后发出可见 `move_`：

```sla
fn table_erased_world_clear_removed_components<R, M>(world: TableErasedWorld<R, M>) -> TableErasedWorld<R, M> {
    let removed_components: Vec<TableErasedRemovedComponent> = Vec::new();
    world.removed_components = removed_components;
    return world;
}
```

缓存失败 SAB 中对应片段只有 `store` 和 `return_`，没有 `move_ removed_components` 等价指令：

```text
call r126296,"@sa_vec_new",""
assign r58656,r126296
ptr_add r126297,r1482,56u
store r126297,0u,r58656,ty:12
release r126297
return_ r1482
```

已在编译器侧补齐 direct-SAB 字段/标识符赋值的 owner RHS move 标记，并避免把 `Vec` 等标准库 owner 类型误判为 Copy。新增最小覆盖 `tests/test_unit_field_assign_move_cleanup.sla` 的空 `Vec::new()` 字段替换场景。

验证结果：

```bash
zig fmt --check src/sab_codegen.zig
zig build --summary all
./zig-out/bin/sla-local-cli sla test tests/test_unit_field_assign_move_cleanup.sla --test-backend sa --trace-panic
SLA_SAB_NO_FALLBACK=1 ./zig-out/bin/sla-local-cli sla test tests/test_unit_field_assign_move_cleanup.sla --test-backend sab --trace-panic
./zig-out/bin/sla-local-cli sla sab build tests/test_unit_field_assign_move_cleanup.sla --out /tmp/field_assign_move_cleanup.sab
./zig-out/bin/sla-local-cli sla sab disasm /tmp/field_assign_move_cleanup.sab --out /tmp/field_assign_move_cleanup.disasm.sa
```

聚焦 SA/SAB 均通过：

```text
test result: ok. 3 passed; 0 failed; 0 skipped
```

新 SAB 反汇编确认 `store` 后已有显式 `move_`：

```text
func_decl $sla__clear_vec_field,fn:354
label $L_ENTRY,L4
    call r356,"@sa_vec_new",""
    assign r345,r356
    store r355,0u,r345,ty:12
    move_ r345
    return_ r355
```

未重新跑下游 `lib/system_param_table_erased.sla` 整文件测试：该文件前一次默认并行过滤测试 120s 无输出超时，继续使用最小回归和 SAB 反汇编作为本次提交证据，避免浪费编译时间和破坏增量缓存。

## 2026-07-07 当前 HEAD 聚焦复验

在 `34baf12` 之后重新复验本仓库最小 fixture，确认后续 direct-SAB identifier assignment 调整没有破坏字段赋值 owner RHS 的显式 consume：

```bash
timeout 10s env SLA_SAB_NO_FALLBACK=1 ./zig-out/bin/sla-local-cli \
  sla test tests/test_unit_field_assign_move_cleanup.sla --test-backend sab --trace-panic

timeout 10s env SLA_SAB_NO_FALLBACK=1 ./zig-out/bin/sla-local-cli \
  sla sab build tests/test_unit_field_assign_move_cleanup.sla \
  --out /tmp/field_assign_move_cleanup.sab

timeout 10s ./zig-out/bin/sla-local-cli \
  sla sab disasm /tmp/field_assign_move_cleanup.sab \
  --out /tmp/field_assign_move_cleanup.disasm.sa
```

结果：

- strict direct-SAB no-fallback：3/3 passed，约 1.63s。
- SAB build：约 1.64s。
- 反汇编中 `clear_vec_field` 仍在字段 `store` 后发出可见 `move_`：

```text
func_decl $sla__clear_vec_field
    store r350,0u,r345,ty:12
    move_ r345
    return_ r350
```

本次仍不重新跑危险下游整文件 `lib/system_param_table_erased.sla`：该路径此前长时间无输出/超时，继续使用本仓库聚焦 fixture 和 SAB 反汇编作为 compiler-owned 修复证据。
