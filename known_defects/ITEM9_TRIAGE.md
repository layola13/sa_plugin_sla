# Item 9 — SAB path non-termination + memory blowup: TRIAGE

BG line, 2026-10-28. Trigger: AH2-retest §5 (FIX_TESTS_WAVE2B.md):
6 test files × 2 serial rounds under `sa test`, zero tests ever
completed; SAB child spinning at 126–531% CPU; miniSecondTurn-
Anchoring OOM-killed twice (anon-rss ≈ 52 GB / 51.6 GB, dmesg).
This triage phase-isolates the smallest entry, the egb probe
(`_defects/probes/t2b_egb_probe.sla`, 27 lines, 2 tests touching
only rpg_jb_assign / rpg_jb_doc / rpg_free_doc of
backends/relay-config relayProtocolGateway.sla). All runs capped
(ulimit -v 12 GB, timeout -s KILL), serial. Scripts:
`scripts/triage9.sh`, `scripts/triage9b.sh` (BG local masters).

## Phase isolation (egb probe)

| phase | result |
|---|---|
| `sa sla check` | rc=0, peak RSS 32 MB |
| `sa sla build` (SA text) | rc=0, peak RSS 53 MB |
| `sa sla test --test-backend sa` | **terminates in seconds**, rc=1, peak 204 MB — PhiStateConflict in `@sla__rpg_free_doc` (register `doc`: Active via L_ELSE_93 vs Consumed at L_MERGE_94) |
| `sa sla test --test-backend sab` | **never terminates**: killed at 240 s cap, rc=137, tree peak RSS 5,103 MB, ≈429 CPU-seconds, zero test output |
| import-only variant (same imports, trivial test body, no rpg calls) | rc=0 PASS in seconds, peak 42 MB, **.sab = 678 bytes** |
| full probe .sab artifact | **88,307,431 bytes** (`.sla-cache/sab/t2b_egb_probe-*.sab`) |

Live process anatomy of the SAB run: the plugin parent process
(`sa sla test`, single thread) first balloons to RSS 3.36 GB
(SAB lowering + module load), then waits in `do_wait` on the
interpreter child (`sa test <file>.sab`), whose main thread sits
in `futex_wait_queue` while **two worker threads run at R state,
~99 s utime each** — the interpreter's worker pool spinning.
Independent corroboration the same hour: BI line's own probe
(`bi_probe_sm.sab` child) was observed at 203% CPU with 14:21
CPU-minutes accumulated, RSS 1.84 GB — same signature, another
line, another worktree.

## Verdict

1. **Primary: SAB emission blowup, reachable-set driven.** The
   emitter is dead-code aware (import-only → 678-byte SAB), but
   the reachable subgraph of just three JSON-builder functions
   expands to an 88 MB SAB, while the SA-text path compiles the
   same graph at 53 MB peak. The SAB emitter evidently re-emits
   shared subgraphs per instantiation/call site (std-macro
   fragments and/or generic bodies along the JSON call tree)
   instead of sharing one emission — combinatorial duplication.
   Parent-process RSS (3.36 GB here; AH2 saw 12–28 GB) tracks
   module size at ~40× inflation.
2. **Secondary: SAB interpreter non-termination on the bloated
   module.** Worker threads spin with zero completed tests in
   240 s (≈429 CPU-seconds). Whether the spin is a mis-lowered
   loop inside duplicated code or scheduler livelock cannot be
   separated at this layer — but the SA backend executes the
   same product code to a verdict in seconds, so product-side
   infinite loop is effectively excluded as the primary cause:
   the spin lives in toolchain-emitted code or its interpreter.
3. **Signature B (anchoring OOM) is the same curve at larger
   scale**: a bigger reachable graph (miniBridge) → lowering +
   interpreter structures exceed 50 GB before any test settles.
   One root family, two surface signatures; no separate defect
   needs to be postulated.
4. **Bonus adjudication**: AF's registered `rpg_free_doc`
   PhiStateConflict is **confirmed reproduced** (SA backend,
   above) — AH2 could not reach it because the SAB path never
   got there. It is a real, terminating, separately actionable
   item (product shape or PhiState family), NOT merged with this
   one.

## Recommended next steps for the fixing line

- Histogram the 88 MB SAB's function inventory (`sa sla sab
  disasm`) against the SA-text inventory: name the most
  duplicated emissions; the fix is dedup/sharing in sab_codegen
  emission (emit each reachable function/fragment once).
- Bisect the reachable set: probe variants calling only
  rpg_jb_assign / only rpg_jb_doc to find which subtree carries
  the multiplication factor.
- After dedup, re-run the interpreter on the shrunken module:
  if the spin persists on a small SAB, it becomes a pure
  interpreter bug with a small repro; if it vanishes, it was a
  downstream symptom.
- Related prior sighting: `sa sla build-exe` on the 54k-line
  li_probe module died RC=137 SIGKILL with no output (BG defect-2
  follow-up note) — same SAB-path blowup family, worth folding
  into the same fix's regression set.
