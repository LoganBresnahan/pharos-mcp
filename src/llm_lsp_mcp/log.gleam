//// Structured logging to stderr.
////
//// **Stdout is reserved for MCP protocol traffic.** Every log line MUST
//// go to stderr. A single stray write to stdout breaks the binary for
//// every user. This module is the only place log output is produced.
////
//// Stub — logging facade lands alongside the first real subsystem in
//// Milestone 1.

/// Placeholder so Gleam does not flag this as an empty module.
/// Removed in the milestone that implements this module.
pub const placeholder: Nil = Nil
