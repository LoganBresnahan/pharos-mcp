#!/usr/bin/env node
// pharos-mcp's command, in the one case it is still JavaScript
// (ADR-035 §5).
//
// The postinstall replaces this file with a symlink to the platform
// package's native `pharos` (the ADR-034 shim), so an MCP client's
// `pharos` runs with no node in its process tree. This file stays, and
// runs, only when the postinstall didn't: an install with
// --ignore-scripts or a failed swap. Then it runs the native `pharos`
// as a child with this process's stdio, passes signals through, and
// exits with its status. That costs a node per session, but only in
// that case. On Windows it says to use WSL (ADR-035).

"use strict";

const { spawn } = require("node:child_process");
const { resolve } = require("../scripts/platform.js");

const found = resolve();
if (found.error) {
  console.error(found.error);
  process.exit(1);
}

const child = spawn(found.bin, process.argv.slice(2), { stdio: "inherit", shell: false });

for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(signal, () => {
    if (child.exitCode === null) child.kill(signal);
  });
}

child.on("exit", (code, signal) => {
  if (signal !== null) {
    process.removeAllListeners(signal);
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code ?? 0);
});

child.on("error", (err) => {
  console.error("pharos: failed to start " + found.bin + ": " + err.message);
  process.exit(1);
});
