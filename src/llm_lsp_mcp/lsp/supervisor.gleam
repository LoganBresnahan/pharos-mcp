//// DynamicSupervisor for LSP clients.
////
//// One child per language registered (rust → rust-analyzer,
//// go → gopls, etc.). Children spawned lazily on first request that
//// needs them; supervised so an LSP crash restarts cleanly.
////
//// Lifecycle policy (kept-warm vs spawn-per-call) is decided in
//// ADR-010, defaulting to kept-warm with optional idle-timeout.
////
//// Stub — DynamicSupervisor wiring lands in Milestone 2.
