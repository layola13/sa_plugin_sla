#!/bin/sh
# Pre-publish guard: every staged binary must embed the same version as its
# package.json. `sla --version` is baked at compile time from -Dversion,
# so tag/build first — never publish a version bump with stale binaries.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

check() {
    # $1 = package suffix, $2 = binary name
    pkg="$ROOT/packages/sla-$1/package.json"
    bin="$ROOT/packages/sla-$1/bin/$2"
    want="$(grep -m1 '"version"' "$pkg" | sed 's/.*: *"//;s/".*//')"
    if [ ! -f "$bin" ]; then
        echo "[MISS] sla-$1: binary $2 not staged"; fail=1; return
    fi
    if strings "$bin" | grep -qx "$want"; then
        echo "[ok] sla-$1: binary embeds $want"
    else
        echo "[FAIL] sla-$1: package.json says $want but binary lacks that version string"; fail=1
    fi
}

check linux-x64   sla
check linux-arm64 sla
check darwin-arm64 sla
check darwin-x64  sla
check win32-x64   sla.exe
check freebsd-x64 sla

exit $fail
