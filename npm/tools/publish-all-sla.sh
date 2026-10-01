#!/bin/sh
# Publish all @slalang/sla packages in dependency order:
# the 6 platform packages first, the meta package last.
# Any extra args are forwarded to `npm publish` (e.g. --dry-run).

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for p in sla-linux-x64 sla-linux-arm64 sla-darwin-arm64 sla-darwin-x64 sla-win32-x64 sla-freebsd-x64; do
    echo "=== publishing @slalang/$p"
    (cd "$ROOT/packages/$p" && npm publish --access public "$@")
done

echo "=== publishing @slalang/sla"
(cd "$ROOT/packages/sla" && npm publish --access public "$@")
