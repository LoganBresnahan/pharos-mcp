#!/usr/bin/env node
// Postinstall warmup: trigger Burrito's first-run cache extract so
// the user's first MCP connection is fast.
//
// Without this script, the very first time an MCP host launches
// pharos, Burrito's Zig wrapper xz-decompresses the embedded ERTS +
// BEAM payload (~50 seconds on typical SSDs). MCP hosts have a 30s
// connect timeout — every fresh install fails on the first try and
// only works after a manual retry once the cache is populated.
// Running the wrapper once during `npm install` moves that 50s wait
// to install time, where it is expected.
//
// Behavior:
//   1. Resolve the platform binary (same logic as bin/pharos.js).
//   2. Spawn it with stdin closed and stdout/stderr to /dev/null.
//   3. Poll for the burrito cache directory until it exists OR a
//      generous deadline expires.
//   4. SIGKILL the wrapper. The cache survives the kill.
//   5. Exit 0 always — install must not fail because of warmup.
//
// Skip conditions (exit 0 cleanly):
//   - Bundled binary missing for this platform.
//   - Cache directory already exists (warmed by a prior install).
//   - PHAROS_SKIP_POSTINSTALL=1 set in env.

"use strict";

const { spawn } = require("node:child_process");
const path = require("node:path");
const fs = require("node:fs");
const os = require("node:os");

const SKIP_VAR = "PHAROS_SKIP_POSTINSTALL";
const DEADLINE_MS = 120_000; // 2 minutes — generous for slow disks
const POLL_INTERVAL_MS = 500;

function main() {
  if (process.env[SKIP_VAR] === "1") {
    console.error("pharos: postinstall skipped (" + SKIP_VAR + "=1)");
    return;
  }

  const bin = resolve_binary();
  if (bin === null) {
    // No matching binary; bin/pharos.js will print an error at first
    // run. Postinstall stays silent — installs of supplementary tools
    // on unsupported platforms shouldn't error out.
    return;
  }

  if (cache_exists()) {
    console.error("pharos: cache already populated; skipping warmup");
    return;
  }

  console.error("pharos: warming Burrito cache (one-time, ~30-60s)...");
  warmup(bin)
    .then(() => {
      console.error("pharos: cache populated; first launch will be fast");
    })
    .catch((err) => {
      // Soft-fail: print a warning, exit 0. The user can still use
      // pharos; they'll just hit the 50s wait on their first MCP
      // connection.
      console.error(
        "pharos: warmup failed (" +
          err.message +
          "); first launch will be slow"
      );
    });
}

function resolve_binary() {
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

  if (target === null) return null;

  const ext = platform === "win32" ? ".exe" : "";
  const filename = "pharos_" + target + ext;
  const candidate = path.join(__dirname, "..", "vendor", filename);

  return fs.existsSync(candidate) ? candidate : null;
}

function cache_root() {
  // Mirrors Burrito's default `<user_cache>/.burrito` location.
  // Linux/macOS: $XDG_DATA_HOME or ~/.local/share. Windows: %APPDATA%.
  if (process.platform === "win32") {
    const appdata = process.env.APPDATA;
    if (!appdata) return null;
    return path.join(appdata, ".burrito");
  }

  const xdg = process.env.XDG_DATA_HOME;
  if (xdg) return path.join(xdg, ".burrito");
  return path.join(os.homedir(), ".local", "share", ".burrito");
}

function cache_exists() {
  const root = cache_root();
  if (root === null) return false;
  if (!fs.existsSync(root)) return false;

  // Burrito creates a versioned directory like
  // `pharos_erts-16.1_0.0.1`. Any pharos_* entry counts as warm.
  try {
    return fs
      .readdirSync(root)
      .some((entry) => entry.startsWith("pharos_"));
  } catch (_) {
    return false;
  }
}

function warmup(bin) {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, [], {
      stdio: ["ignore", "ignore", "ignore"],
      detached: false,
    });

    let settled = false;
    const settle = (fn) => {
      if (settled) return;
      settled = true;
      fn();
    };

    const start = Date.now();
    const poll = setInterval(() => {
      if (cache_exists()) {
        clearInterval(poll);
        // Cache directory exists. Burrito creates it early in extract
        // and finishes shortly after. Give it a small grace window so
        // the *.beam files inside are flushed, then kill.
        setTimeout(() => {
          try {
            child.kill("SIGKILL");
          } catch (_) {}
          settle(resolve);
        }, 2_000);
        return;
      }

      if (Date.now() - start > DEADLINE_MS) {
        clearInterval(poll);
        try {
          child.kill("SIGKILL");
        } catch (_) {}
        settle(() => reject(new Error("cache populate timed out")));
      }
    }, POLL_INTERVAL_MS);

    child.on("error", (err) => {
      clearInterval(poll);
      settle(() => reject(err));
    });

    child.on("exit", (code, signal) => {
      // Burrito wrapper may exit on its own once extract is complete
      // (depending on platform). Treat that as success.
      clearInterval(poll);
      if (signal === "SIGKILL") {
        // We killed it after seeing the cache dir; settle is already
        // pending via the poll interval's timeout.
        return;
      }
      settle(resolve);
    });
  });
}

main();
