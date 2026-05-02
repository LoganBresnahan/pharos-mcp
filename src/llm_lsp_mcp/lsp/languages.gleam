//// Language → command + per-LSP quirks.
////
//// Maps a configured language identifier (e.g., "rust", "go", "ts")
//// to:
////   - the executable command + args to spawn
////   - file extensions / URI schemes to associate
////   - per-LSP `initializationOptions` (rust-analyzer, gopls, ...)
////   - workspace-root discovery hints (look for `Cargo.toml`,
////     `go.mod`, `package.json`, etc.)
////
//// Sensible defaults bundled in Milestone 9; user-overridable via
//// config file.
////
//// Stub — language registry lands in Milestone 3.
