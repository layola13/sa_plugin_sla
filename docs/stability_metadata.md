# SLA Stability Metadata

> This is the English counterpart of the Chinese document [SLA 稳定性元数据](./stability_metadata_cn.md).

Date: 2026-07-06

## Scope

`sa_plugin_sla` only provides the low-level contract and verification tooling for stability metadata. The specific label meanings, business fixtures, thresholds, runner output, and user-facing commitments are maintained by downstream projects.

This avoids mistaking downstream project state for capability claims of this compiler repository.

## CLI

Output the JSON Schema:

```sh
SA_PLUGIN_DEV=1 sa sla stability schema
```

Verify a manifest:

```sh
SA_PLUGIN_DEV=1 sa sla stability verify stability.json --json
```

The verification result contains:

- `valid`: whether the manifest passed structural validation.
- `labels`: the number of declared labels.
- `artifacts`: the number of recorded artifacts.
- `evidence`: the number of recorded evidence entries.
- `errors`: structural, label-reference, or evidence-status errors.

## Manifest Shape

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

Label names are only checked for format and reference validity; the compiler does not interpret labels such as `stable-demo`, `verified-sab-backend`, or `experimental-parallel` as built-in semantics.
