# Defect 3 — SAB referee false verdicts on multi-String structs (AW residual 13)

BG compiler line, 2026-10-28. Status: **root cause characterized, NOT
fixed in this line** (no fake fix). Two distinct defects were conflated
in the AW evidence; they are separated below. α blocks the SAB test
path for any test that calls `str_eq` on a locally-owned String; β is
a separate, older registered family and ALSO blocks url.sla.

## α — referee false BorrowConflict on `str_eq(&local, ...)` (this item)

### Minimal repro
`repro_alpha_streq_local_string.sla` in this directory (10 lines of
body). Equally minimal with `format("hello")` inline in the @test.

### Established facts (all measured 2026-10-28, plugin 59cbcfa8 +
BG fixes 87976d3d/abab292a, sci 138654f6, overlay SA_STD_DIR with
AW's held url.sla where the url corpus was involved)

- Host `sa test` and `sa sla test --test-backend sab` trap
  deterministically: `BorrowConflict` 1008, `expected_mask 1`
  (Active), `actual_mask 2` (Locked_Read), register = the String's
  own register (`tmp_0` for an inline format() local, `tmp_4` for a
  fn-returned local). `sa sla test --test-backend sa` passes; the
  same body as `fn main` assembles and runs (rc 0) on the native
  path. So the verdict is a SAB-path referee false positive, not a
  program error and not an SA-backend issue.
- The url corpus reproduces at scale, byte-identical to AW's
  evidence: dbg35 (4 tests) traps BorrowConflict tmp_1394
  (Active/Locked_Read); each of its 4 tests traps alone (tmp_512 /
  tmp_740 / tmp_1381 / tmp_1387); AW's test_url traps UseAfterMove
  1009 with expected_mask == actual_mask == 8 (Consumed) — the
  sibling signature (see "sibling" below).
- Trigger conditions, by controlled probes (each a full compile+run):
  - TRAPS: `str_eq(&m, "lit")`, `str_eq(&m, other_string)`,
    str_eq bound to a `let` first, str_eq twice — whenever `m` is a
    locally-owned String (format()-built or fn-returned) in the
    SAME function that calls str_eq.
  - PASSES: `len(m)` in place of str_eq; `format()` local never
    str_eq'd; `str_eq(&u.field, ...)` on a struct field projection;
    `str_eq(&m, ...)` inside a fn that received `m` BY VALUE as a
    parameter (check2 shape); must_url/url_parse/url_empty/url_clone/
    url_merge_paths/url_to_string called with the results only
    len-checked or unused.
- SAB disassembly of the minimal repro (`sa sla sab disasm`):
  the String register is borrowed by the STRING_BUF_AS_STR fragment
  chain (`borrow r397,r2,"read",cap:borrow`; `borrow r451,r397,...`),
  the view is materialized as a fresh 16-byte slice struct (r398),
  and `release r397` is emitted once at the STR_EQ fragment end.
  The referee nevertheless holds the String register Locked_Read at
  a later verification point (fn-exit release/merge), i.e. the
  borrow accounting across the fragment boundary does not balance
  for locally-owned String registers, while parameter registers and
  field projections are accounted correctly.
  - Side anomaly in the same disassembly: the FORMAT_PUSH fragment
    borrows `r377`, a register that is never assigned anywhere in
    the module (`borrow r378,r377,"read",cap:borrow`), and a call
    carries SA-source arg names (`call r2,"@sa_vec_reserve",
    "^tmp_0, tmp_2, 1"`) — SAB-direct fragment register binding is
    loose in the same area (family of residual 11 and BM D1:
    SAB-direct fragment/register bookkeeping, UnknownRegister 1007
    being the loud variant, this BorrowConflict the quiet one).
- Candidate loci (evidence does not yet separate them; a fix attempt
  must discriminate first):
  1. Plugin `sab_codegen.zig`: the STRING_BUF_AS_STR / STR_EQ
     fragment emission (emitStdMacroFragment sites ~11317/11560/
     15425) releases the view register but the unborrow of the
     OWNER register is not emitted (or is emitted against a
     fragment-local alias the referee does not equate with the
     local's register) when the owner is a locally-owned String;
     for parameters the owner temp is a `ptr_add` projection whose
     release is tolerated.
  2. sci `src/referee/` (verifier.zig/table.zig): borrow-of-borrow
     chains are counted per register and the release at the
     fragment end decrements the wrong link, leaving the base
     register Locked_Read; the self-contradictory UseAfterMove
     report (expected Consumed == actual Consumed, AW test_url +
     BA2 loopback suite) suggests the referee's expected/actual
     bookkeeping has a second, related accounting slip — in the
     UseAfterMove case a register the program consumed exactly
     once is reported consumed when the check expected it alive,
     and the report prints the post-state as "expected".
- Why not fixed here: either locus is shared by every std macro
  fragment / every SAB program; landing a change without the
  discrimination experiment (a referee trace on the minimal repro)
  risks corpus-wide regressions. The discrimination experiment is
  specified: instrument or hand-trace the referee state of the
  String register across the minimal repro's blocks (entry →
  AS_STR borrow → STR_EQ end release → merge → fn exit) and compare
  against the check2 (passing) trace.

### Sibling signature (UseAfterMove, Consumed == Consumed)
Seen in AW's test_url (tmp_4428) and BA2's proxy loopback suite.
Not isolated to a minimal repro in this line: BM's D4 sample
(`cand_len = cand_len;` inside ip.sla) did NOT reproduce as a bare
@test (u64 self-assignment passes), so that shape needs its
surrounding fn context. Recorded as the same suspected accounting
family, unproven.

## β — producer-side String corruption in the url corpus (NOT this item)

While bisecting α, the url value failures were shown to be partly
REAL misreads, present on BOTH backends (so not referee noise):

- `url_merge_paths(&base, format("g"))` for base
  `http://a/b/c/d;p?q` returns a String whose `len` is not 6
  (panic-ladder h1, both backends). Via the `expect_str` helper the
  same comparison fails with str_eq returning false on both
  backends (c10) — the producer, not str_eq, is at fault there.
- Narrower (b7): for a freshly parsed Url, `len(scheme)==4`,
  `len(host)==1`, `len(path)==8` all read correctly, but
  `PTR_BYTE_AT(STR_PTR(base.path), 0)` is not 47 ('/') on either
  backend — the parse-produced `path` String has the right length
  and wrong bytes. This points at the url_dup_range-produced
  (raw-slice) String representation vs the format()-produced one
  (the registered String-representation split, residual 11/BB3) or
  at a range error in url_parse itself; NOT isolated further here.
- Eliminated as β triggers (all pass in isolation, both backends):
  sequential `out = format("{}{}", out, format(..))` reassignment,
  the same in a while loop, conditional (if/else) first
  reassignment, pieces built by `[u8; 1].iter().collect<String>()`,
  and a url-free miniature of merge_paths appending raw
  PTR_BYTE_AT bytes through a &struct field in loops (beta6).
- Consequence for the main session: fixing α alone does NOT
  unblock url.sla integration (sci 71ac392b); β (residual 12③ /
  representation split) blocks it independently.

## What a fix must preserve (acceptance shape)
- The minimal repro + dbg35 (4/4) + AW test_url pass on host
  `sa test` and `--test-backend sab`, SA backend unchanged.
- Corpus name-set parity on the string/str_eq-heavy test files
  (baseline vs fixed), per the house rule.
- No new SAB-direct regressions in the FORMAT/AS_STR fragment
  family (D1's mime probe is the canary).
