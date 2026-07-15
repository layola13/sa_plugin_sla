# issue023: sla_music_cli SA-text build fails resolving imported macro argument type

日期：2026-07-15
状态：OPEN

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
