#!/usr/bin/env node
'use strict';
// @slalang/sla launcher: standalone `sla` binary, no SA_PLUGIN_DEV needed.
// The sla compiler shells out to the `sa` host (build-exe/build-wasm/test),
// so this launcher puts a directory containing a directly-executable `sa`
// on PATH before exec: prefer the real binary inside @salang/sa's platform
// package, fall back to the @salang/sa node wrapper.
// No runtime dependencies; works on Node >= 16.
const path = require('path');
const fs = require('fs');
const { spawnSync } = require('child_process');

const SLA_PLATFORMS = {
  'linux-x64': { pkg: '@slalang/sla-linux-x64', bin: 'sla' },
  'linux-arm64': { pkg: '@slalang/sla-linux-arm64', bin: 'sla' },
  'darwin-arm64': { pkg: '@slalang/sla-darwin-arm64', bin: 'sla' },
  'darwin-x64': { pkg: '@slalang/sla-darwin-x64', bin: 'sla' },
  'win32-x64': { pkg: '@slalang/sla-win32-x64', bin: 'sla.exe' },
  'freebsd-x64': { pkg: '@slalang/sla-freebsd-x64', bin: 'sla' },
};

// Mirrors @salang/sa's platform table: the `sa` host binary lives in the
// matching @salang/sa-<platform> package (a transitive dependency via
// @salang/sa, resolvable hoisted or nested).
const SA_PLATFORMS = {
  'linux-x64': { pkg: '@salang/sa-linux-x64', bin: 'sa' },
  'linux-arm64': { pkg: '@salang/sa-linux-arm64', bin: 'sa' },
  'darwin-arm64': { pkg: '@salang/sa-darwin-arm64', bin: 'sa' },
  'darwin-x64': { pkg: '@salang/sa-darwin-x64', bin: 'sa' },
  'win32-x64': { pkg: '@salang/sa-win32-x64', bin: 'sa.exe' },
  'freebsd-x64': { pkg: '@salang/sa-freebsd-x64', bin: 'sa' },
};

function pkgDir(name) {
  try {
    return path.dirname(require.resolve(`${name}/package.json`));
  } catch (e) {
    return null;
  }
}

function main() {
  const key = `${process.platform}-${process.arch}`;
  const entry = SLA_PLATFORMS[key];
  if (!entry) {
    console.error(
      `@slalang/sla: unsupported platform "${key}". ` +
        `Supported: ${Object.keys(SLA_PLATFORMS).join(', ')}.`
    );
    process.exit(1);
  }
  const slaDir = pkgDir(entry.pkg);
  if (!slaDir) {
    console.error(
      `@slalang/sla: platform package "${entry.pkg}" is not installed. ` +
        `Reinstall with: npm install -f @slalang/sla`
    );
    process.exit(1);
  }

  const env = { ...process.env };
  const sep = process.platform === 'win32' ? ';' : ':';
  const prependPath = (dir) => {
    env.PATH = `${dir}${sep}${env.PATH || ''}`;
  };
  // Real `sa` binary first (directly executable, no node involved).
  const saEntry = SA_PLATFORMS[key];
  if (saEntry) {
    const saPlatDir = pkgDir(saEntry.pkg);
    if (saPlatDir) prependPath(path.join(saPlatDir, 'bin'));
  }
  // Then the @salang/sa node wrapper as fallback.
  const saDir = pkgDir('@salang/sa');
  if (saDir) prependPath(path.join(saDir, 'bin'));

  const binPath = path.join(slaDir, 'bin', entry.bin);
  // Tarballs packed on Windows lose the Unix exec bit; restore it.
  try {
    fs.chmodSync(binPath, 0o755);
  } catch {}
  const r = spawnSync(binPath, process.argv.slice(2), {
    stdio: 'inherit',
    env,
  });
  if (r.error) {
    console.error(`@slalang/sla: failed to run ${binPath}: ${r.error.message}`);
    process.exit(1);
  }
  process.exit(r.status === null ? 1 : r.status);
}

main();
