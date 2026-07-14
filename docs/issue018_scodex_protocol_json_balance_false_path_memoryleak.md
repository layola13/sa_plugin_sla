# issue018: protocol JSON balance false path leaves live register at SA test exit

Date: 2026-07-14
Status: open

## Summary

While adding SLA-native `scodex` protocol JSON round-trip scanning, focused
SA-backend tests that call byte-scanning helpers on JSON envelopes fail with
`MemoryLeak`: a temporary register remains active at test-function exit.

The same source type-checks through `SA_PLUGIN_DEV=1 sa sla check -p
scodex-cli`. The helper implementation can remain in `scodex`, but regular
tests cannot exercise the pointer scanner until this backend cleanup issue is
fixed.

## Repro

Project:

```text
/home/vscode/projects/sla_codex
```

Minimal positive test shape:

```sla
@test "protocol json round trip scans event envelopes"() {
    let configured_json = "{\"id\":\"0\",\"msg\":{\"type\":\"session_configured\"}}";
    let configured_ptr = STR_PTR(configured_json);
    if protocol_json_round_trip_ok(&configured_ptr, STR_LEN(configured_json)) != true {
        panic(19060);
    };
    if protocol_json_round_trip_msg_code(&configured_ptr, STR_LEN(configured_json)) != 3 {
        panic(19061);
    };
}
```

Observed trap:

```text
error[MemoryLeak]: live registers remain at function exit
  in function @test "protocol json round trip scans event envelopes"():
  source_text: "    return"
  register: tmp_1658
  state: Active
```

Minimal unbalanced test shape:

```sla
@test "protocol json envelope balance detects malformed json"() {
    let broken_json = "{\"id\":\"0\",\"msg\":{\"type\":\"task_complete\"}";
    let broken_ptr = STR_PTR(broken_json);
    if protocol_json_envelope_balanced(&broken_ptr, STR_LEN(broken_json)) {
        panic(19073);
    };
}
```

Command:

```sh
cd /home/vscode/projects/sla_codex
SA_PLUGIN_DEV=1 sa sla test packages/scodex-protocol/src/protocol_json.sla --test-backend sa --trace-panic
```

Observed trap:

```text
error[MemoryLeak]: live registers remain at function exit
  in function @test "protocol json envelope balance detects malformed json"():
  source_text: "    return"
  register: tmp_1764
  state: Active
```

Minimal missing-type test shape:

```sla
@test "protocol json round trip rejects malformed envelopes"() {
    let missing_type_json = "{\"id\":\"0\",\"msg\":{}}";
    let missing_type_ptr = STR_PTR(missing_type_json);
    if protocol_json_round_trip_ok(&missing_type_ptr, STR_LEN(missing_type_json)) {
        panic(19070);
    };
}
```

Observed trap:

```text
error[MemoryLeak]: live registers remain at function exit
  in function @test "protocol json round trip rejects malformed envelopes"():
  source_text: "    return"
  register: tmp_1754
  state: Active
```

The direct SAB backend also exits nonzero without additional diagnostics for
the same test shape.

## Impact

`scodex` kept the round-trip scanner API, but removed scanner execution tests
from its regular gate until the backend cleanup issue is fixed. This avoids
blocking unrelated protocol work while preserving the repro here.

## Hypothesis

The helper uses `STR_PTR`, `PTR_BYTE_ADD`, `PTR_READ_U8`, loop-local booleans,
and returns `false` for an unbalanced closing state. The failing path likely
misses cleanup for a pointer or scalar temporary introduced during loop lowering
or final boolean return lowering.

This appears related to the existing register lifecycle / cleanup family of
issues, not to `scodex` protocol semantics.

## Acceptance

- The positive, malformed-balance, and missing-type tests above pass on
  `--test-backend sa`.
- The same tests pass on direct SAB or report precise source-level issues
  instead of backend register leaks.
- `scodex` can re-enable malformed protocol JSON balance coverage without
  source-level workarounds.
