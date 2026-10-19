// Shared by bin/pharos.js and scripts/postinstall.js (ADR-035 §5):
// find this host's platform package and the native `pharos` it ships,
// and say plainly when there is none.
//
// The platform packages (@pharos-mcp/linux-x64, …) are
// optionalDependencies with `os`, `cpu` (and on Linux `libc`) fields,
// so npm installs exactly the one that fits this host, or none.

"use strict";

const path = require("node:path");
const fs = require("node:fs");

const PLATFORMS = {
  "linux-x64": "@pharos-mcp/linux-x64",
  "linux-arm64": "@pharos-mcp/linux-arm64",
  "darwin-x64": "@pharos-mcp/darwin-x64",
  "darwin-arm64": "@pharos-mcp/darwin-arm64",
};

const UNSUPPORTED_WINDOWS =
  "pharos 0.2 runs on Linux and macOS; on Windows, install it inside WSL " +
  "(pharos-mcp@0.1.4 was the last native Windows build)";

const UNSUPPORTED_LINUX =
  "pharos 0.2 needs glibc 2.35+ (Alpine/musl and older distros aren't " +
  "supported yet); pharos-mcp@0.1.4 still runs there";

// glibc's version as [major, minor], or null on musl (or anything that
// isn't glibc). Node reports it in its diagnostic report header.
function glibc_version() {
  try {
    const header = process.report.getReport().header;
    const v = header.glibcVersionRuntime;
    if (!v) return null;
    const [major, minor] = v.split(".").map(Number);
    return [major, minor];
  } catch (_) {
    return null;
  }
}

// Why this host can't run pharos 0.2, or null when it can.
function unsupported_reason() {
  if (process.platform === "win32") return UNSUPPORTED_WINDOWS;
  const key = process.platform + "-" + process.arch;
  if (!PLATFORMS[key]) {
    return (
      "pharos has no build for " +
      key +
      " (supported: " +
      Object.keys(PLATFORMS).join(", ") +
      "); open an issue at https://github.com/LoganBresnahan/pharos-mcp/issues"
    );
  }
  if (process.platform === "linux") {
    const v = glibc_version();
    if (v === null || v[0] < 2 || (v[0] === 2 && v[1] < 35)) return UNSUPPORTED_LINUX;
  }
  return null;
}

// The installed native `pharos` (release/bin/pharos) and its
// release root, or an error message.
function resolve() {
  const reason = unsupported_reason();
  if (reason) return { error: reason };
  const pkg = PLATFORMS[process.platform + "-" + process.arch];
  let pkg_json;
  try {
    pkg_json = require.resolve(pkg + "/package.json");
  } catch (_) {
    return {
      error:
        "pharos: the platform package " +
        pkg +
        " is not installed. npm skips optional dependencies with " +
        "--no-optional / --omit=optional, and some registry mirrors drop them; " +
        "retry with: npm install -g --include=optional pharos-mcp",
    };
  }
  const root = path.join(path.dirname(pkg_json), "release");
  const bin = path.join(root, "bin", "pharos");
  if (!fs.existsSync(bin)) {
    return { error: "pharos: " + pkg + " has no release/bin (a broken install; reinstall pharos-mcp)" };
  }
  return { bin: bin, root: root };
}

module.exports = { resolve, unsupported_reason, UNSUPPORTED_LINUX, UNSUPPORTED_WINDOWS };
