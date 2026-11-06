# DEF-SAB-AUDIT — dual-backend registration audit (form A′/C′)

## Why

The SLA checker accepts calls through hand-written cascades, and the
two codegen backends (SA text / SAB) dispatch through their own
cascades and macro bridges. There is no enumerable registration
table anywhere (mapping report, section 1), so a call could pass
checking and fail only inside SAB codegen — first-failure-only, one
program at a time (UnknownRegister / Undefined call / ...).

This directory implements the adapted form ruled for DEF-SAB-AUDIT:
the C′ probe matrix *generates* the registration registry by
compiling probes, and the A′ audit module (src/sab_audit.zig)
*consumes* it at check time.

## Pieces

- `symbols.tsv` — the symbol spec: live-example families (iterator
  adapters, std macro bridges, `using` extensions) plus core-surface
  controls. Each row names the audit symbol key, a template, and the
  probe body. Multi-symbol probes (using_ext) share one probe file.
- `templates/*.sla.tpl` — probe program shapes (ordinary @test
  programs; `{{BODY}}` is substituted per row).
- `gen_probes.py` — instantiates `probes/*.sla` + `manifest.tsv`,
  and extracts the enumerable std declaration plane from
  `$SA_STD_DIR/*.sla` into `decl_rows.tsv` (declared-plane symbols
  are lowered generically on both backends; the registry records
  them as `decl` instead of probing them).
- `run_matrix.sh` — runs every probe through BOTH backends
  (`sa sla test --test-backend sa|sab`) in fresh directories and
  classifies each cell with four-link reading (rc=0 AND the
  `test result` line AND `0 failed` AND no error signature) into
  `results.tsv` with a phase (check|codegen|run) and a signature.
- `build_registry.py` — joins results + manifest + decl rows into
  `registry.tsv`, the checked-in registry. Status per backend:
  `ok` / `fail` (signature kept) / `checkfail` (the shared checker
  rejected the probe shape) / `decl`.
- `emit_registry_zig.py` — renders `registry.tsv` as
  `src/sab_audit_registry.zig`, the table the audit module imports.
- `regen.sh [--check]` — full regeneration; `--check` fails when
  the checked-in registry or generated table differ from a fresh
  regeneration for the same (plugin tree, sa_std tree) pair.
- `samples/` + `self_proof.sh` — independent-driver self-proof:
  src/sab_audit_driver.zig exercises the audit module on checked
  sample programs (no pipeline wiring) and asserts the live-example
  findings appear in ONE pass.
- `wiring.patch` — the minimal main-flow wiring (one audit call
  inside runSlaFrontend + the module import). NOT applied by this
  line: both candidate hook points sit in file domains owned by
  other in-flight lines; the main session lands it in integration
  order.

## Staleness rules (防陈腐)

- The registry is stamped with the (plugin head, sa_std head) pair
  it was measured against — see the header of `registry.tsv`. It
  carries NO wall-clock stamp, so regeneration for the same pair is
  byte-identical and the `--check` diff is meaningful.
- Any change to checker/codegen cascades or to the sa_std surface
  invalidates the registry for the new head pair: re-run
  `regen.sh`, and the diff (symbols entering/leaving the registry,
  verdict flips) is the review surface.
- Right after the audit itself lands as a commit, the plugin-head
  stamp refreshes once (the audit files do not change compiler
  behavior); that one-line stamp diff is expected, not staleness.
- A hardcoded-class symbol with no registry entry is reported by
  the audit as `unprobed` (listed in full, non-blocking). Grow the
  registry by adding a row to `symbols.tsv` and regenerating —
  never by editing `registry.tsv` or `sab_audit_registry.zig`.

## Evidence validity: SAB columns and sa_std changes

Operational fact (measured by the card-1 fix line, 2026-11-04,
recorded here at the main session's direction): **SAB fragment
routing prefers the plugin-baked `sa_std_source_dir` and does not
honor `SA_STD_DIR`.** After sa_std is modified, a SAB measurement
taken with only `SA_STD_DIR` set silently runs against the OLD
baked std — a green obtained that way is void.

Rule for this registry: any probe row or registry entry whose
claim involves **SAB behavior after an sa_std change** counts as
evidence only when obtained by the swap-in method — the changed
std is copied into the plugin's baked `sa_std_source_dir` under a
three-step sha verification (source std hash == baked copy hash
before measuring; re-verified after measuring; original swapped
back afterwards and its hash confirmed restored). A row obtained
any other way is invalid and must be re-measured before use.

Applicability to the current registry: this line never modified
sa_std. The registry was measured against the box's stock
installed std (`SA_STD_DIR=/content/sa_all/sci/sa_std` @
73a7e888, the same tree the installed plugin was built from), so
no current row depends on the swap-in method. The rule binds any
future regeneration performed on top of a modified std.

## Doctrine anchors

- SAB is the production path; SA text is the teaching /
  decompile-debug mirror (user ruling 2026-11-03 23:41). The audit
  defaults to the production target set {SAB}: SAB gaps are hard
  findings, text-only gaps are listed as mirror-distortion
  findings. The test target set is {SAB, text} (both hard).
- No fallback: a missing registration is a loud finding, never a
  reroute through the other backend (user ruling 2026-11-03 23:40).
