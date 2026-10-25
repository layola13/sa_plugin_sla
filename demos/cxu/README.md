# CXU 模块提炼演示（demos/cxu）

把 CXU（codex-react-ui）的每个模块提炼成一个可独立运行的 SLA/SA 演示：
演示通过 = 该模块所需的 sa_std 与 SLA 能力被实证；演示撞墙 = 撞墙点即
SLA/SA 的改进项，先补地基再继续。总体路线图与排期见 sala
01_overview/08_cxu_rewrite_roadmap.html。

| 演示 | 提炼自 | 状态 |
|---|---|---|
| D1 01_bridge_stdio | 各 CLI 桥的双向 stdio 内核（spawn + JSON-RPC 行协议） | 已落地（见下） |
| D2 HTTP/WS/SSE 服务面 | server 的 hono/ws 层 | 待开工 |
| D3 会话与持久化 | storage（SQLite + JSON） | 待开工 |
| D4 配置面 | config（TOML + env） | 待开工（前置 P0-6 TOML） |
| D5 终端 PTY | terminalPty.ts | 待开工（前置 P0-2 PTY） |
| D6 文件监视 | fs.watch 用法群 | 待开工（前置 P0-3） |
| D7 代码图谱 | saVmTreeSitter / saVmCodeGraph | 待开工（前置 P0-4） |
| D8 认证小件 | bcrypt / keyring | 待开工（前置 P0-6） |
| D9 VM 工具面 | saVmTool / JEV + 16_policy | 待开工（前置 D7） |
| D10 静态与产物服务 | server 静态面 | 待开工（前置 D2） |
| D11 free-key 服务 | free-key server | 待开工（前置 D2） |
| D12 前端微缩 | web 对话屏（SAX + airlock） | 待开工（前置 D2） |

## D1 01_bridge_stdio

- `main.sla`：用 `sa_std_process_spawn_bidi`（P0-1，sci 94c4f654）以可写
  stdin 方式 spawn `/bin/cat`，写入一行 JSON-RPC 请求，关闭 stdin 后把
  stdout 读到 EOF，校验往返长度与首尾字节，再 wait 收割退出码。
- `argv1.sa`：单参数 argv 填充宏（效 codexmini 的 X_ARGV_FILL；
  .sla 里不允许 ptr→u64 转换，故在 SA 层填 [u64; 2]）。
- 字节级回显一致性由 sci 的 C 驱动测试锁定
  （tests/sa_std_runtime.zig 的 bidi 用例）；本演示证明的是 SLA 表面。

```bash
export PATH=/content/sa_all/sci/zig-out/bin:$PATH
SA_PLUGIN_DEV=1 sa build-exe demos/cxu/01_bridge_stdio/main.sla
./main    # 输出 d1 bridge stdio ok，退出码 0
SA_PLUGIN_DEV=1 sa sla test demos/cxu/01_bridge_stdio/main.sla
```
