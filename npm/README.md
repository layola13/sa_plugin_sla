# npm — `@slalang/sla` npm 分发（esbuild 式 7 包）

meta 包 `@slalang/sla`（launcher + `bin/sla`）配 6 个平台子包。
npm 按 `os`/`cpu` 自动只装命中平台的那一个；`@salang/sa` 为硬依赖
（sla 的 build-exe/build-wasm/test 要调 `sa` 宿主，launcher 已把真 `sa`
放到 PATH 上，无需 `SA_PLUGIN_DEV`）。

```
npm/
  packages/sla/                # @slalang/sla：bin/sla.js launcher + 文档
  packages/sla-linux-x64/ ...  # 各平台子包：bin/sla(.exe) + package.json + README
  tools/stage-sla-binaries.sh  # 从本地构建产物 stage 二进制
  tools/fetch-sla-binaries.sh / .ps1  # 从 GitHub Release 拉二进制（发布机用）
  tools/publish-all-sla.sh / .ps1     # 一条命令发 7 个包
```

## 版本同步

跟 `@salang/sa` 同版本线（当前 0.1.3）：7 个包版本号 + meta 的 pins
（`dependencies.@salang/sa` 与 6 个 optionalDependencies）全一致。
`sla --version` 取构建时 git tag，流程固定为
**打 tag → 重编 6 平台 → check → publish**。

## 发布（需 slalang 组织发布权限）

```sh
npm login
git pull && sh npm/tools/fetch-sla-binaries.sh --version <VER>  # 或已 stage 则跳过
sh npm/tools/check-sla-versions.sh   # 若有（对齐校验）
sh npm/tools/publish-all-sla.sh      # 依次发布 7 个包
npm install -g @slalang/sla && sla --version   # 验证
```

Windows：`powershell npm/tools/fetch-sla-binaries.ps1 -Version <VER>`，
`powershell npm/tools/publish-all-sla.ps1`。scope 包必须 `--access public`
（脚本内已带）。
