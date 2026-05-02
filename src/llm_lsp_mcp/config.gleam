//// Configuration loader.
////
//// Sources, in precedence order:
////   1. CLI flags (`--tools`, `--transport`, `--bridge-port`, ...)
////   2. Environment variables (`LLM_LSP_MCP_*`)
////   3. Config file (TOML, location TBD per ADR-009)
////   4. Built-in defaults
////
//// Stub — config plumbing lands in Milestone 3 (when language registry
//// becomes user-configurable) and is finalized in Milestone 9.
