# issue051: SLA signed parse middle struct field loses negative flag

Status: open.

While extending `sla_music_cli` editor context records with three trailing
signed stem-x coordinates, both generated-SA and direct SAB changed the middle
parsed value from `-9` to `9`.

The source bytes are correct and end with:

```text
 1031 -9 -9\n
```

The parser returns a small scalar-only struct:

```sla
struct SignedParse {
    ok: bool,
    negative: bool,
    value: u64,
    next_offset: u64,
}

let stem_x_local = read_i64_until(bytes, offset, 32);
let stem_x = read_i64_until(bytes, stem_x_local.next_offset, 32);
let stem_x_page = read_i64_until(bytes, stem_x.next_offset, 10);

let stem_x_value = stem_x.value as i64;
if stem_x.negative == true {
    stem_x_value = 0 - stem_x_value;
};
```

Observed behavior:

- `stem_x_local` reads `1031` correctly.
- `stem_x.value` reads `9` correctly.
- `stem_x.negative` is observed as `false`, producing `9` instead of `-9`.
- The final `stem_x_page` value reads `-9` correctly.
- The original struct field is `-9` before serialization, and byte-level
  assertions prove both minus signs are present in the serialized record.

Observed commands:

```sh
cd /home/vscode/projects/sla_music_cli
SA_PLUGIN_DEV=1 sa sla test src/music_ir.sla --test-backend sa --jobs 1 --trace-panic
SA_PLUGIN_DEV=1 sa sla test src/music_ir.sla --test-backend sab --jobs 1 --trace-panic
```

Both backends fail the same regression assertion with the middle value equal
to positive `9`. This is not an SA-text-only lowering disagreement.

Expected behavior:

- Reading `stem_x.next_offset` to parse the following field must not alter or
  invalidate later scalar projections from `stem_x`.
- All three scalar-only parse results must retain their own `negative` flag.

Likely area:

- repeated projections from a scalar-only local struct after one projection is
  used as the argument to a following helper call;
- local aggregate aliasing or temporary reuse shared by generated-SA and SAB
  lowering.

Music-side workaround:

- Capture `stem_x.negative`, `stem_x.value`, and `stem_x.next_offset` into
  scalar locals before calling the parser for `stem_x_page`.

