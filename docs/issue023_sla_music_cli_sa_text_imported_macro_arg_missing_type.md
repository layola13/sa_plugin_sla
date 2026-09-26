# issue023: sla_music_cli SA-text build fails resolving imported macro argument type

日期：2026-07-15
状态：FIXED / VERIFIED

## Summary

`sla_music_cli/src/main.sla` 的真实 CLI 构建走 SA-text backend 时，在 imported macro 参数类型解析处失败。music 模块单测通过，当前阻塞发生在编译器 codegen 对 imported macro call arg 的类型恢复路径。

## Repro

```sh
cd /home/vscode/projects/sla_music_cli
SA_PLUGIN_DEV=1 sa sla build src/main.sla --out /tmp/slamusic-main.sa
```

结果：

```text
Codegen Error: failed to generate SA code: error.CodegenError
/home/vscode/projects/sa_plugins/sa_plugin_sla/src/codegen.zig:9139 in genImportedMacroArg
    const arg_ty = self.resolvedTypeForExpr(arg) orelse return CodegenError.CodegenError;
```

## Suspected Surface

`main.sla` 通过 `cli.sla` / `io.sla` 使用多种 imported macro：

- `ENV_ARGS_JSON()`
- `PTR_BYTE_ADD(...)`
- `PTR_READ_U8(...)`
- `STR_PTR(...)`
- `STR_LEN(...)`
- `sa_fs_write_file(...)`
- `FS_READ_BUFFER_*`

其中某个 imported macro 参数在 typecheck 后没有被 `resolvedTypeForExpr(arg)` 找回，导致 SA-text codegen 直接返回 `CodegenError`。这更像是 macro arg type fallback 缺口，而不是 music source 语义错误。

## Suggested Investigation

重点检查：

- `src/codegen.zig`
- `genImportedMacroArg`
- `genImportedMacroCall`
- `resolvedTypeForExpr`
- imported macro 参数是 identifier、literal、pointer arithmetic 结果或 len-call 结果时的 fallback 规则

可用 debug narrowing：临时打印 `genImportedMacroArg` 失败时的 macro 名、arg index、arg AST kind，再抽出最小 `.sla` fixture。

## Acceptance

修复后至少需要：

```sh
cd /home/vscode/projects/sla_music_cli
SA_PLUGIN_DEV=1 sa sla build src/main.sla --out /tmp/slamusic-main.sa
SA_PLUGIN_DEV=1 sa sla build-exe src/main.sla -o /tmp/slamusic-cli
```

并增加 compiler 侧最小回归，覆盖 imported macro arg 类型缺失时应从 local/expr fallback 恢复，而不是裸返回 `CodegenError`。

## Resolution

`src/codegen.zig` 的 expression type fallback 现在覆盖：

- `len(...) -> usize`
- comparison / logical binary expressions -> `bool`
- `ENV_ARGS_JSON`、`ENV_VARS_JSON`、`ENV_SPLIT_PATHS_JSON`、
  `ENV_JOIN_PATHS_JSON` 这类 imported buffer-producing macro -> `u64`

Imported macro 参数路径统一通过 `importedMacroArgType()` 取回类型，不再在
多个 materialization/address 分支中直接裸用缺失的
`resolvedTypeForExpr(...)`。

`src/plugin_tests.zig` 的
`sla sa codegen resolves local binding types for imported macro args` 回归现在覆盖：

- `sa_fs_write_file(..., len(bytes))`
- `ENV_ARGS_JSON()`
- `ENV_BUFFER_DATA(buffer)`
- `ENV_BUFFER_LEN(buffer)`

## Verification

以下命令串行通过：

```sh
zig test src/plugin_tests.zig \
  --test-filter "sla sa codegen resolves local binding types for imported macro args"
zig build -j1 --summary all
SA_PLUGIN_DEV=1 sa plugin install --dev .
SA_PLUGIN_DEV=1 sa sla help

cd /home/vscode/projects/sla_music_cli
SA_PLUGIN_DEV=1 sa sla build src/main.sla --out /tmp/slamusic-main.sa
```

真实 SA-text repro 已通过。`build-exe` 的 direct SAB `tmp_167`
`UseAfterMove` 是独立的 issue022，不影响本 issue 的 SA-text closure。
