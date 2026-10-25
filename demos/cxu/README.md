# CXU 模块提炼演示（demos/cxu）

把 CXU（codex-react-ui）的每个模块提炼成一个可独立运行的 SLA/SA 演示：
演示通过 = 该模块所需的 sa_std 与 SLA 能力被实证；演示撞墙 = 撞墙点即
SLA/SA 的改进项，先补地基再继续。总体路线图与排期见 sala
01_overview/08_cxu_rewrite_roadmap.html。

| 演示 | 提炼自 | 状态 |
|---|---|---|
| D1 01_bridge_stdio | 各 CLI 桥的双向 stdio 内核（spawn + JSON-RPC 行协议） | 已落地（见下） |
| D2 HTTP/WS/SSE 服务面 | server 的 hono/ws 层 | 已落地（见下） |
| D3 会话与持久化 | storage（SQLite + JSON） | 已落地（见下） |
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

## D2 02_http_ws_sse

- `server.sla`：v2 服务器面三件套——`GET /hello` 返回 JSON、
  `GET /events` 以 stream 响应发三条 SSE tick、`GET /ws` 升级 WebSocket
  回显一帧后关闭；服务满三请求打印 `d2 server ok` 退出。
- `client.sla`：用内置 ws_client 连 `/ws` 发文本帧并逐字节验回显。
- `byteseq.sa`：(ptr, len) 字节比较宏（指针出参式；.sla 代码生成拿不到
  普通 .sa 宏的值出参寄存器，故效 codexmini X_STR_EQ 改指针式）。
- `run.sh`：构建两端、curl 验 HTTP/SSE、client 验 WS、全绿打印
  `d2 http/ws/sse ok`。

实测踩到的契约（.sai 未注明，记此备忘）：

1. v2 WebSocket 是非阻塞 + poll 驱动：`websocket_read_v2` 无数据时返回
   状态 1（would_block），须先 `websocket_poll_v2`（readable=1）再读、
   遇 1 重试；`websocket_upgrade*` 成功后请求句柄已被实现消费，
   不可再 req_free。
2. `.sai` 里返回写作 `-> &ptr` 的 extern（如 ws_client_buffer_data），
   其结果流入 ptr 形参前需在 let 上显式标注 `: ptr` 才会强制转换。

```bash
bash demos/cxu/02_http_ws_sse/run.sh
```

## D3 03_store_session

- `main.sla`：经限定导入 `plugin/node/node_extra.sai` 用 node 插件的
  SQLite 门面（`sa_node_plugin_sqlite_*`）开库建 sessions 表，插入两条
  会话（payload 为 JSON 文本）、更新轮次，再以 query_json 取回并用
  sa_std JSON 面解析嵌套 payload（校验 model 与 temp）、做
  stringify/parse 往返，全过打印 `d3 store ok`。
- `run.sh`：构建运行后另用 python3 sqlite3 独立打开数据库核对行数、
  轮次与 payload，全绿打印 `d3 store+json ok`。
- 注意：sa_plugin_db 是自研列存引擎、不是 SQLite；SA 生态的真 SQLite
  入口就是 node 插件门面（sci 的 sa_std/plugin_sqlite.sa 宏包装之）。

本演示倒逼出的修复（均已落地）：

1. SLA 前端原先不解析 `plugin/<name>/...` 限定导入（只有 SA 阶段的
   resolver 认）——plugin_imports.zig 已补 SLA 侧解析，按
   SA_PLUGINS_HOME/installed/<name>/current/sa/ 定位接口文件，
   生成的 .sa 保留限定拼写供 SA 阶段链接。
2. http-client 插件 sap.json 广告了已内置 std 的核心 .sai，符号冒烟
   必然失败导致其与依赖者（node）永远装不上——已去广告（.sai 文件
   留仓作文档，与 http-server 先例一致）。
3. node 插件 build.zig 的 http 桥模块根指向瘦身时已删除的文件——已
   改指 sci src/runtime 的 sa_http_client.zig / sa_http_server.zig；
   两核心的共享文件改走命名导入（sci 的 "sio" 先例），避免同一文件
   落入两个模块。

```bash
bash demos/cxu/03_store_session/run.sh
```
