//// Single source of truth for pharos's own version string.
////
//// Reads the OTP application `vsn`, which mix/gleam derive from
//// `mix.exs` (`@version_base`, cleaned to a bare semver when
//// `PHAROS_RELEASE=1`) and `gleam.toml`. Sourcing it at runtime keeps
//// `--version`, the MCP `serverInfo`, and the `clientInfo` pharos
//// sends as an LSP/MCP client from ever drifting out of sync with the
//// released artifact — five hand-bumped literals once shipped 0.1.3
//// mislabelled as "0.1.2".

/// pharos's version, e.g. `"0.1.4"`. Falls back to `"0.0.0-unknown"`
/// only if the application resource isn't loaded — never in a running
/// server; possible in a bare unit-test process.
@external(erlang, "pharos_version_ffi", "current")
pub fn current() -> String
