#!/usr/bin/env node
// Node shim that exec's the platform-native pharos burrito binary.
//
// MCP hosts (Claude Code, Cursor, ChatGPT Desktop, Claude Desktop)
// configure pharos as `{ "command": "pharos" }` (after `npm install
// -g pharos-mcp`) or `{ "command": "npx", "args": ["-y",
// "pharos-mcp"] }`. Either way, npm puts this shim on PATH; the
// shim resolves the right platform sub-package via require.resolve
// and exec's its binary.
//
// The platform sub-packages (pharos-mcp-linux-x64, etc.) are
// declared as optionalDependencies in this package's package.json,
// with `os` and `cpu` fields on each sub-package. npm filters
// optional deps at install time, so exactly one platform package
// lands on disk per host. If none does (unsupported platform, OR
// `--no-optional` flag), we print a clear error.
//
// Stdio is "inherit" so the child sees the host's actual stdin pipe
// — pharos's stdio_worker opens a `{fd, 0, 0}` port over it for MCP
// NDJSON. shell=false ensures argv passes through without
// intermediate shell quoting.

"use strict";

const { spawn } = require("node:child_process");
const path = require("node:path");

const PLATFORM_MAP = {
  "linux-x64": { pkg: "pharos-mcp-linux-x64", bin: "pharos" },
  "linux-arm64": { pkg: "pharos-mcp-linux-arm64", bin: "pharos" },
  "darwin-x64": { pkg: "pharos-mcp-darwin-x64", bin: "pharos" },
  "darwin-arm64": { pkg: "pharos-mcp-darwin-arm64", bin: "pharos" },
  "win32-x64": { pkg: "pharos-mcp-win-x64", bin: "pharos.exe" },
};

function resolve_binary() {
  const key = process.platform + "-" + process.arch;
  const entry = PLATFORM_MAP[key];

  if (!entry) {
    console.error(
      "pharos: unsupported platform/arch combination: " +
        key +
        ". Supported: " +
        Object.keys(PLATFORM_MAP).join(", ") +
        ". " +
        "Open an issue at https://github.com/LoganBresnahan/pharos-mcp/issues " +
        "if you need a missing platform."
    );
    process.exit(1);
  }

  // require.resolve(<pkg>/package.json) succeeds iff the optional
  // dep was installed by npm — i.e., the host platform matched its
  // os/cpu filters. If it throws, the user is on a supported
  // platform but the optional dep was skipped (--no-optional, lock
  // file mismatch, registry mirror issue).
  let pkg_json_path;
  try {
    pkg_json_path = require.resolve(entry.pkg + "/package.json");
  } catch (_err) {
    console.error(
      "pharos: platform package '" +
        entry.pkg +
        "' was not installed. " +
        "This usually means npm install was run with --no-optional, or your registry " +
        "mirror blocked the optional dependency. Retry with: " +
        "npm install -g --include=optional pharos-mcp"
    );
    process.exit(1);
  }

  return path.join(path.dirname(pkg_json_path), "bin", entry.bin);
}

const child = spawn(resolve_binary(), process.argv.slice(2), {
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
