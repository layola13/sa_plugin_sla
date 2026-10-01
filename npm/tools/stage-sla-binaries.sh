#!/bin/sh
# Stage verified `sla` binaries into the @slalang/sla platform package dirs.
# Mirrors tools/stage-binaries.sh (which handles @salang/sa).
#
# Usage: sh tools/stage-sla-binaries.sh [--dist DIR]
# Default DIR is /tmp/sla-dist with per-target subdirs, each with bin/sla
# (or bin/sla.exe on Windows), as produced by the verified cross builds.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="${1:---dist}"
if [ "$DIST" = "--dist" ]; then DIST="${2:-/tmp/sla-dist}"; else DIST="$DIST"; fi

stage() {
    # $1 = dist subdir, $2 = package suffix, $3 = binary name
    src="$DIST/$1/bin/$3"
    dst="$ROOT/packages/sla-$2/bin/$3"
    if [ ! -f "$src" ]; then
        echo "[skip] missing $src (build that target first)"
        return 0
    fi
    cp "$src" "$dst"
    chmod +x "$dst"
    echo "[ok] sla-$2 <= $src ($(du -h "$dst" | cut -f1))"
}

stage linux-x86_64   linux-x64   sla
stage arm-aarch64    linux-arm64 sla
stage mac-aarch64    darwin-arm64 sla
stage mac-x86_64     darwin-x64  sla
stage windows-x86_64 win32-x64   sla.exe
stage freebsd-x86_64 freebsd-x64 sla

# Stage the SLA source stdlib (platform-independent) into the @slalang/sla
# meta package. Sources, not binaries: copy straight from this checkout
# (same tag as the release being published).
rm -rf "$ROOT/packages/sla/sla_std"
cp -r "$ROOT/../sla_std" "$ROOT/packages/sla/sla_std"
echo "[ok] sla stdlib <= $ROOT/../sla_std"
