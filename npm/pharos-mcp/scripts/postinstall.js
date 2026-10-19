#!/usr/bin/env node
// pharos-mcp postinstall (ADR-035 §5): make `pharos` the native shim.
//
// npm links the `pharos` command to bin/pharos.js. On Linux and macOS
// this replaces that file with a symlink to the installed platform
// package's release/bin/pharos (esbuild's pattern), so every MCP
// session runs the native shim directly and no node stays resident.
// The shim follows its own symlinks to find the release beside it.
//
// - Unsupported host (no build, musl, glibc < 2.35): say so and exit
//   non-zero, so the install fails loudly instead of at first use.
// - Windows: nothing to swap; bin/pharos.js runs the native pharos.
// - PHAROS_SKIP_POSTINSTALL=1, or any failure to swap: bin/pharos.js
//   stays and works as a fallback.

"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { resolve } = require("./platform.js");

function main() {
  if (process.env.PHAROS_SKIP_POSTINSTALL === "1") {
    console.error("pharos: postinstall skipped (PHAROS_SKIP_POSTINSTALL=1); bin/pharos.js runs pharos");
    return 0;
  }
  const found = resolve();
  if (found.error) {
    console.error(found.error);
    return 1;
  }
  if (process.platform === "win32") return 0;

  // Belt and braces: npm keeps executable bits on publish, but a
  // tarball repacked elsewhere may not.
  for (const dir of [path.join(found.root, "bin"), ...erts_bins(found.root)]) {
    for (const name of safe_readdir(dir)) {
      const file = path.join(dir, name);
      try {
        const st = fs.statSync(file);
        if (st.isFile() && !(st.mode & 0o111)) fs.chmodSync(file, st.mode | 0o755);
      } catch (_) {}
    }
  }

  const wrapper = path.join(__dirname, "..", "bin", "pharos.js");
  const target = path.relative(path.dirname(wrapper), found.bin);
  const tmp = wrapper + ".swap-" + process.pid;
  try {
    fs.symlinkSync(target, tmp);
    fs.renameSync(tmp, wrapper);
  } catch (err) {
    try {
      fs.unlinkSync(tmp);
    } catch (_) {}
    console.error("pharos: kept the JS launcher (" + err.message + "); pharos still works, through node");
  }
  return 0;
}

function erts_bins(root) {
  return safe_readdir(root)
    .filter((name) => name.startsWith("erts-"))
    .map((name) => path.join(root, name, "bin"));
}

function safe_readdir(dir) {
  try {
    return fs.readdirSync(dir);
  } catch (_) {
    return [];
  }
}

process.exitCode = main();
