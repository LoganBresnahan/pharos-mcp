//// Top-level supervisor tree.
////
//// Children:
////   - MCP transport (stdio and/or HTTP, per CLI flags)
////   - LSP client supervisor (DynamicSupervisor; one child per language)
////   - Tool registry
////   - Bridge client (probes the optional VSCode extension)
////
//// Stub — supervisor and child specs land in Milestone 1.
