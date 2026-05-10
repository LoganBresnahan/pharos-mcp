# Dogfood pass — 23 languages × 39 tools

**Label:** binary (Run 1, skip perl/ruby/terraform/java)
**Binary:** `/home/oof/pharos-mcp/burrito_out/pharos_linux_x64`
**Result:** **355/523 cells PASS** (67%)

Per-language LSP-bound tools (22): hover, document_symbols, workspace_symbols, get_diagnostics, goto_definition, goto_type_definition, goto_implementation, find_references, signature_help, format_document, code_actions, rename_preview, inlay_hints, semantic_tokens, call_hierarchy_prepare, call_hierarchy_incoming_calls, call_hierarchy_outgoing_calls, type_hierarchy_prepare, type_hierarchy_supertypes, type_hierarchy_subtypes, lsp_request_raw, apply_workspace_edit.

Global one-shot tools (17): echo, runtime_processes, runtime_supervision_tree, runtime_ets_tables, runtime_memory, runtime_applications, runtime_scheduler_util, runtime_log_tail, runtime_log_level, runtime_log_clear, runtime_trace_lsp, runtime_kill_lsp, runtime_trace_calls, runtime_language_config, runtime_set_tool_timeout, runtime_effective_tool_config, runtime_pid_info.

Result keys: `OK` = response without isError. `server gap` = isError carrying -32601 / Method not found / unsupported file type — plumbing fine, LSP doesn't implement it. `FAIL` = anything else.

## (global) (16/17)

| Tool | Result | Note |
|------|--------|------|
| `echo` | OK | ok (14b) |
| `runtime_processes` | OK | ok (12730b) |
| `runtime_supervision_tree` | OK | ok (5762b) |
| `runtime_ets_tables` | OK | ok (3408b) |
| `runtime_memory` | OK | ok (164b) |
| `runtime_applications` | OK | ok (1674b) |
| `runtime_scheduler_util` | OK | ok (865b) |
| `runtime_log_tail` | OK | ok (25027b) |
| `runtime_log_level` | OK | ok (34b) |
| `runtime_log_clear` | OK | ok (16b) |
| `runtime_trace_lsp` | OK | ok (4144b) |
| `runtime_kill_lsp` | OK | ok (66b) |
| `runtime_trace_calls` | FAIL | isError=true: runtime_trace_calls is disabled. Enable it in pharos.toml under [runtime] trace_calls_enabled = true (or set PHAROS_RUNTIME_TRACE_ENABLED=1) and restart pharos |
| `runtime_language_config` | OK | ok (759b) |
| `runtime_set_tool_timeout` | OK | ok (71b) |
| `runtime_effective_tool_config` | OK | ok (196b) |
| `runtime_pid_info` | OK | ok (630b) |

## bash (17/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (4b) |
| `document_symbols` | OK | ok (2135b) |
| `workspace_symbols` | OK | ok (2b) |
| `get_diagnostics` | OK | ok (163b) |
| `goto_definition` | OK | ok (2b) |
| `goto_type_definition` | GAP | server gap (-32601 / unsupported) |
| `goto_implementation` | GAP | server gap (-32601 / unsupported) |
| `find_references` | OK | ok (2b) |
| `signature_help` | GAP | server gap (-32601 / unsupported) |
| `format_document` | OK | ok (57b) |
| `code_actions` | OK | ok (2b) |
| `rename_preview` | FAIL | isError=true: expected WorkspaceEdit shape (changes or documentChanges) |
| `inlay_hints` | GAP | server gap (-32601 / unsupported) |
| `semantic_tokens` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_incoming_calls` | FAIL | prepare returned no item |
| `call_hierarchy_outgoing_calls` | FAIL | prepare returned no item |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `lsp_request_raw` | OK | ok (4b) |
| `apply_workspace_edit` | OK | ok (149b) |

## clojure (20/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (364b) |
| `document_symbols` | OK | ok (143040b) |
| `workspace_symbols` | OK | ok (983b) |
| `get_diagnostics` | OK | ok (38877b) |
| `goto_definition` | OK | ok (156b) |
| `goto_type_definition` | GAP | server gap (-32601 / unsupported) |
| `goto_implementation` | OK | ok (2b) |
| `find_references` | OK | ok (158b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | OK | ok (292071b) |
| `code_actions` | OK | ok (2114b) |
| `rename_preview` | OK | ok (104b) |
| `inlay_hints` | GAP | server gap (-32601 / unsupported) |
| `semantic_tokens` | OK | ok (168010b) |
| `call_hierarchy_prepare` | OK | ok (305b) |
| `call_hierarchy_incoming_calls` | OK | ok (2b) |
| `call_hierarchy_outgoing_calls` | OK | ok (2b) |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `lsp_request_raw` | OK | ok (794b) |
| `apply_workspace_edit` | OK | ok (149b) |

## cpp (20/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (254b) |
| `document_symbols` | OK | ok (20216b) |
| `workspace_symbols` | OK | ok (3821b) |
| `get_diagnostics` | OK | ok (5271b) |
| `goto_definition` | OK | ok (161b) |
| `goto_type_definition` | OK | ok (161b) |
| `goto_implementation` | OK | ok (2b) |
| `find_references` | OK | ok (1457b) |
| `signature_help` | OK | ok (57b) |
| `format_document` | OK | ok (527b) |
| `code_actions` | OK | ok (2b) |
| `rename_preview` | OK | ok (363b) |
| `inlay_hints` | OK | ok (2b) |
| `semantic_tokens` | OK | ok (3900b) |
| `call_hierarchy_prepare` | OK | ok (2b) |
| `call_hierarchy_incoming_calls` | FAIL | prepare returned no item |
| `call_hierarchy_outgoing_calls` | FAIL | prepare returned no item |
| `type_hierarchy_prepare` | OK | ok (327b) |
| `type_hierarchy_supertypes` | OK | ok (2b) |
| `type_hierarchy_subtypes` | OK | ok (2b) |
| `lsp_request_raw` | OK | ok (254b) |
| `apply_workspace_edit` | OK | ok (149b) |

## css (18/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (226b) |
| `document_symbols` | OK | ok (648173b) |
| `workspace_symbols` | GAP | server gap (-32601 / unsupported) |
| `get_diagnostics` | OK | ok (216b) |
| `goto_definition` | OK | ok (147b) |
| `goto_type_definition` | GAP | server gap (-32601 / unsupported) |
| `goto_implementation` | GAP | server gap (-32601 / unsupported) |
| `find_references` | OK | ok (609b) |
| `signature_help` | GAP | server gap (-32601 / unsupported) |
| `format_document` | OK | ok (330005b) |
| `code_actions` | OK | ok (2b) |
| `rename_preview` | OK | ok (186b) |
| `inlay_hints` | GAP | server gap (-32601 / unsupported) |
| `semantic_tokens` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_incoming_calls` | FAIL | prepare returned no item |
| `call_hierarchy_outgoing_calls` | FAIL | prepare returned no item |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `lsp_request_raw` | OK | ok (226b) |
| `apply_workspace_edit` | OK | ok (149b) |

## elixir (14/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (4b) |
| `document_symbols` | OK | ok (2528b) |
| `workspace_symbols` | FAIL | isError=true: server error -32603: Timeout |
| `get_diagnostics` | OK | ok (211b) |
| `goto_definition` | FAIL | isError=true: server error -32603: ** (Protocol.UndefinedError) protocol Enumerable not implemented for %GenLSP.ErrorResponse{message: "Timeout", code: -32603, data: nil} of  |
| `goto_type_definition` | GAP | server gap (-32601 / unsupported) |
| `goto_implementation` | GAP | server gap (-32601 / unsupported) |
| `find_references` | FAIL | isError=true: server error -32603: Timeout |
| `signature_help` | GAP | server gap (-32601 / unsupported) |
| `format_document` | FAIL | isError=true: server error -32603: Timeout |
| `code_actions` | OK | ok (2b) |
| `rename_preview` | GAP | server gap (-32601 / unsupported) |
| `inlay_hints` | GAP | server gap (-32601 / unsupported) |
| `semantic_tokens` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_incoming_calls` | FAIL | prepare returned no item |
| `call_hierarchy_outgoing_calls` | FAIL | prepare returned no item |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `lsp_request_raw` | OK | ok (4b) |
| `apply_workspace_edit` | OK | ok (149b) |

## erlang (19/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (163b) |
| `document_symbols` | OK | ok (8166b) |
| `workspace_symbols` | OK | ok (2b) |
| `get_diagnostics` | OK | ok (6254b) |
| `goto_definition` | OK | ok (352b) |
| `goto_type_definition` | OK | ok (4b) |
| `goto_implementation` | GAP | server gap (-32601 / unsupported) |
| `find_references` | OK | ok (157b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | GAP | server gap (-32601 / unsupported) |
| `code_actions` | OK | ok (2b) |
| `rename_preview` | FAIL | isError=true: server error -32803: Invalid new function name: 'Renamed' |
| `inlay_hints` | OK | ok (322b) |
| `semantic_tokens` | OK | ok (183b) |
| `call_hierarchy_prepare` | OK | ok (269b) |
| `call_hierarchy_incoming_calls` | OK | ok (2b) |
| `call_hierarchy_outgoing_calls` | OK | ok (744b) |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `lsp_request_raw` | OK | ok (163b) |
| `apply_workspace_edit` | OK | ok (149b) |

## gleam (11/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (530b) |
| `document_symbols` | OK | ok (30215b) |
| `workspace_symbols` | FAIL | isError=true: tool timeout: LSP did not respond in time. The LSP may still be indexing — pass a larger `timeout_ms` on this tool call, or call `runtime_set_tool_timeout` to r |
| `get_diagnostics` | OK | ok (216b) |
| `goto_definition` | OK | ok (150b) |
| `goto_type_definition` | OK | ok (2b) |
| `goto_implementation` | FAIL | isError=true: tool timeout: LSP did not respond in time. The LSP may still be indexing — pass a larger `timeout_ms` on this tool call, or call `runtime_set_tool_timeout` to r |
| `find_references` | OK | ok (1894b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | OK | ok (60937b) |
| `code_actions` | OK | ok (2b) |
| `rename_preview` | FAIL | isError=true: server error -32602: Renamed is not a valid name |
| `inlay_hints` | FAIL | isError=true: tool timeout: LSP did not respond in time. The LSP may still be indexing — pass a larger `timeout_ms` on this tool call, or call `runtime_set_tool_timeout` to r |
| `semantic_tokens` | FAIL | isError=true: tool timeout: LSP did not respond in time. The LSP may still be indexing — pass a larger `timeout_ms` on this tool call, or call `runtime_set_tool_timeout` to r |
| `call_hierarchy_prepare` | FAIL | isError=true: tool timeout: LSP did not respond in time. The LSP may still be indexing — pass a larger `timeout_ms` on this tool call, or call `runtime_set_tool_timeout` to r |
| `call_hierarchy_incoming_calls` | FAIL | prepare returned no item |
| `call_hierarchy_outgoing_calls` | FAIL | prepare returned no item |
| `type_hierarchy_prepare` | FAIL | isError=true: tool timeout: LSP did not respond in time. The LSP may still be indexing — pass a larger `timeout_ms` on this tool call, or call `runtime_set_tool_timeout` to r |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `lsp_request_raw` | OK | ok (530b) |
| `apply_workspace_edit` | OK | ok (149b) |

## go (17/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (144b) |
| `document_symbols` | OK | ok (39320b) |
| `workspace_symbols` | OK | ok (5309b) |
| `get_diagnostics` | OK | ok (215b) |
| `goto_definition` | OK | ok (152b) |
| `goto_type_definition` | FAIL | isError=true: server error 0: cannot find type name from type func() |
| `goto_implementation` | FAIL | isError=true: server error 0: init is a function, not a method (query at 'func' token to find matching signatures) |
| `find_references` | OK | ok (152b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | OK | ok (57b) |
| `code_actions` | OK | ok (1595b) |
| `rename_preview` | OK | ok (98b) |
| `inlay_hints` | OK | ok (4b) |
| `semantic_tokens` | OK | ok (11b) |
| `call_hierarchy_prepare` | OK | ok (332b) |
| `call_hierarchy_incoming_calls` | OK | ok (2b) |
| `call_hierarchy_outgoing_calls` | OK | ok (1926b) |
| `type_hierarchy_prepare` | FAIL | isError=true: server error 0: not a type name |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `lsp_request_raw` | OK | ok (144b) |
| `apply_workspace_edit` | OK | ok (149b) |

## haskell (20/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (249b) |
| `document_symbols` | OK | ok (18766b) |
| `workspace_symbols` | OK | ok (3746b) |
| `get_diagnostics` | OK | ok (230b) |
| `goto_definition` | OK | ok (168b) |
| `goto_type_definition` | OK | ok (2b) |
| `goto_implementation` | OK | ok (2b) |
| `find_references` | OK | ok (1337b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | OK | ok (13431b) |
| `code_actions` | OK | ok (2b) |
| `rename_preview` | OK | ok (213b) |
| `inlay_hints` | OK | ok (11959b) |
| `semantic_tokens` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_prepare` | OK | ok (384b) |
| `call_hierarchy_incoming_calls` | OK | ok (2b) |
| `call_hierarchy_outgoing_calls` | OK | ok (975b) |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `lsp_request_raw` | OK | ok (436b) |
| `apply_workspace_edit` | OK | ok (149b) |

## html (17/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (4b) |
| `document_symbols` | OK | ok (672b) |
| `workspace_symbols` | GAP | server gap (-32601 / unsupported) |
| `get_diagnostics` | OK | ok (237b) |
| `goto_definition` | OK | ok (2b) |
| `goto_type_definition` | GAP | server gap (-32601 / unsupported) |
| `goto_implementation` | GAP | server gap (-32601 / unsupported) |
| `find_references` | OK | ok (2b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | OK | ok (195b) |
| `code_actions` | OK | ok (2b) |
| `rename_preview` | FAIL | isError=true: expected WorkspaceEdit shape (changes or documentChanges) |
| `inlay_hints` | GAP | server gap (-32601 / unsupported) |
| `semantic_tokens` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_incoming_calls` | FAIL | prepare returned no item |
| `call_hierarchy_outgoing_calls` | FAIL | prepare returned no item |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `lsp_request_raw` | OK | ok (4b) |
| `apply_workspace_edit` | OK | ok (149b) |

## java (0/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | FAIL | skipped (--skip) |
| `document_symbols` | FAIL | skipped (--skip) |
| `workspace_symbols` | FAIL | skipped (--skip) |
| `get_diagnostics` | FAIL | skipped (--skip) |
| `goto_definition` | FAIL | skipped (--skip) |
| `goto_type_definition` | FAIL | skipped (--skip) |
| `goto_implementation` | FAIL | skipped (--skip) |
| `find_references` | FAIL | skipped (--skip) |
| `signature_help` | FAIL | skipped (--skip) |
| `format_document` | FAIL | skipped (--skip) |
| `code_actions` | FAIL | skipped (--skip) |
| `rename_preview` | FAIL | skipped (--skip) |
| `inlay_hints` | FAIL | skipped (--skip) |
| `semantic_tokens` | FAIL | skipped (--skip) |
| `call_hierarchy_prepare` | FAIL | skipped (--skip) |
| `call_hierarchy_incoming_calls` | FAIL | skipped (--skip) |
| `call_hierarchy_outgoing_calls` | FAIL | skipped (--skip) |
| `type_hierarchy_prepare` | FAIL | skipped (--skip) |
| `type_hierarchy_supertypes` | FAIL | skipped (--skip) |
| `type_hierarchy_subtypes` | FAIL | skipped (--skip) |
| `lsp_request_raw` | FAIL | skipped (--skip) |
| `apply_workspace_edit` | FAIL | skipped (--skip) |

## json (18/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (4b) |
| `document_symbols` | OK | ok (8580b) |
| `workspace_symbols` | GAP | server gap (-32601 / unsupported) |
| `get_diagnostics` | OK | ok (207b) |
| `goto_definition` | GAP | server gap (-32601 / unsupported) |
| `goto_type_definition` | GAP | server gap (-32601 / unsupported) |
| `goto_implementation` | GAP | server gap (-32601 / unsupported) |
| `find_references` | GAP | server gap (-32601 / unsupported) |
| `signature_help` | GAP | server gap (-32601 / unsupported) |
| `format_document` | OK | ok (1400b) |
| `code_actions` | OK | ok (103b) |
| `rename_preview` | GAP | server gap (-32601 / unsupported) |
| `inlay_hints` | GAP | server gap (-32601 / unsupported) |
| `semantic_tokens` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_incoming_calls` | FAIL | prepare returned no item |
| `call_hierarchy_outgoing_calls` | FAIL | prepare returned no item |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `lsp_request_raw` | OK | ok (4b) |
| `apply_workspace_edit` | OK | ok (149b) |

## lua (18/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (67b) |
| `document_symbols` | OK | ok (201384b) |
| `workspace_symbols` | OK | ok (4532b) |
| `get_diagnostics` | OK | ok (7483b) |
| `goto_definition` | OK | ok (345b) |
| `goto_type_definition` | OK | ok (4b) |
| `goto_implementation` | OK | ok (345b) |
| `find_references` | OK | ok (4084b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | OK | ok (65952b) |
| `code_actions` | OK | ok (2b) |
| `rename_preview` | OK | ok (952b) |
| `inlay_hints` | OK | ok (4b) |
| `semantic_tokens` | OK | ok (34479b) |
| `call_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_incoming_calls` | FAIL | prepare returned no item |
| `call_hierarchy_outgoing_calls` | FAIL | prepare returned no item |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `lsp_request_raw` | OK | ok (479b) |
| `apply_workspace_edit` | OK | ok (149b) |

## markdown (17/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (4b) |
| `document_symbols` | OK | ok (1061b) |
| `workspace_symbols` | OK | ok (6022b) |
| `get_diagnostics` | OK | ok (208b) |
| `goto_definition` | OK | ok (4b) |
| `goto_type_definition` | GAP | server gap (-32601 / unsupported) |
| `goto_implementation` | GAP | server gap (-32601 / unsupported) |
| `find_references` | OK | ok (300b) |
| `signature_help` | GAP | server gap (-32601 / unsupported) |
| `format_document` | GAP | server gap (-32601 / unsupported) |
| `code_actions` | OK | ok (592b) |
| `rename_preview` | FAIL | isError=true: expected WorkspaceEdit shape (changes or documentChanges) |
| `inlay_hints` | GAP | server gap (-32601 / unsupported) |
| `semantic_tokens` | OK | ok (11b) |
| `call_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_incoming_calls` | FAIL | prepare returned no item |
| `call_hierarchy_outgoing_calls` | FAIL | prepare returned no item |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `lsp_request_raw` | OK | ok (4b) |
| `apply_workspace_edit` | OK | ok (149b) |

## perl (0/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | FAIL | skipped (--skip) |
| `document_symbols` | FAIL | skipped (--skip) |
| `workspace_symbols` | FAIL | skipped (--skip) |
| `get_diagnostics` | FAIL | skipped (--skip) |
| `goto_definition` | FAIL | skipped (--skip) |
| `goto_type_definition` | FAIL | skipped (--skip) |
| `goto_implementation` | FAIL | skipped (--skip) |
| `find_references` | FAIL | skipped (--skip) |
| `signature_help` | FAIL | skipped (--skip) |
| `format_document` | FAIL | skipped (--skip) |
| `code_actions` | FAIL | skipped (--skip) |
| `rename_preview` | FAIL | skipped (--skip) |
| `inlay_hints` | FAIL | skipped (--skip) |
| `semantic_tokens` | FAIL | skipped (--skip) |
| `call_hierarchy_prepare` | FAIL | skipped (--skip) |
| `call_hierarchy_incoming_calls` | FAIL | skipped (--skip) |
| `call_hierarchy_outgoing_calls` | FAIL | skipped (--skip) |
| `type_hierarchy_prepare` | FAIL | skipped (--skip) |
| `type_hierarchy_supertypes` | FAIL | skipped (--skip) |
| `type_hierarchy_subtypes` | FAIL | skipped (--skip) |
| `lsp_request_raw` | FAIL | skipped (--skip) |
| `apply_workspace_edit` | FAIL | skipped (--skip) |

## python (20/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (219b) |
| `document_symbols` | OK | ok (42034b) |
| `workspace_symbols` | OK | ok (400b) |
| `get_diagnostics` | OK | ok (7929b) |
| `goto_definition` | OK | ok (149b) |
| `goto_type_definition` | OK | ok (149b) |
| `goto_implementation` | GAP | server gap (-32601 / unsupported) |
| `find_references` | OK | ok (149b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | OK | ok (57b) |
| `code_actions` | OK | ok (209b) |
| `rename_preview` | OK | ok (95b) |
| `inlay_hints` | GAP | server gap (-32601 / unsupported) |
| `semantic_tokens` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_prepare` | OK | ok (270b) |
| `call_hierarchy_incoming_calls` | OK | ok (4b) |
| `call_hierarchy_outgoing_calls` | OK | ok (825b) |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `lsp_request_raw` | OK | ok (219b) |
| `apply_workspace_edit` | OK | ok (149b) |

## ruby (0/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | FAIL | skipped (--skip) |
| `document_symbols` | FAIL | skipped (--skip) |
| `workspace_symbols` | FAIL | skipped (--skip) |
| `get_diagnostics` | FAIL | skipped (--skip) |
| `goto_definition` | FAIL | skipped (--skip) |
| `goto_type_definition` | FAIL | skipped (--skip) |
| `goto_implementation` | FAIL | skipped (--skip) |
| `find_references` | FAIL | skipped (--skip) |
| `signature_help` | FAIL | skipped (--skip) |
| `format_document` | FAIL | skipped (--skip) |
| `code_actions` | FAIL | skipped (--skip) |
| `rename_preview` | FAIL | skipped (--skip) |
| `inlay_hints` | FAIL | skipped (--skip) |
| `semantic_tokens` | FAIL | skipped (--skip) |
| `call_hierarchy_prepare` | FAIL | skipped (--skip) |
| `call_hierarchy_incoming_calls` | FAIL | skipped (--skip) |
| `call_hierarchy_outgoing_calls` | FAIL | skipped (--skip) |
| `type_hierarchy_prepare` | FAIL | skipped (--skip) |
| `type_hierarchy_supertypes` | FAIL | skipped (--skip) |
| `type_hierarchy_subtypes` | FAIL | skipped (--skip) |
| `lsp_request_raw` | FAIL | skipped (--skip) |
| `apply_workspace_edit` | FAIL | skipped (--skip) |

## rust (20/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (222b) |
| `document_symbols` | OK | ok (3287b) |
| `workspace_symbols` | OK | ok (197b) |
| `get_diagnostics` | OK | ok (211b) |
| `goto_definition` | OK | ok (348b) |
| `goto_type_definition` | OK | ok (2b) |
| `goto_implementation` | OK | ok (2b) |
| `find_references` | OK | ok (937b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | OK | ok (57b) |
| `code_actions` | OK | ok (5699b) |
| `rename_preview` | OK | ok (398b) |
| `inlay_hints` | OK | ok (2203b) |
| `semantic_tokens` | OK | ok (7466b) |
| `call_hierarchy_prepare` | OK | ok (344b) |
| `call_hierarchy_incoming_calls` | OK | ok (970b) |
| `call_hierarchy_outgoing_calls` | OK | ok (2364b) |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `lsp_request_raw` | OK | ok (222b) |
| `apply_workspace_edit` | OK | ok (149b) |

## scala (18/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (77b) |
| `document_symbols` | OK | ok (16453b) |
| `workspace_symbols` | FAIL | isError=true: tool timeout: LSP did not respond in time. The LSP may still be indexing — pass a larger `timeout_ms` on this tool call, or call `runtime_set_tool_timeout` to r |
| `get_diagnostics` | OK | ok (225b) |
| `goto_definition` | OK | ok (159b) |
| `goto_type_definition` | OK | ok (163b) |
| `goto_implementation` | OK | ok (2b) |
| `find_references` | OK | ok (321b) |
| `signature_help` | OK | ok (57b) |
| `format_document` | OK | ok (57b) |
| `code_actions` | OK | ok (2b) |
| `rename_preview` | FAIL | isError=true: expected WorkspaceEdit shape (changes or documentChanges) |
| `inlay_hints` | FAIL | isError=true: tool timeout: LSP did not respond in time. The LSP may still be indexing — pass a larger `timeout_ms` on this tool call, or call `runtime_set_tool_timeout` to r |
| `semantic_tokens` | FAIL | isError=true: tool timeout: LSP did not respond in time. The LSP may still be indexing — pass a larger `timeout_ms` on this tool call, or call `runtime_set_tool_timeout` to r |
| `call_hierarchy_prepare` | OK | ok (430b) |
| `call_hierarchy_incoming_calls` | OK | ok (530b) |
| `call_hierarchy_outgoing_calls` | OK | ok (1229b) |
| `type_hierarchy_prepare` | OK | ok (326b) |
| `type_hierarchy_supertypes` | OK | ok (2b) |
| `type_hierarchy_subtypes` | OK | ok (2b) |
| `lsp_request_raw` | OK | ok (77b) |
| `apply_workspace_edit` | OK | ok (149b) |

## terraform (0/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | FAIL | skipped (--skip) |
| `document_symbols` | FAIL | skipped (--skip) |
| `workspace_symbols` | FAIL | skipped (--skip) |
| `get_diagnostics` | FAIL | skipped (--skip) |
| `goto_definition` | FAIL | skipped (--skip) |
| `goto_type_definition` | FAIL | skipped (--skip) |
| `goto_implementation` | FAIL | skipped (--skip) |
| `find_references` | FAIL | skipped (--skip) |
| `signature_help` | FAIL | skipped (--skip) |
| `format_document` | FAIL | skipped (--skip) |
| `code_actions` | FAIL | skipped (--skip) |
| `rename_preview` | FAIL | skipped (--skip) |
| `inlay_hints` | FAIL | skipped (--skip) |
| `semantic_tokens` | FAIL | skipped (--skip) |
| `call_hierarchy_prepare` | FAIL | skipped (--skip) |
| `call_hierarchy_incoming_calls` | FAIL | skipped (--skip) |
| `call_hierarchy_outgoing_calls` | FAIL | skipped (--skip) |
| `type_hierarchy_prepare` | FAIL | skipped (--skip) |
| `type_hierarchy_supertypes` | FAIL | skipped (--skip) |
| `type_hierarchy_subtypes` | FAIL | skipped (--skip) |
| `lsp_request_raw` | FAIL | skipped (--skip) |
| `apply_workspace_edit` | FAIL | skipped (--skip) |

## typescript (20/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (308b) |
| `document_symbols` | OK | ok (9189b) |
| `workspace_symbols` | OK | ok (607b) |
| `get_diagnostics` | OK | ok (157b) |
| `goto_definition` | OK | ok (344b) |
| `goto_type_definition` | OK | ok (148b) |
| `goto_implementation` | OK | ok (149b) |
| `find_references` | OK | ok (1350b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | OK | ok (2064b) |
| `code_actions` | OK | ok (1196b) |
| `rename_preview` | OK | ok (336b) |
| `inlay_hints` | OK | ok (2b) |
| `semantic_tokens` | OK | ok (1317b) |
| `call_hierarchy_prepare` | OK | ok (277b) |
| `call_hierarchy_incoming_calls` | OK | ok (867b) |
| `call_hierarchy_outgoing_calls` | OK | ok (2614b) |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `lsp_request_raw` | OK | ok (308b) |
| `apply_workspace_edit` | OK | ok (149b) |

## yaml (17/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (4b) |
| `document_symbols` | OK | ok (7843b) |
| `workspace_symbols` | GAP | server gap (-32601 / unsupported) |
| `get_diagnostics` | OK | ok (161b) |
| `goto_definition` | OK | ok (4b) |
| `goto_type_definition` | GAP | server gap (-32601 / unsupported) |
| `goto_implementation` | GAP | server gap (-32601 / unsupported) |
| `find_references` | GAP | server gap (-32601 / unsupported) |
| `signature_help` | GAP | server gap (-32601 / unsupported) |
| `format_document` | OK | ok (903b) |
| `code_actions` | OK | ok (2b) |
| `rename_preview` | FAIL | isError=true: expected WorkspaceEdit shape (changes or documentChanges) |
| `inlay_hints` | GAP | server gap (-32601 / unsupported) |
| `semantic_tokens` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_incoming_calls` | FAIL | prepare returned no item |
| `call_hierarchy_outgoing_calls` | FAIL | prepare returned no item |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `lsp_request_raw` | OK | ok (4b) |
| `apply_workspace_edit` | OK | ok (149b) |

## zig (18/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (182b) |
| `document_symbols` | OK | ok (89045b) |
| `workspace_symbols` | OK | ok (4b) |
| `get_diagnostics` | OK | ok (312b) |
| `goto_definition` | OK | ok (329b) |
| `goto_type_definition` | OK | ok (4b) |
| `goto_implementation` | OK | ok (329b) |
| `find_references` | OK | ok (50744b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | OK | ok (57b) |
| `code_actions` | OK | ok (5124b) |
| `rename_preview` | OK | ok (11366b) |
| `inlay_hints` | OK | ok (108b) |
| `semantic_tokens` | OK | ok (287783b) |
| `call_hierarchy_prepare` | OK | ok (4b) |
| `call_hierarchy_incoming_calls` | FAIL | prepare returned no item |
| `call_hierarchy_outgoing_calls` | FAIL | prepare returned no item |
| `type_hierarchy_prepare` | OK | ok (4b) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `lsp_request_raw` | OK | ok (182b) |
| `apply_workspace_edit` | OK | ok (149b) |
