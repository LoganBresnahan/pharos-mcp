//// Structured logging to stderr.
////
//// **Stdout is reserved for MCP protocol traffic.** Every log line MUST
//// go to stderr. A single stray write to stdout breaks the binary for
//// every user. This module is the only place log output is produced.

import gleam/io

/// Emit an informational message on stderr.
pub fn info(message: String) -> Nil {
  io.println_error("[info] " <> message)
}

/// Emit a warning on stderr.
pub fn warn(message: String) -> Nil {
  io.println_error("[warn] " <> message)
}

/// Emit an error on stderr.
pub fn error(message: String) -> Nil {
  io.println_error("[error] " <> message)
}
