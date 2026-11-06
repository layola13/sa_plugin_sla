#!/bin/bash
# Build (once per invocation; zig caches) and run the independent
# audit driver. Usage: run_driver.sh <file.sla> [production|both|mirror] [--lenient]
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
export SCI_ROOT="${SCI_ROOT:-/content/sa_all/sci}"
zig build --build-file "$HERE/driver_build/build.zig" -Dsci-root="$SCI_ROOT" -p "$HERE/.driver_out" --cache-dir "$HERE/.driver_cache" > /dev/null
exec "$HERE/.driver_out/bin/sab_audit_driver" "$@"
