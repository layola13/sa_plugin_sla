# issue013: 借用参数被赋值移动后，函数尾部仍生成 `!param`，触发 UseAfterMove

- 状态: fixed（入库回归覆盖；2026-07-14 本地 SA/SAB 复验）
- 类别: codegen / 借用约束
- 相关 issue: issue011（同属借用/路径状态的尾部清理）

## 现象

当函数声明一个借用形参 `p: &T`，但在函数体内用普通 `let` 把该借用形参按值绑定到另一个本地：

```sla
struct Foo { x: int, }

fn use(vm: &Foo, env: &Foo) -> int {
    let _env = env;
    return 0;
}

@test "repro"() {
    let g = Foo { x: 7 };
    use(&g, &g);
}
```

`sa sla test repro.sla --test-backend sa` 会失败：

```
error[UseAfterMove]: moved value is no longer usable
  in function @sla__use(vm: ptr, env: ptr) -> i64:
  line ...:     !env
  register: env
  state: expected Consumed, actual Consumed
{"trap":"UseAfterMove","trap_code":1009,...,"source_text":"    !env","register":"env","state":"expected Consumed, actual Consumed"}
```

## 期望行为

二选一对编译器更具可用性：

1. `let _env = env;`（其中 `env` 是借用形参）应解答为借用句柄的“移动 / 转移”：env 的借用句柄从 `env` 转移到 `_env`，函数尾部 cleanup 应针对 `_env`（且仅当其未被进一步移动时），不再对 `env` 发 `!env`。
2. 或者语义上禁止 `let _X = borrowed_param;` 并给出前端诊断（借用类型不实现 by-value move），强制用户要么直接用 `env`，要么显式 `let _env = &env;`（借用复制）。

## 实际行为（当前 bug）

后端在 type-check / codegen 中按值移动借用的标记后：

- `env` 被 type checker 标记为 `.consumed`（被 `let _env = env;` 消耗），但 `borrow_source_temps['env']` 的借用句柄在 codegen 中通过 `move_borrow_address_temps` 转移到 `_env`，同时 `borrow_source_temps.remove('env')`。
- 然而在某个跨 return / 尾部 cleanup 路径上，仍向输出 SA 里写出 `!env`（即便 `env` 已经处于 `Consumed` 状态）。VM 验证在执行 `!env` 时发现 `env` 寄存器状态为 `Consumed`，按定义无法再次释放，于是抛出 `UseAfterMove`（trap_code 1009）。

排查路径也已经指向 `src/type_checker.zig::checkBlock`（把仍 `active` 的本地加入 `cleanups`），以及 `src/codegen.zig::emitRelease`（对 `borrow_source_temps` 的尾清理逻辑判断 `consumed_bindings`）。存在两处中之一未在“借用 value 被移动”的情况下正确跳过 `!env`：
- `type_checker.zig:2920` 附近函数作用域遍历仍可能把 `env` 当 active 加入 cleanup list（当函数体末尾不是 return_stmt 而 `env` 的状态保存方式与移动语义不一致时）。
- `codegen.zig:emitFunctionTailCleanups` / `emitRelease` 需要双向校验：仅当 binding 既未被显式 consume 又确实在 `borrow_source_temps` / `refcell_borrow_handles` 中时才发出 `!name`。

## 最小重现

文件 `/tmp/repro_borrow_alias.sla`（见上文 `fn use` 示例）。直接：

```bash
cd /home/vscode/projects/sa_plugins/sa_plugin_sla
rm -rf .sla-cache && env SA_PLUGIN_DEV=1 sa sla test /tmp/repro_borrow_alias.sla --test-backend sa
```

会输出上文的 `UseAfterMove` 与 `EXIT=0`（sa 把 trap 视为 test 失败但外层 exit code 为 0；以 trap JSON 为准）。

## 影响范围

- 用户散到任何用 `let _x = borrowed_param;` 的写法都会破坏；lua 端的 lvm.sla 在迁移过程中通过反复把 `let _x = x;`（其中 x 是借用）移除来规避；这是被本 issue 抓到的典型案例（lua_sla 中的 `vm_exec_gettabup` / `vm_exec_settabup` 与 `let _env = env;`）。
- 编译期（sla check）不会发现，只在 `sa` backend test 时以 trap 暴露，因此对用户更隐蔽。

## 临时规避（用户端）

把形如 `let _X = borrowed_param;` 的死绑定移除即可；当不是死绑定而是真的需要新名字（例如改名或别名）时，建议改为 `let _X = &borrowed_param;`（显式再借用）。

## 修复与回归

入库回归：

```text
tests/test_unit_borrow_param_alias_cleanup.sla
```

覆盖两种形态：

- `let alias: &T = env; return 0;`：alias 死绑定时，函数尾部不能再释放已转移的 `env`。
- `let alias: &T = env; return alias.value;`：alias 被读取时，cleanup 仍只能落在活跃 alias/source 状态上，不能双重释放源借用参数。

当前 TypeChecker cleanup 收集会跳过已经被其它 active borrow alias 接管的 borrow-like source；SA-text 与 direct SAB 都通过同一回归。

串行验证：

```sh
./zig-out/bin/sla-local-cli sla test tests/test_unit_borrow_param_alias_cleanup.sla --test-backend sa --jobs 1 --trace-panic
./zig-out/bin/sla-local-cli sla test tests/test_unit_borrow_param_alias_cleanup.sla --test-backend sab --jobs 1 --trace-panic
```
