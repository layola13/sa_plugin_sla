#!/usr/bin/env bash
# D12 frontend miniature: (1) builds the SAX page (page.sax) into its
# web bundle (app.wasm + airlock.js + index.html) with the sax plugin;
# (2) builds the SLA token-stream backend and the stand-in client,
# runs one WS round and verifies the assembled token stream.
# Honest scope: the SAX airlock has no WebSocket bridge yet, so the
# page bundle is build-verified and the stream round runs through
# client.sla speaking the page's protocol (gap recorded in README).
set -u
cd "$(dirname "$0")"
export PATH=/content/sa_all/sci/zig-out/bin:/content/sa_all/sa_plugin_sla/zig-out/bin:/tools/node/bin:$PATH
export SA_PLUGIN_DEV=1
SAX=/content/sa_all/sa_plugin_sax

# The sax bundle build needs the plugin's LLVM-C backend
# (LLVMDIBuilderInsertDeclareRecordAtEnd -> LLVM >= 19; the box has
# llvm-20-dev from apt.llvm.org). A -Dllvm=false bootstrap plugin
# loads but cannot emit app.wasm.
if [ ! -f "$SAX/zig-out/lib/libsax.so" ]; then
  echo "building sax plugin (ReleaseFast, LLVM-C backend)..."
  (cd "$SAX" && timeout 1200 /opt/zig17/zig build -Doptimize=ReleaseFast) || { echo "D12 SAX BUILD FAILED"; exit 1; }
fi

rm -rf web server server.sa server.sa.bc client client.sa client.sa.bc
SA_PLUGINS_PATH=$SAX/zig-out/lib/libsax.so timeout 300 sa sax build page.sax --out-dir web || { echo "D12 SAX PAGE BUILD FAILED"; exit 1; }
for f in app.wasm airlock.js index.html; do
  [ -s "web/$f" ] || { echo "D12 BUNDLE MISSING $f"; exit 1; }
done
grep -q "TokenView" web/app.sa || { echo "D12 BUNDLE LACKS COMPONENT"; exit 1; }
echo "sax bundle ok (app.wasm $(stat -c%s web/app.wasm) bytes)"

timeout 300 sa build-exe server.sla || { echo "D12 SERVER BUILD FAILED"; exit 1; }
timeout 300 sa build-exe client.sla || { echo "D12 CLIENT BUILD FAILED"; exit 1; }
timeout 60 ./server > server.log 2>&1 &
SRV=$!
sleep 1
timeout 60 ./client
rc=$?
wait $SRV
src=$?
[ $rc -eq 0 ] || { echo "D12 CLIENT RC=$rc"; exit 1; }
[ $src -eq 0 ] || { echo "D12 SERVER RC=$src"; cat server.log; exit 1; }
grep -q "d12 server ok" server.log || { echo "D12 SERVER LOG MISSING OK"; cat server.log; exit 1; }
echo "d12 frontend mini demo ok"
