#!/usr/bin/env bash
# Judge negative diagnostic carriers in test form.
#
# Why this script exists: `sa sla test <file>` silently skips any file
# without an @test block, so negative carriers (tests/test_error_*.sla)
# pass vacuously under the test runner and their diagnostics are never
# judged by any suite path (the DIAG-LEAK family). Diagnostics are
# therefore judged here, each by the frontend that actually produces it:
#   - checker diagnostics        -> `sla check`
#   - SAB string-escape decoding -> `sla sab build`
#   - text lowering              -> `sla build`
#   - cooperative wasm lowering  -> `sla build-wasm`
#   - workspace resolution       -> `sla check` with cwd in the fixture
# A case passes only when the command exits non-zero AND its output
# contains the expected diagnostic text. A legal control file must be
# accepted (exit 0) by the check frontend.
#
# Usage (from anywhere; the script cd's to the repo root):
#   tools/run_diag_checks.sh
# Environment follows the suite conventions (SA_STD_DIR,
# SA_SLA_FIXTURE_DIR, SLA_NO_FRESHNESS_CACHE=1, cleared caches).
set -uo pipefail
cd "$(dirname "$0")/.."

SA="${SA:-sa}"
pass=0
fail=0

judge() { # name expected-substring command...
    local name="$1" expect="$2"
    shift 2
    local out rc
    out="$("$@" 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ] && [[ "$out" == *"$expect"* ]]; then
        echo "PASS $name"
        pass=$((pass + 1))
    else
        echo "FAIL $name (rc=$rc, expected substring: $expect)"
        echo "$out" | head -5
        fail=$((fail + 1))
    fi
}

judge_ws() { # name expected-substring fixture-dir command...
    local name="$1" expect="$2" dir="$3"
    shift 3
    local out rc
    out="$(cd "$dir" && "$@" 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ] && [[ "$out" == *"$expect"* ]]; then
        echo "PASS $name"
        pass=$((pass + 1))
    else
        echo "FAIL $name (rc=$rc, expected substring: $expect)"
        echo "$out" | head -5
        fail=$((fail + 1))
    fi
}

judge_ok() { # name command...  (positive control: must exit 0)
    local name="$1"
    shift
    local out rc
    out="$("$@" 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "PASS $name (control)"
        pass=$((pass + 1))
    else
        echo "FAIL $name (control, rc=$rc)"
        echo "$out" | head -5
        fail=$((fail + 1))
    fi
}

# DIAG-LEAK family: produced by `sla check`, previously judged by no
# suite path. (Also asserted in-process in src/plugin_tests.zig J-1.)
judge MacroParamUnused-unused-param "MacroParamUnused" \
    "$SA" sla check tests/test_error_check_hook_unused_param.sla
judge MacroParamUnused-shadowed-param "MacroParamUnused" \
    "$SA" sla check tests/test_error_check_hook_shadowed_param.sla
judge ShaderDimensionMismatch "ShaderDimensionMismatch" \
    "$SA" sla check tests/test_error_shader_dimension.sla
judge ShaderDuplicateName "ShaderDuplicateName" \
    "$SA" sla check tests/test_error_shader_duplicate.sla
judge ShaderStageViolation "ShaderStageViolation" \
    "$SA" sla check tests/test_error_shader_stage_violation.sla

# MonomorphizeError surfaces under its prose label "Monomorphization
# Error"; the concrete set member rides along in the same message.
judge MonomorphizeError "Monomorphization Error" \
    "$SA" sla check tests/test_error_overload_generic_mix.sla

# Codegen/lowering-stage diagnostics: `sla check` never reaches the
# stage that raises these, so each is judged by its producing frontend.
judge InvalidStringLiteral "InvalidStringLiteral" \
    "$SA" sla sab build tests/test_error_diag_invalid_string_literal.sla \
    --out /tmp/diag_invalid_string.sab
judge LoweringFailed "LoweringFailed" \
    "$SA" sla build tests/test_error_diag_lowering_failed.sla \
    --out /tmp/diag_lowering_failed.sa
judge CoopUnsupported "CoopUnsupported" \
    "$SA" sla build-wasm tests/test_error_diag_coop_unsupported.sla \
    --out /tmp/diag_coop.wasm

# Workspace-resolution diagnostics: judged by `sla check` run with cwd
# inside each fixture under tests/diag_workspace/.
judge_ws UnknownPackage "unknown workspace package" \
    tests/diag_workspace/unknown_package "$SA" sla check -p nosuch
judge_ws MissingDefaultMember "MissingDefaultMember" \
    tests/diag_workspace/missing_default_member "$SA" sla check
judge_ws InvalidFormat "InvalidFormat" \
    tests/diag_workspace/invalid_format "$SA" sla check
judge_ws DuplicateEntry "DuplicateEntry" \
    tests/diag_workspace/duplicate_entry "$SA" sla check
judge_ws InvalidPath "invalid path" \
    tests/diag_workspace/invalid_path "$SA" sla check

# Positive control: the judging frontends must accept a legal program.
judge_ok control-check "$SA" sla check tests/test_diag_control_ok.sla

echo "======================================================"
echo "diag checks: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
