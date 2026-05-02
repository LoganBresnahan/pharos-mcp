//// OTP application entry point.
////
//// `mix.exs` wires this module as the `mod:` callback. On BEAM boot
//// the application controller calls `start/2` here, which starts the
//// top-level supervisor tree (see `llm_lsp_mcp/supervisor`).
////
//// Stub — wiring lands in Milestone 1 once the supervisor tree has
//// real children. For Milestone 0 the OTP application boots empty.
