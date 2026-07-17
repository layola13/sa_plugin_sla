# issue001: switch over local u8 emits double cleanup / UseAfterMove

Date: 2026-07-13

Status: fixed/current-non-repro. Rechecked on 2026-07-17 with focused
installed/dev SA and strict direct-SAB fixtures.

## Context

While implementing the pure-SLA music parser in `/home/vscode/projects/sla_music_cli`,
`sa sla check` accepted the source, but both SAB and SA test backends failed after
introducing a `switch` over a local `u8`.

## Observed commands

```sh
cd /home/vscode/projects/sla_music_cli
SA_PLUGIN_DEV=1 sa sla check src/music_parse.sla
SA_PLUGIN_DEV=1 sa sla test src/music_parse.sla --test-backend sab --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test src/music_parse.sla --test-backend sa --jobs 1 --trace-panic
```

`check` passed, SAB failed with:

```text
SAB Error: failed to encode SAB ... error.VerificationTrap
```

The SA backend exposed the underlying verifier trap:

```text
error[UseAfterMove]: moved value is no longer usable
  in function @sla__music_keyword(source: ptr, span: ptr) -> ptr:
  source_text: "    !first"
  register: first
  state: expected Consumed, actual Consumed
```

## Reduced shape

The problematic source shape was:

```sla
enum Keyword {
    Unknown,
    Track,
}

fn classify(source: &Vec<u8>, index: u64) -> Keyword {
    let first: u8 = source[index];
    switch first {
        116 => {
            return Keyword::Track;
        },
        default => {},
    };
    return Keyword::Unknown;
}
```

## Expected

Switching over a primitive copy value should not emit a second cleanup for the
same local after the switch target has already been consumed/released.

## Workaround

Avoid `switch` over a local primitive in the music parser for now. Use enum
classification helpers plus exhaustive `match`, which is covered by
`tests/test_unit_enum_match.sla`.

## Resolution

The switch-expression statement and local-scrutinee cleanup paths are covered by
the later direct-SAB switch lowering and cleanup fixes. The focused regression is
`tests/test_unit_switch_local_scrutinee_cleanup.sla`.

2026-07-17 serial focused verification:

```sh
SA_PLUGIN_DEV=1 sa sla test tests/test_unit_switch_local_scrutinee_cleanup.sla --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 SLA_SAB_NO_FALLBACK=1 sa sla test tests/test_unit_switch_local_scrutinee_cleanup.sla --test-backend sab --jobs 1 --trace-panic
```

Both backends passed 2/2. No full suite was run.
