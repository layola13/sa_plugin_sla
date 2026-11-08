# SAB audit measurement std tree (narrowed sa_std)

This directory documents the narrowed sa_std tree a SAB-audit
registry regeneration measures against. The tree itself is NOT
checked in — `tools/sab_audit/make_meas.sh` constructs it in a
scratch directory on every regeneration setup, from the sci tree
under test, so the measurement can never silently run against a
stale or foreign std.

## Shape

```
<stdroot>/sa_std/            <- SA_STD_DIR for the measurement runs
    <the sci sa_std sources, copied verbatim>
    libsa_std.a              <- built by the SAME sci tree
                                (`zig build sa-std-static`)
```

`regen.sh` exports this directory as `SAB_AUDIT_MEAS_STD` /
`SA_STD_DIR`, and the measurement plugin is *built* with
`SA_STD_DIR` pointing here, so the plugin's baked
`sa_std_source_dir` — the root SAB fragment routing actually reads,
which does NOT honor `SA_STD_DIR` at run time — is this tree. That
is the sha three-step discipline of the parent README (source std
hash == baked copy hash before measuring; re-verified after
measuring; the original sci tree is never written to, so there is
nothing to swap back) applied to a scratch copy instead of the
shipped tree.

## Why narrowed

The audit probes import `sa_std/*.sa` / `sa_std/*.sai` units and the
audit's declaration plane is extracted from `sa_std/*.sla`. The
narrowed tree carries exactly those sources plus the one archive
the linker needs (`libsa_std.a`). It deliberately excludes the
sci build's `zig-out`, caches, tests and docs, so a measurement
assembly is small, disposable, and — most importantly — derived
from the exact (plugin tree, sa_std tree) pair the regenerated
registry is stamped with.
