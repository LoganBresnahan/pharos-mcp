//// Configuration loader.
////
//// Sources, in precedence order:
////   1. CLI flags (`--tools`, `--transport`, `--bridge-port`, ...)
////   2. Environment variables (`PHAROS_*`)
////   3. Config file (TOML, location TBD per ADR-009)
////   4. Built-in defaults
////
//// Stub — config plumbing lands in Milestone 3 (when language registry
//// becomes user-configurable) and is finalized in Milestone 9.

/// Placeholder so Gleam does not flag this as an empty module.
/// Removed in the milestone that implements this module.
pub const placeholder: Nil = Nil
