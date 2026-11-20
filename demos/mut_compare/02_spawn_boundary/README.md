# 02 Spawn Boundary: Borrows Must Not Cross a Task Boundary

Rust enforces this with `Send` + `'static`: a closure passed to
`thread::spawn` may not capture a borrow of a stack place. SLA enforces the
same rule with checker guards on the spawn boundary:

- `neg_go_borrow.sla` — `go modify(&number)` while main keeps writing.
  `sa sla check` **rejects** it: the spawned function takes a borrowed
  parameter, "which would dangle across the goroutine boundary; pass an
  owned value or a raw pointer instead". This guard predates the fix line.
- `neg_spawn_closure_borrow.sla` — `thread::spawn(^|| modify(&number))`.
  `sa sla check` **rejects** it with `error.BorrowEscape` since
  sa_plugin_sla `2b65a1dd` (DEF-SLA-SPAWN-CLOSURE-BORROW-ESCAPE). Before
  that fix this file checked, built, and ran, printing `210` — a live
  data race the checker silently allowed.
- `neg_spawn_closure_indirect_borrow.sla` — `let r = &number;` then
  `thread::spawn(^|| modify(r))`. The borrow is first bound to `r`, then
  the closure captures `r`. The guard follows the binding and rejects it
  with `error.BorrowEscape` too. The Rust implementation
  (`layola13/sla` `b06c05ee`) rejects the same file the same way.

The sanctioned crossing is ownership transfer, not a shared borrow:

- `main.sla` — two channels (request/response), 50 ping-pong rounds.
  The worker owns both channel ends. Prints `50`, exit code 0.
- `main.rs` — Rust reference with `std::sync::mpsc`. Same output.

Verified 2026-11-20 on sa 0.1.9 + sa_plugin_sla 2b65a1dd (box bd00ae7b9304):

```bash
SA_PLUGIN_DEV=1 sa sla check demos/mut_compare/02_spawn_boundary/main.sla
SA_PLUGIN_DEV=1 sa sla build-exe demos/mut_compare/02_spawn_boundary/main.sla -o /tmp/mut02 && /tmp/mut02
# prints 50, exit code 0
SA_PLUGIN_DEV=1 sa sla check demos/mut_compare/02_spawn_boundary/neg_go_borrow.sla
# must FAIL (rejection quoted above)
SA_PLUGIN_DEV=1 sa sla check demos/mut_compare/02_spawn_boundary/neg_spawn_closure_borrow.sla
# must FAIL with error.BorrowEscape
SA_PLUGIN_DEV=1 sa sla check demos/mut_compare/02_spawn_boundary/neg_spawn_closure_indirect_borrow.sla
# must FAIL with error.BorrowEscape (indirect capture through `r`)
```

Coordination proofs measured the same day on the same toolchain
(`probe-conc`, box bd00ae7b9304): `Arc<Mutex<i32>>` 4 workers x 250 =
exactly `1000`; three parallel readers summing an `Arc<i32>` 10,000 times
each = `1000000` each. The `Arc<RwLock<i32>>` mix (writer +2 x100, two
readers asserting every read even) is timing-sensitive: `200` in 22 of 28
runs across both the old and the new plugin builds, the other 6 ending in
a runtime panic (code 17) — reported as a rate, not a stable exact value.
