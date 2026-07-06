# SLA 稳定性元数据

日期：2026-07-06

## 范围

`sa_plugin_sla` 只提供稳定性元数据的底层契约和验证工具。具体标签含义、业务 fixture、阈值、runner 输出和用户承诺由下游项目维护。

这避免把下游项目状态误写成本编译器仓库的能力声明。

## CLI

输出 JSON Schema：

```sh
SA_PLUGIN_DEV=1 sa sla stability schema
```

验证 manifest：

```sh
SA_PLUGIN_DEV=1 sa sla stability verify stability.json --json
```

验证结果包含：

- `valid`：manifest 是否通过结构验证。
- `labels`：声明的标签数量。
- `artifacts`：记录的 artifact 数量。
- `evidence`：记录的证据数量。
- `errors`：结构、标签引用或证据状态错误。

## Manifest 形状

```json
{
  "schema_version": 1,
  "project": "downstream-project",
  "labels": [
    { "name": "stable-demo", "description": "User-facing demo with repeatable verification evidence." },
    { "name": "verified-sa-backend", "description": "SA-text backend verification passed." },
    { "name": "verified-sab-backend", "description": "Direct SAB verification passed." }
  ],
  "artifacts": [
    {
      "path": "lib/parallel.sla",
      "labels": ["verified-sab-backend"],
      "evidence": [
        { "kind": "command", "status": "pass", "command": "SA_PLUGIN_DEV=1 sa sla test lib/parallel.sla --test-backend sab" }
      ]
    }
  ]
}
```

标签名只做格式和引用校验；编译器不会把 `stable-demo`、`verified-sab-backend`、`experimental-parallel` 等标签解释成内置语义。
