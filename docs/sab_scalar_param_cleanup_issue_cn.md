# SAB scalar parameter cleanup leak in focused table-erased wrapper

日期：2026-07-06

## 背景

在 `sla_ecs` 为 `lib/system_param_table_erased.sla` 补普通 `Query<Entity> + Commands` system-param runner
时，曾临时加入 allow 变体：runner 接受一个额外的标量 component id 参数，并调用现有
`table_erased_world_query_entities_allow` 构造查询。

SA backend 对核心 runner 通过；但只要 focused SAB 路径需要编码这个 allow wrapper，就会在 SAB verifier
阶段报告标量参数仍为 Active。该 allow 变体不是本批 ECS 核心功能，因此已从 `sla_ecs` 当前改动中移除；
问题在这里记录为编译器/SAB cleanup issue。

## 临时触发代码形状

仓库：`/home/vscode/projects/sla_ecs`

曾触发问题的 wrapper 形状：

```sla
fn table_erased_run_entity_allow_query_commands_system<R, M>(
    world: TableErasedWorld<R, M>,
    allow_component_id: i32,
    run: fn(TableErasedEntityQueryCommandsParam<R, M>) -> TableErasedEntityQueryCommandsParam<R, M>,
) -> TableErasedWorld<R, M> {
    let query = table_erased_world_query_entities_allow<R, M>(world, allow_component_id);
    let param0 = table_erased_entity_query_commands_param<R, M>(query, table_erased_commands_param_new<R, M>(world));
    let param1 = run(param0);
    let (world2, cleared) = table_erased_commands_apply<R, M>(param1.commands.world, param1.commands.commands);
    return world2;
}
```

`_auto` 版本同样触发过问题，泄漏参数名变为 `allow_type_id`：

```sla
fn table_erased_run_entity_allow_query_commands_system_auto<R, M>(
    world: TableErasedWorld<R, M>,
    allow_type_id: i32,
    run: fn(TableErasedEntityQueryCommandsParam<R, M>) -> TableErasedEntityQueryCommandsParam<R, M>,
) -> TableErasedWorld<R, M> {
    let allow_component_id = table_erased_world_component_id_for_type<R, M>(world, allow_type_id);
    return table_erased_run_entity_allow_query_commands_system<R, M>(world, allow_component_id, run);
}
```

## 复现命令

在上述临时代码存在时：

```sh
timeout 120s env SA_PLUGIN_DEV=1 sa sla test lib/system_param_table_erased.sla \
  --filter "table erased entity query commands param defers spawned entity"
```

## 观察到的 SAB 错误

直接 allow wrapper：

```text
error[MemoryLeak]: live registers remain at function exit
  register: allow_component_id
  state: Active
{"trap":"MemoryLeak","trap_code":1012,"file":".sla-cache/sab/system_param_table_erased-99717586d756e833.sab","line":13196,"source_line":0,"column":null,"source_text":null,"original_text":null,"bad_token":null,"context":[],"register":"allow_component_id","registers":[],"expected_mask":null,"actual_mask":1,"expected_mask_name":null,"actual_mask_name":"Active","upstream_loc":null,"function":null,"is_ffi_wrapper":false,"message":"live registers remain at function exit","hint":null}
```

`_auto` wrapper：

```text
error[MemoryLeak]: live registers remain at function exit
  register: allow_type_id
  state: Active
{"trap":"MemoryLeak","trap_code":1012,"file":".sla-cache/sab/system_param_table_erased-99717586d756e833.sab","line":13205,"source_line":0,"column":null,"source_text":null,"original_text":null,"bad_token":null,"context":[],"register":"allow_type_id","registers":[],"expected_mask":null,"actual_mask":1,"expected_mask_name":null,"actual_mask_name":"Active","upstream_loc":null,"function":null,"is_ffi_wrapper":false,"message":"live registers remain at function exit","hint":null}
```

另外，测试内直接用表达式调用现有 allow query：

```sla
if table_erased_world_query_entities_allow<TableErasedParamTime, TableErasedParamEvent>(w10, disabled.id).iter_len() != 3 { panic(12777); };
```

会让 SA focused path 在测试函数退出时报告临时值泄漏：

```text
error[MemoryLeak]: live registers remain at function exit
  in function @test "table erased entity query commands param defers spawned e
  line 39838 (expanded 35071):     return
  register: tmp_7535
  state: Active
```

## 当前 ECS 侧处理

`sla_ecs` 当前实现只保留基础 `table_erased_run_entity_query_commands_system`，避免把 allow wrapper 作为
库 API 落地。核心行为验证已通过：

```sh
SA_PLUGIN_DEV=1 sa sla check lib/system_param_table_erased.sla
timeout 120s env SA_PLUGIN_DEV=1 sa sla test lib/system_param_table_erased.sla \
  --filter "table erased entity query commands param defers spawned entity" \
  --test-backend sa
timeout 120s env SA_PLUGIN_DEV=1 sa sla test lib/system_param_table_erased.sla \
  --filter "table erased entity query commands param defers spawned entity"
```

三条命令均通过。

## 编译器侧修复状态

已在 `sa_plugin_sla` 修复并验证。

实现要点：

- `src/sab_codegen.zig` 将函数退出时的参数 cleanup 明确分为 `skip` / `consume` / `release`：copy-value 标量参数在退出前标记 consumed，不生成非法 primitive `release`；borrow 参数和 pointer-shaped owned 参数仍按原有所有权规则释放。
- `src/lowering_rules.zig` 的 auto-borrow call-arg 计划现在把临时 receiver 表达式纳入 `release_after_call`，所以 `temporary().method()` 这类借用 receiver 调用会释放 owner temporary。
- `src/codegen.zig` 的 associated-target 用户方法调用路径现在传入 receiver-style auto-borrow 选项，SA-text 和 direct SAB 对表达式链临时值释放保持一致。

新增回归：`tests/test_unit_scalar_param_cleanup_direct.sla`，覆盖 table-erased-like wrapper、`_auto` wrapper、未使用标量参数 consumed、以及 `temporary().iter_len()` owner temporary cleanup。

验证：

```sh
zig test src/lowering_rules.zig --test-filter "shared lowering rules normalize derives and call argument prefixes"
zig build --summary all
zig build test --summary all
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_scalar_param_cleanup_direct.sla --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_scalar_param_cleanup_direct.sla --test-backend sab --jobs 1 --trace-panic
sa plugin install --dev .
SA_PLUGIN_DEV=1 sa sla help
SA_PLUGIN_DEV=1 sa sla check /home/vscode/projects/sla_ecs/lib/system_param_table_erased.sla
SA_PLUGIN_DEV=1 sa sla test /home/vscode/projects/sla_ecs/lib/system_param_table_erased.sla --filter "table erased entity query commands param defers spawned entity" --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test /home/vscode/projects/sla_ecs/lib/system_param_table_erased.sla --filter "table erased entity query commands param defers spawned entity" --test-backend sab --jobs 1 --trace-panic
```

补充回归也通过：scalar reassignment、Result/EntityItem、Box/from_raw、void fn-pointer、borrow-temp 25/25、RefCell payload 7/7、本地 strict direct-SAB `tests/test_unit_*.sla` sweep 108/108 files、262/262 cases、host `parallel.sla` strict direct-SAB 1/1。

## 期望

SAB direct backend 应在函数退出前正确清理未被移动的标量参数，尤其是这种 thin wrapper 中仅作为调用参数
传递的 `i32` 参数。SA/SAB 对 focused filter 的行为也应一致：表达式链产生的查询临时值应在测试函数退出前
被正确释放。

当前状态：上述期望已对当前 repro surface 验证通过；全局 roadmap 仍保持开放。
