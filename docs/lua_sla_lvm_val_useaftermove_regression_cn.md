# lua_sla lvm.sla val UseAfterMove (cache-stale false alarm; resolved by .sla-cache clean)

日期：2026-07-13

状态：resolved (false alarm). Initial report assumed a SLA-compiler regression; subsequent investigation showed the failure was due to a stale `.sla-cache` rather than a deterministic UseAfterMove. Cleaned with `rm -rf .sla-cache` and re-run; both back-to-back cached-clean attempts `sa sla check src_lua/lvm.sla` then returned EXIT=0. Leaving this note as a recovery trail for `lua_sla` slice authors in case they hit the same.

## Initial snapshot (false alarm symptom)

In `/home/vscode/projects/lua_sla` the following ran and reported a source-position-less `UseAfterMove`:

```bash
cd /home/vscode/projects/lua_sla
SA_PLUGIN_DEV=1 sa sla check src_lua/lvm.sla   # EXIT=1
```

Output:

```text
Type Check Error: failed to verify types: UseAfterMove: identifier `val` was already consumed (error.UseAfterMove)
```

The same EXIT=1 was reproduced on a `git stash`-backed prior HEAD `99cbae8` and on a couple of cache-bearing re-runs, which is what made it look like a deterministic regression rather than a cache-stale artifact.

## Resolution sequence

```bash
cd /home/vscode/projects/lua_sla
rm -rf .sla-cache
SA_PLUGIN_DEV=1 sa sla check src_lua/lvm.sla   # EXIT=0
rm -rf .sla-cache
SA_PLUGIN_DEV=1 sa sla check src_lua/lvm.sla   # EXIT=0 (stable across two more back-to-back runs)
```

All four other gate files also pass after the same cache clean:

- `sa sla check src_lua/lua.sla` -> EXIT=0
- `sa sla check src_lua/tests/test_generic_for_compile_only.sla` -> EXIT=0
- `sa sla check src_lua/tests/test_function_closure_compile_only.sla` -> EXIT=0
- `sa sla check src_lua/tests/test_numeric_for_compile_only.sla` -> EXIT=0

## Takeaway

Before filing a SLA-compiler regression for an identifier-less, line-less `UseAfterMove`, run `rm -rf .sla-cache` first and recheck. The `sla_tsgo` `host`-form sibling report (`sla_tsgo_modulespecifier_host_value_useaftermove_issue_cn.md`) should be re-examined with the same cache-clean first, since that one has not yet been invalidated by a clean recheck.
