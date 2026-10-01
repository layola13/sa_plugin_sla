#!/bin/sh
# Fetch prebuilt `sla` binaries from a sa_plugin_sla GitHub Release into the
# platform package dirs. Used on publisher machines that don't rebuild every
# target (e.g. Windows laptop publishing @slalang/sla).
#
# Binaries are intentionally NOT committed to git; the GitHub Release is the
# binary store. Rebuilding instead? See stage-sla-binaries.sh.
#
# Usage: sh tools/fetch-sla-binaries.sh [--version VER]   (default: 0.1.3)

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VER="0.1.3"
if [ "${1:-}" = "--version" ]; then VER="$2"; fi
BASE="https://github.com/layola13/sa_plugin_sla/releases/download/$VER"

fetch() {
    # $1 = release asset suffix (e.g. linux-x86_64), $2 = package suffix,
    # $3 = binary name in package
    url="$BASE/sla-$VER-$1.zip"
    dst="$ROOT/packages/sla-$2/bin/$3"
    tmp="$(mktemp /tmp/sla-fetch-XXXXXX.zip)"
    trap 'rm -f "$tmp"' EXIT INT TERM
    echo "[i] $url"
    curl -sSL -o "$tmp" "$url"
    unzip -q -o -j "$tmp" "$3" -d "$ROOT/packages/sla-$2/bin"
    rm -f "$tmp"
    trap - EXIT INT TERM
    chmod +x "$dst"
    echo "[ok] sla-$2 <= sla-$VER-$1.zip ($(du -h "$dst" | cut -f1))"
}

fetch linux-x86_64   linux-x64   sla
fetch arm-aarch64    linux-arm64 sla
fetch mac-aarch64    darwin-arm64 sla
fetch mac-x86_64     darwin-x64  sla
fetch windows-x86_64 win32-x64   sla.exe
fetch freebsd-x86_64 freebsd-x64 sla
