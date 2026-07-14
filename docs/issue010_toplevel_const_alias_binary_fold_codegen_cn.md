# issue010: 顶层 const 初始化器为 `.identifier` / `.binary_expr` 时 codegen 崩溃为 `CodegenError`

日期：2026-07-13
状态：fixed (SA-text 与 direct SAB 均有入库回归覆盖；2026-07-14 复验)

## Summary

`src/codegen.zig` 的 `emitTopLevelConstDecl` 之前对顶层 `const` 初始化器的两种形态走 `else => return CodegenError.CodegenError`：

- `.identifier`：`const B: int = A;`（顶层 const 之间的标量别名）
- `.binary_expr`：`const N: int = 0 - 1;`（用以表达负整数字面量的标量二元折叠）

代码生成遇到上面任何一种声明就直接出口 `CodegenError`，导致整个文件无法 lowering 成 SA。`lua_sla/src_lua/lvm.sla` 里同时存在大量这两类声明（负整数常量、`os.time()` 的 epoch 借助 `0 - 1` 表达、const 别名等），一旦走到 `sa sla build`/`sa sla test` 即直接失败。

## Repro

最小复现 (写两个文件后 `sa sla check / sa sla build`)：

```sla
// /tmp/repro_const.sla
const A: int = 42;
const B: int = A;
fn trigger() -> int {
    return B;
}
```

```sla
// /tmp/repro_binary.sla
const A: int = 42;
const B: int = 0 - A;
const NEG_ONE: int = 0 - 1;
fn trigger() -> int {
    return B + NEG_ONE;
}
```

修复前：`sa sla check` / `sa sla build` 直接 ExitFailure，codegen 在 `emitTopLevelConstDecl` 的 `else` 分支返回 `CodegenError.CodegenError`。

修复后（本机实测）：

```text
env SA_PLUGIN_DEV=1 sa sla check /tmp/repro_const.sla   # EXIT=0  => [PASS] trigger
env SA_PLUGIN_DEV=1 sa sla build /tmp/repro_binary.sla --out /tmp/r.sa   # EXIT=0 => [PASS] binary const fold
env SA_PLUGIN_DEV=1 sa sla build /home/vscode/projects/lua_sla/src_lua/lvm.sla --out /tmp/lvm_built.sa
# EXIT=0，生成 ~11 MB SA 文件，codegen 全程不退
```

## Root Cause

`emitTopLevelConstDecl` 没有为顶层 const 初始化器里的：

1. `.identifier` —— 标量 const 间的别名（`const B = A;`），以及
2. `.binary_expr` —— `add/sub/mul/div/mod/bit_*/shl/shr` 形式的标量二元表达式（典型 `const N: int = 0 - 1;`）

维护可解析的标量信息，整体走 `else => return CodegenError.CodegenError`。这与 SLA C 参考移植里大量使用的代码风格冲突：

- Lua 5.x 源经常把负值写成 `0 - k` 或 `0 - n`（避免 SLA 解析器对一元负号的歧义）。
- `lua_sla` 多处用 `const B = A;` 让 codegen 的命名空间与 C 端别名一一对应。

在 Lua 5.x 大文件（`lvm.sla` 约 1.3 万行）上，这两类声明必然出现，把 `sa sla build` 直接卡死。

## Fix

在 `src/codegen.zig` 引入两条 pipeline：

1. `scalarConstantNodeFor(expr: *const ast.Node) ?*const ast.Node`：把表达式解析成 `global_scalar_consts` 表里的字面量节点；`.identifier` 走别名链，`.literal` 直接返回。
2. `foldTopLevelBinaryConst(bin: *const ast.BinaryExpr) CodegenError!?*ast.Node`：对 `add/sub/mul/div/mod/bit_and/bit_or/bit_xor/shl/shr` 等运算，用两侧 `scalarConstantNodeFor` 得到字面量后做折叠，分配一个新的 `*ast.Node` 字面量并返回；不可折叠（非标量、未注册）时返回 `null`。

`generate()` 里新增一组阶段，按顺序处理顶层 const：

- **3a 注册 const 名**：扫描所有顶层 `const`，把 `.literal`（int/float/bool）直接登记到 `global_scalar_consts`。.identifier/.binary_expr 此时尚未解析（其依赖项可能后面才出现）。
- **3b 登记字面量 scalar**：再次扫描顶层 const，对纯 `.literal` 初始化器登记 name→literal node（重复扫一次，保证 import 顺序无关）。
- **3c 迭代折叠 scalar 别名**：重复扫描顶层 const，对 `.identifier` 形态借 `global_scalar_consts.get(target)` 把别名解析成原字面量再登记，直到集合不再变化。
- **3c-bis 迭代折叠 binary ↔ alias**：重复扫描，对 `.binary_expr` 形态调 `foldTopLevelBinaryConst`：成功则登记新折叠 literal；失败则继续下一轮，让 alias chain 稳定后再折。
- **3d emit**：上面阶段稳定后 emit；中段 `emitTopLevelConstDecl` 此时拿到已折叠的 `global_scalar_consts` 名表即可直接处理本声明。

`emitTopLevelConstDecl`：

- `.identifier`：若 `global_scalar_consts.contains(c.name)` 视为已折叠，return（scalar const 在 use site 直接走 metadata，不需要 SA `@const` 绑定）；未在 `global_const_bindings` 出现的未知 alias 仍保留 `CodegenError` 出口以免静默通过。
- `.binary_expr`：同样：已折叠则 return，否则保留 `CodegenError` 出口。

结果：`lua_sla/src_lua/lvm.sla` 这一万三千行文件能从 `sa sla check`（5 gate 全 EXIT=0）一路走到 `sa sla build --out /tmp/lvm_built.sa` 生成完整 SA（~11 MB），再到 `sa sla test --test-backend sa` 的子进程 `sa test src_lua/lvm.test.sa --jobs auto` 阶段。

## 提交说明

本修复已在本地 working tree 完成，并通过上述 repro 验证。当前 sa_plugin_sla 工作树有大量与本修复无关的 pre-existing 改动，无法干净地单独 split commit 而暂存于此。等仓库 stash/diff 清理后再做单独 commit：

```text
zig build
cp zig-out/lib/libsla.so /home/vscode/.local/share/sa_plugins/installed/sla/current/libsla.so
sha=$(sha256sum zig-out/lib/libsla.so | awk '{print $1}')
sed -i "s/^sha256=.*/sha256=$sha/" /home/vscode/.local/share/sa_plugins/installed/sla/current/sap.lock
```

## Regression

入库回归：

- `tests/test_unit_toplevel_const_alias.sla`
- `tests/test_unit_toplevel_const_binary_fold.sla`

2026-07-14 复验发现 direct SAB 原先只收集 literal scalar const，没有像 SA-text 一样迭代折叠 `.identifier` alias 与 `.binary_expr`，因此 `const B = A; return B;` 在 SAB 中会生成未声明寄存器 `B`。`src/sab_codegen.zig` 现已补齐同一套 scalar const alias/binary fold 收集逻辑。

串行验证：

```sh
zig build -j1 --summary all
./zig-out/bin/sla-local-cli sla test tests/test_unit_toplevel_const_alias.sla --test-backend sa --jobs 1 --trace-panic
./zig-out/bin/sla-local-cli sla test tests/test_unit_toplevel_const_alias.sla --test-backend sab --jobs 1 --trace-panic
./zig-out/bin/sla-local-cli sla test tests/test_unit_toplevel_const_binary_fold.sla --test-backend sa --jobs 1 --trace-panic
./zig-out/bin/sla-local-cli sla test tests/test_unit_toplevel_const_binary_fold.sla --test-backend sab --jobs 1 --trace-panic
```
