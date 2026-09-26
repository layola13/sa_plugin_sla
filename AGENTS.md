在 Windows PowerShell 环境中处理包含中文的文件时，必须显式使用 UTF-8 编码。

读取文本文件优先使用：Get-Content -Encoding UTF8
写入文本文件优先使用 PowerShell 的 Set-Content -Encoding UTF8 或 Add-Content -Encoding UTF8
不要用未指定编码的 Get-Content / Set-Content / Out-File 处理中文、Markdown、TOML、JSON 等文本文件
终端输出出现乱码时，先用 UTF-8 重新读取确认，不要直接认定文件内容损坏

SLA 插件以 dev 模式运行：每次调用 `sa sla` 子命令前必须设置 `SA_PLUGIN_DEV=1` 环境变量（例：`SA_PLUGIN_DEV=1 sa sla help`），否则会调用到系统已安装的正式版本而非仓库的 dev 版本。安装/更新插件用：`SA_PLUGIN_DEV=1 sa plugin install --dev .`。

## Codex CLI 文件读写约定

在 Codex CLI 环境里读写文件，正确做法是通过 `shell_command` 工具跑 PowerShell（注意：当前 harness 未暴露独立的 read_file/write_file/edit 工具，apply_patch 不是给 agent 的直接接口，不要去 PowerShell 里调用 apply_patch.bat）：

- 读：Get-Content -Encoding UTF8 <file>
- 写：Set-Content -Encoding UTF8 <file> -Value ...(或 Add-Content -Encoding UTF8)
- 新建/改文件：同样用 Set-Content -Encoding UTF8
