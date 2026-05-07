#!/usr/bin/env node
// Node shim that exec's the platform-native pharos burrito binary.
//
// MCP hosts (Claude Desktop, Claude Code, Cursor, etc.) configure
// pharos as `{ "command": "npx", "args": ["-y", "pharos-mcp"] }`.
// npx resolves to this script; `binary_path()` picks the right
// burrito binary for the host platform/arch and execs it with the
// host's argv + stdio.
//
// Stdio is "inherit" so the child sees the host's actual stdin
// pipe — pharos's stdio_worker opens a `{fd, 0, 0}` port over it for
// MCP NDJSON. spawn() with shell=false ensures argv passes through
// without intermediate shell quoting.

"use strict";

const { spawn } = require("node:child_process");
const path = require("node:path");
const fs = require("node:fs");

function binary_path() {
  const platform = process.platform;
  const arch = process.arch;

  const target =
    platform === "linux" && arch === "x64"
      ? "linux_x64"
      : platform === "linux" && arch === "arm64"
      ? "linux_arm64"
      : platform === "darwin" && arch === "x64"
      ? "darwin_x64"
      : platform === "darwin" && arch === "arm64"
      ? "darwin_arm64"
      : platform === "win32" && arch === "x64"
      ? "win_x64"
      : null;

  if (target === null) {
    console.error(
      "pharos: unsupported platform/arch combination: " +
        platform +
        "/" +
        arch +
        ". Supported: linux x64/arm64, darwin x64/arm64, win32 x64."
    );
    process.exit(1);
  }

  const ext = platform === "win32" ? ".exe" : "";
  const filename = "pharos_" + target + ext;
  const candidate = path.join(__dirname, "..", "vendor", filename);

  if (!fs.existsSync(candidate)) {
    console.error(
      "pharos: bundled binary not found at " +
        candidate +
        ". The npm package may be incomplete; reinstall, or build from " +
        "source via the GitHub repo."
    );
    process.exit(1);
  }

  return candidate;
}

const child = spawn(binary_path(), process.argv.slice(2), {
  stdio: "inherit",
  shell: false,
});

child.on("exit", (code, signal) => {
  if (signal !== null) {
    // Re-raise the signal so callers see the real exit cause.
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code ?? 0);
});

child.on("error", (err) => {
  console.error("pharos: failed to spawn binary: " + err.message);
  process.exit(1);
});
