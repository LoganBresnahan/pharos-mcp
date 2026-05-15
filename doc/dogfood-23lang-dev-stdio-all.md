# Dogfood pass — 23 languages × 39 tools

**Label:** B (trust spawner) / dev / stdio / all
**Binary:** `bin/pharos-dev`
**Transport:** `stdio`
**Profile:** `all`
**Result:** **141/524 cells PASS** (26%)

Per-language LSP-bound tools (22): hover, document_symbols, workspace_symbols, get_diagnostics, goto_definition, goto_type_definition, goto_implementation, find_references, signature_help, format_document, code_actions, rename_preview, inlay_hints, semantic_tokens, call_hierarchy_prepare, call_hierarchy_incoming_calls, call_hierarchy_outgoing_calls, type_hierarchy_prepare, type_hierarchy_supertypes, type_hierarchy_subtypes, lsp_request_raw, apply_workspace_edit.

Global one-shot tools (17): echo, runtime_processes, runtime_supervision_tree, runtime_ets_tables, runtime_memory, runtime_applications, runtime_scheduler_util, runtime_log_tail, runtime_log_level, runtime_log_clear, runtime_trace_lsp, runtime_kill_lsp, runtime_trace_calls, runtime_language_config, runtime_set_tool_timeout, runtime_effective_tool_config, runtime_pid_info.

Result keys: `OK` = response without isError. `server gap` = isError carrying -32601 / Method not found / unsupported file type — plumbing fine, LSP doesn't implement it. `FAIL` = anything else. `OK (after retry …)` = first call timed out, harness fired `runtime_set_tool_timeout` to bump the budget, retry passed. `filter rejected (default profile)` rows mark tools the default profile is configured to deny — graceful filter, not a defect.

## (global) (15/18)

| Tool | Result | Note |
|------|--------|------|
| `echo` | OK | ok (14b) |
| `runtime_processes` | OK | ok (7556b) |
| `runtime_supervision_tree` | OK | ok (1862b) |
| `runtime_ets_tables` | OK | ok (3054b) |
| `runtime_memory` | OK | ok (160b) |
| `runtime_applications` | OK | ok (136b) |
| `runtime_scheduler_util` | OK | ok (864b) |
| `runtime_log_tail` | OK | ok (32894b) |
| `runtime_log_level` | OK | ok (34b) |
| `runtime_log_clear` | OK | ok (16b) |
| `runtime_trace_lsp` | OK | ok (2653b) |
| `runtime_kill_lsp` | FAIL | no response within 30s |
| `runtime_trace_calls` | FAIL | isError=true: runtime_trace_calls is disabled. Enable it in pharos.toml under [runtime] trace_calls_enabled = true (or set PHAROS_RUNTIME_TRACE_ENABLED=1) and restart pharos |
| `runtime_language_config` | OK | ok (755b) |
| `runtime_set_tool_timeout` | OK | ok (71b) |
| `runtime_effective_tool_config` | OK | ok (338b) |
| `runtime_pid_info` | OK | ok (646b) |
| `runtime_lsp_state` | FAIL | no response within 30s |

## bash (0/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | FAIL | retry exhausted: no response within 95s |
| `document_symbols` | FAIL | retry exhausted: no response within 95s |
| `workspace_symbols` | FAIL | retry exhausted: no response within 95s |
| `get_diagnostics` | FAIL | lsp unresponsive (short-circuited) |
| `goto_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_type_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_implementation` | FAIL | lsp unresponsive (short-circuited) |
| `find_references` | FAIL | lsp unresponsive (short-circuited) |
| `signature_help` | FAIL | lsp unresponsive (short-circuited) |
| `format_document` | FAIL | lsp unresponsive (short-circuited) |
| `code_actions` | FAIL | lsp unresponsive (short-circuited) |
| `rename_preview` | FAIL | lsp unresponsive (short-circuited) |
| `inlay_hints` | FAIL | lsp unresponsive (short-circuited) |
| `semantic_tokens` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_incoming_calls` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_outgoing_calls` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_supertypes` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_subtypes` | FAIL | lsp unresponsive (short-circuited) |
| `lsp_request_raw` | FAIL | lsp unresponsive (short-circuited) |
| `apply_workspace_edit` | FAIL | lsp unresponsive (short-circuited) |

## clojure (0/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | FAIL | retry exhausted: no response within 95s |
| `document_symbols` | FAIL | retry exhausted: no response within 95s |
| `workspace_symbols` | FAIL | retry exhausted: no response within 95s |
| `get_diagnostics` | FAIL | lsp unresponsive (short-circuited) |
| `goto_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_type_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_implementation` | FAIL | lsp unresponsive (short-circuited) |
| `find_references` | FAIL | lsp unresponsive (short-circuited) |
| `signature_help` | FAIL | lsp unresponsive (short-circuited) |
| `format_document` | FAIL | lsp unresponsive (short-circuited) |
| `code_actions` | FAIL | lsp unresponsive (short-circuited) |
| `rename_preview` | FAIL | lsp unresponsive (short-circuited) |
| `inlay_hints` | FAIL | lsp unresponsive (short-circuited) |
| `semantic_tokens` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_incoming_calls` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_outgoing_calls` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_supertypes` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_subtypes` | FAIL | lsp unresponsive (short-circuited) |
| `lsp_request_raw` | FAIL | lsp unresponsive (short-circuited) |
| `apply_workspace_edit` | FAIL | lsp unresponsive (short-circuited) |

## cpp (20/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (254b) |
| `document_symbols` | OK | ok (20216b) |
| `workspace_symbols` | OK | ok (5321b) |
| `get_diagnostics` | OK | ok (5275b) |
| `goto_definition` | OK | ok (165b) |
| `goto_type_definition` | OK | ok (165b) |
| `goto_implementation` | OK | ok (2b) |
| `find_references` | OK | ok (1493b) |
| `signature_help` | OK | ok (57b) |
| `format_document` | OK | ok (531b) |
| `code_actions` | OK | ok (2b) |
| `rename_preview` | OK | ok (367b) |
| `inlay_hints` | OK | ok (2b) |
| `semantic_tokens` | OK | ok (3900b) |
| `call_hierarchy_prepare` | OK | ok (2b) |
| `call_hierarchy_incoming_calls` | FAIL | prepare returned no item |
| `call_hierarchy_outgoing_calls` | FAIL | prepare returned no item |
| `type_hierarchy_prepare` | OK | ok (331b) |
| `type_hierarchy_supertypes` | OK | ok (2b) |
| `type_hierarchy_subtypes` | OK | ok (2b) |
| `lsp_request_raw` | OK | ok (254b) |
| `apply_workspace_edit` | OK | ok (149b) |

## css (0/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | FAIL | retry exhausted: no response within 95s |
| `document_symbols` | FAIL | retry exhausted: no response within 95s |
| `workspace_symbols` | FAIL | retry exhausted: no response within 95s |
| `get_diagnostics` | FAIL | lsp unresponsive (short-circuited) |
| `goto_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_type_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_implementation` | FAIL | lsp unresponsive (short-circuited) |
| `find_references` | FAIL | lsp unresponsive (short-circuited) |
| `signature_help` | FAIL | lsp unresponsive (short-circuited) |
| `format_document` | FAIL | lsp unresponsive (short-circuited) |
| `code_actions` | FAIL | lsp unresponsive (short-circuited) |
| `rename_preview` | FAIL | lsp unresponsive (short-circuited) |
| `inlay_hints` | FAIL | lsp unresponsive (short-circuited) |
| `semantic_tokens` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_incoming_calls` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_outgoing_calls` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_supertypes` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_subtypes` | FAIL | lsp unresponsive (short-circuited) |
| `lsp_request_raw` | FAIL | lsp unresponsive (short-circuited) |
| `apply_workspace_edit` | FAIL | lsp unresponsive (short-circuited) |

## elixir (14/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (4b) |
| `document_symbols` | OK | ok (2528b) |
| `workspace_symbols` | FAIL | isError=true: server error -32603: Timeout |
| `get_diagnostics` | OK | ok (215b) |
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

## erlang (0/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | FAIL | no response within 285s |
| `document_symbols` | FAIL | no response within 285s |
| `workspace_symbols` | FAIL | no response within 285s |
| `get_diagnostics` | FAIL | lsp unresponsive (short-circuited) |
| `goto_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_type_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_implementation` | FAIL | lsp unresponsive (short-circuited) |
| `find_references` | FAIL | lsp unresponsive (short-circuited) |
| `signature_help` | FAIL | lsp unresponsive (short-circuited) |
| `format_document` | FAIL | lsp unresponsive (short-circuited) |
| `code_actions` | FAIL | lsp unresponsive (short-circuited) |
| `rename_preview` | FAIL | lsp unresponsive (short-circuited) |
| `inlay_hints` | FAIL | lsp unresponsive (short-circuited) |
| `semantic_tokens` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_incoming_calls` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_outgoing_calls` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_supertypes` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_subtypes` | FAIL | lsp unresponsive (short-circuited) |
| `lsp_request_raw` | FAIL | lsp unresponsive (short-circuited) |
| `apply_workspace_edit` | FAIL | lsp unresponsive (short-circuited) |

## gleam (0/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | FAIL | no response within 285s |
| `document_symbols` | FAIL | no response within 285s |
| `workspace_symbols` | FAIL | no response within 285s |
| `get_diagnostics` | FAIL | lsp unresponsive (short-circuited) |
| `goto_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_type_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_implementation` | FAIL | lsp unresponsive (short-circuited) |
| `find_references` | FAIL | lsp unresponsive (short-circuited) |
| `signature_help` | FAIL | lsp unresponsive (short-circuited) |
| `format_document` | FAIL | lsp unresponsive (short-circuited) |
| `code_actions` | FAIL | lsp unresponsive (short-circuited) |
| `rename_preview` | FAIL | lsp unresponsive (short-circuited) |
| `inlay_hints` | FAIL | lsp unresponsive (short-circuited) |
| `semantic_tokens` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_incoming_calls` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_outgoing_calls` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_supertypes` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_subtypes` | FAIL | lsp unresponsive (short-circuited) |
| `lsp_request_raw` | FAIL | lsp unresponsive (short-circuited) |
| `apply_workspace_edit` | FAIL | lsp unresponsive (short-circuited) |

## go (19/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (1582b) |
| `document_symbols` | OK | ok (39320b) |
| `workspace_symbols` | OK | ok (5632b) |
| `get_diagnostics` | OK | ok (175b) |
| `goto_definition` | OK | ok (157b) |
| `goto_type_definition` | OK | ok (157b) |
| `goto_implementation` | OK | ok (4b) |
| `find_references` | OK | ok (469b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | OK | ok (57b) |
| `code_actions` | OK | ok (1379b) |
| `rename_preview` | OK | ok (163b) |
| `inlay_hints` | OK | ok (4b) |
| `semantic_tokens` | OK | ok (11b) |
| `call_hierarchy_prepare` | FAIL | isError=true: server error 0: flagConfig is not a function |
| `call_hierarchy_incoming_calls` | FAIL | prepare returned no item |
| `call_hierarchy_outgoing_calls` | FAIL | prepare returned no item |
| `type_hierarchy_prepare` | OK | ok (333b) |
| `type_hierarchy_supertypes` | OK | ok (4b) |
| `type_hierarchy_subtypes` | OK | ok (4b) |
| `lsp_request_raw` | OK | ok (1582b) |
| `apply_workspace_edit` | OK | ok (149b) |

## haskell (0/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | FAIL | no response within 225s |
| `document_symbols` | FAIL | no response within 225s |
| `workspace_symbols` | FAIL | no response within 225s |
| `get_diagnostics` | FAIL | lsp unresponsive (short-circuited) |
| `goto_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_type_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_implementation` | FAIL | lsp unresponsive (short-circuited) |
| `find_references` | FAIL | lsp unresponsive (short-circuited) |
| `signature_help` | FAIL | lsp unresponsive (short-circuited) |
| `format_document` | FAIL | lsp unresponsive (short-circuited) |
| `code_actions` | FAIL | lsp unresponsive (short-circuited) |
| `rename_preview` | FAIL | lsp unresponsive (short-circuited) |
| `inlay_hints` | FAIL | lsp unresponsive (short-circuited) |
| `semantic_tokens` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_incoming_calls` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_outgoing_calls` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_supertypes` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_subtypes` | FAIL | lsp unresponsive (short-circuited) |
| `lsp_request_raw` | FAIL | lsp unresponsive (short-circuited) |
| `apply_workspace_edit` | FAIL | lsp unresponsive (short-circuited) |

## html (0/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | FAIL | retry exhausted: no response within 95s |
| `document_symbols` | FAIL | retry exhausted: no response within 95s |
| `workspace_symbols` | FAIL | retry exhausted: no response within 95s |
| `get_diagnostics` | FAIL | lsp unresponsive (short-circuited) |
| `goto_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_type_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_implementation` | FAIL | lsp unresponsive (short-circuited) |
| `find_references` | FAIL | lsp unresponsive (short-circuited) |
| `signature_help` | FAIL | lsp unresponsive (short-circuited) |
| `format_document` | FAIL | lsp unresponsive (short-circuited) |
| `code_actions` | FAIL | lsp unresponsive (short-circuited) |
| `rename_preview` | FAIL | lsp unresponsive (short-circuited) |
| `inlay_hints` | FAIL | lsp unresponsive (short-circuited) |
| `semantic_tokens` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_incoming_calls` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_outgoing_calls` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_supertypes` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_subtypes` | FAIL | lsp unresponsive (short-circuited) |
| `lsp_request_raw` | FAIL | lsp unresponsive (short-circuited) |
| `apply_workspace_edit` | FAIL | lsp unresponsive (short-circuited) |

## java (0/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | FAIL | no response within 645s |
| `document_symbols` | FAIL | no response within 645s |
| `workspace_symbols` | FAIL | no response within 645s |
| `get_diagnostics` | FAIL | lsp unresponsive (short-circuited) |
| `goto_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_type_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_implementation` | FAIL | lsp unresponsive (short-circuited) |
| `find_references` | FAIL | lsp unresponsive (short-circuited) |
| `signature_help` | FAIL | lsp unresponsive (short-circuited) |
| `format_document` | FAIL | lsp unresponsive (short-circuited) |
| `code_actions` | FAIL | lsp unresponsive (short-circuited) |
| `rename_preview` | FAIL | lsp unresponsive (short-circuited) |
| `inlay_hints` | FAIL | lsp unresponsive (short-circuited) |
| `semantic_tokens` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_incoming_calls` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_outgoing_calls` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_supertypes` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_subtypes` | FAIL | lsp unresponsive (short-circuited) |
| `lsp_request_raw` | FAIL | lsp unresponsive (short-circuited) |
| `apply_workspace_edit` | FAIL | lsp unresponsive (short-circuited) |

## json (0/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | FAIL | retry exhausted: no response within 95s |
| `document_symbols` | FAIL | retry exhausted: no response within 95s |
| `workspace_symbols` | FAIL | retry exhausted: no response within 95s |
| `get_diagnostics` | FAIL | lsp unresponsive (short-circuited) |
| `goto_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_type_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_implementation` | FAIL | lsp unresponsive (short-circuited) |
| `find_references` | FAIL | lsp unresponsive (short-circuited) |
| `signature_help` | FAIL | lsp unresponsive (short-circuited) |
| `format_document` | FAIL | lsp unresponsive (short-circuited) |
| `code_actions` | FAIL | lsp unresponsive (short-circuited) |
| `rename_preview` | FAIL | lsp unresponsive (short-circuited) |
| `inlay_hints` | FAIL | lsp unresponsive (short-circuited) |
| `semantic_tokens` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_incoming_calls` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_outgoing_calls` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_supertypes` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_subtypes` | FAIL | lsp unresponsive (short-circuited) |
| `lsp_request_raw` | FAIL | lsp unresponsive (short-circuited) |
| `apply_workspace_edit` | FAIL | lsp unresponsive (short-circuited) |

## lua (0/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | FAIL | retry exhausted: no response within 95s |
| `document_symbols` | FAIL | retry exhausted: no response within 95s |
| `workspace_symbols` | FAIL | retry exhausted: no response within 95s |
| `get_diagnostics` | FAIL | lsp unresponsive (short-circuited) |
| `goto_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_type_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_implementation` | FAIL | lsp unresponsive (short-circuited) |
| `find_references` | FAIL | lsp unresponsive (short-circuited) |
| `signature_help` | FAIL | lsp unresponsive (short-circuited) |
| `format_document` | FAIL | lsp unresponsive (short-circuited) |
| `code_actions` | FAIL | lsp unresponsive (short-circuited) |
| `rename_preview` | FAIL | lsp unresponsive (short-circuited) |
| `inlay_hints` | FAIL | lsp unresponsive (short-circuited) |
| `semantic_tokens` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_incoming_calls` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_outgoing_calls` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_supertypes` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_subtypes` | FAIL | lsp unresponsive (short-circuited) |
| `lsp_request_raw` | FAIL | lsp unresponsive (short-circuited) |
| `apply_workspace_edit` | FAIL | lsp unresponsive (short-circuited) |

## markdown (0/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | FAIL | retry exhausted: no response within 95s |
| `document_symbols` | FAIL | retry exhausted: no response within 95s |
| `workspace_symbols` | FAIL | retry exhausted: no response within 95s |
| `get_diagnostics` | FAIL | lsp unresponsive (short-circuited) |
| `goto_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_type_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_implementation` | FAIL | lsp unresponsive (short-circuited) |
| `find_references` | FAIL | lsp unresponsive (short-circuited) |
| `signature_help` | FAIL | lsp unresponsive (short-circuited) |
| `format_document` | FAIL | lsp unresponsive (short-circuited) |
| `code_actions` | FAIL | lsp unresponsive (short-circuited) |
| `rename_preview` | FAIL | lsp unresponsive (short-circuited) |
| `inlay_hints` | FAIL | lsp unresponsive (short-circuited) |
| `semantic_tokens` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_incoming_calls` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_outgoing_calls` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_supertypes` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_subtypes` | FAIL | lsp unresponsive (short-circuited) |
| `lsp_request_raw` | FAIL | lsp unresponsive (short-circuited) |
| `apply_workspace_edit` | FAIL | lsp unresponsive (short-circuited) |

## perl (0/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | FAIL | no response within 285s |
| `document_symbols` | FAIL | no response within 285s |
| `workspace_symbols` | FAIL | no response within 285s |
| `get_diagnostics` | FAIL | lsp unresponsive (short-circuited) |
| `goto_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_type_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_implementation` | FAIL | lsp unresponsive (short-circuited) |
| `find_references` | FAIL | lsp unresponsive (short-circuited) |
| `signature_help` | FAIL | lsp unresponsive (short-circuited) |
| `format_document` | FAIL | lsp unresponsive (short-circuited) |
| `code_actions` | FAIL | lsp unresponsive (short-circuited) |
| `rename_preview` | FAIL | lsp unresponsive (short-circuited) |
| `inlay_hints` | FAIL | lsp unresponsive (short-circuited) |
| `semantic_tokens` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_incoming_calls` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_outgoing_calls` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_supertypes` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_subtypes` | FAIL | lsp unresponsive (short-circuited) |
| `lsp_request_raw` | FAIL | lsp unresponsive (short-circuited) |
| `apply_workspace_edit` | FAIL | lsp unresponsive (short-circuited) |

## python (0/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | FAIL | retry exhausted: no response within 95s |
| `document_symbols` | FAIL | retry exhausted: no response within 95s |
| `workspace_symbols` | FAIL | retry exhausted: no response within 95s |
| `get_diagnostics` | FAIL | lsp unresponsive (short-circuited) |
| `goto_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_type_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_implementation` | FAIL | lsp unresponsive (short-circuited) |
| `find_references` | FAIL | lsp unresponsive (short-circuited) |
| `signature_help` | FAIL | lsp unresponsive (short-circuited) |
| `format_document` | FAIL | lsp unresponsive (short-circuited) |
| `code_actions` | FAIL | lsp unresponsive (short-circuited) |
| `rename_preview` | FAIL | lsp unresponsive (short-circuited) |
| `inlay_hints` | FAIL | lsp unresponsive (short-circuited) |
| `semantic_tokens` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_incoming_calls` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_outgoing_calls` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_supertypes` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_subtypes` | FAIL | lsp unresponsive (short-circuited) |
| `lsp_request_raw` | FAIL | lsp unresponsive (short-circuited) |
| `apply_workspace_edit` | FAIL | lsp unresponsive (short-circuited) |

## ruby (15/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (4b) |
| `document_symbols` | OK | ok (65550b) |
| `workspace_symbols` | OK | ok (421b) |
| `get_diagnostics` | OK | ok (218b) |
| `goto_definition` | OK | ok (2b) |
| `goto_type_definition` | FAIL | retry exhausted: no response within 95s |
| `goto_implementation` | FAIL | retry exhausted: no response within 95s |
| `find_references` | OK | ok (55932b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | OK | ok (72665b) |
| `code_actions` | OK | ok (691b) |
| `rename_preview` | OK | ok (43b) |
| `inlay_hints` | OK | ok (2b) |
| `semantic_tokens` | OK | ok (15590b) |
| `call_hierarchy_prepare` | FAIL | retry exhausted: no response within 95s |
| `call_hierarchy_incoming_calls` | FAIL | prepare returned no item |
| `call_hierarchy_outgoing_calls` | FAIL | prepare returned no item |
| `type_hierarchy_prepare` | OK | ok (4b) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `lsp_request_raw` | OK | ok (4b) |
| `apply_workspace_edit` | OK | ok (149b) |

## rust (20/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (222b) |
| `document_symbols` | OK | ok (3287b) |
| `workspace_symbols` | OK | ok (201b) |
| `get_diagnostics` | OK | ok (215b) |
| `goto_definition` | OK | ok (352b) |
| `goto_type_definition` | OK | ok (2b) |
| `goto_implementation` | OK | ok (2b) |
| `find_references` | OK | ok (961b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | OK | ok (57b) |
| `code_actions` | OK | ok (5687b) |
| `rename_preview` | OK | ok (410b) |
| `inlay_hints` | OK | ok (2207b) |
| `semantic_tokens` | OK | ok (7466b) |
| `call_hierarchy_prepare` | OK | ok (348b) |
| `call_hierarchy_incoming_calls` | OK | ok (978b) |
| `call_hierarchy_outgoing_calls` | OK | ok (2368b) |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `lsp_request_raw` | OK | ok (222b) |
| `apply_workspace_edit` | OK | ok (149b) |

## scala (0/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | FAIL | isError=true: LSP spawn failed: readiness probe never succeeded: ready_timeout_ms (240000ms) would be exceeded by next backoff sleep; last error: transport error during probe |
| `document_symbols` | FAIL | no response within 345s |
| `workspace_symbols` | FAIL | no response within 345s |
| `get_diagnostics` | FAIL | no response within 345s |
| `goto_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_type_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_implementation` | FAIL | lsp unresponsive (short-circuited) |
| `find_references` | FAIL | lsp unresponsive (short-circuited) |
| `signature_help` | FAIL | lsp unresponsive (short-circuited) |
| `format_document` | FAIL | lsp unresponsive (short-circuited) |
| `code_actions` | FAIL | lsp unresponsive (short-circuited) |
| `rename_preview` | FAIL | lsp unresponsive (short-circuited) |
| `inlay_hints` | FAIL | lsp unresponsive (short-circuited) |
| `semantic_tokens` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_incoming_calls` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_outgoing_calls` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_supertypes` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_subtypes` | FAIL | lsp unresponsive (short-circuited) |
| `lsp_request_raw` | FAIL | lsp unresponsive (short-circuited) |
| `apply_workspace_edit` | FAIL | lsp unresponsive (short-circuited) |

## terraform (0/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | FAIL | retry exhausted: no response within 95s |
| `document_symbols` | FAIL | retry exhausted: no response within 95s |
| `workspace_symbols` | FAIL | retry exhausted: no response within 95s |
| `get_diagnostics` | FAIL | lsp unresponsive (short-circuited) |
| `goto_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_type_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_implementation` | FAIL | lsp unresponsive (short-circuited) |
| `find_references` | FAIL | lsp unresponsive (short-circuited) |
| `signature_help` | FAIL | lsp unresponsive (short-circuited) |
| `format_document` | FAIL | lsp unresponsive (short-circuited) |
| `code_actions` | FAIL | lsp unresponsive (short-circuited) |
| `rename_preview` | FAIL | lsp unresponsive (short-circuited) |
| `inlay_hints` | FAIL | lsp unresponsive (short-circuited) |
| `semantic_tokens` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_incoming_calls` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_outgoing_calls` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_supertypes` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_subtypes` | FAIL | lsp unresponsive (short-circuited) |
| `lsp_request_raw` | FAIL | lsp unresponsive (short-circuited) |
| `apply_workspace_edit` | FAIL | lsp unresponsive (short-circuited) |

## typescript (20/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (308b) |
| `document_symbols` | OK | ok (9189b) |
| `workspace_symbols` | OK | ok (619b) |
| `get_diagnostics` | OK | ok (161b) |
| `goto_definition` | OK | ok (348b) |
| `goto_type_definition` | OK | ok (152b) |
| `goto_implementation` | OK | ok (153b) |
| `find_references` | OK | ok (1386b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | OK | ok (2068b) |
| `code_actions` | OK | ok (1208b) |
| `rename_preview` | OK | ok (340b) |
| `inlay_hints` | OK | ok (2b) |
| `semantic_tokens` | OK | ok (1317b) |
| `call_hierarchy_prepare` | OK | ok (281b) |
| `call_hierarchy_incoming_calls` | OK | ok (871b) |
| `call_hierarchy_outgoing_calls` | OK | ok (2622b) |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `lsp_request_raw` | OK | ok (308b) |
| `apply_workspace_edit` | OK | ok (149b) |

## yaml (0/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | FAIL | retry exhausted: no response within 95s |
| `document_symbols` | FAIL | retry exhausted: no response within 95s |
| `workspace_symbols` | FAIL | retry exhausted: no response within 95s |
| `get_diagnostics` | FAIL | lsp unresponsive (short-circuited) |
| `goto_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_type_definition` | FAIL | lsp unresponsive (short-circuited) |
| `goto_implementation` | FAIL | lsp unresponsive (short-circuited) |
| `find_references` | FAIL | lsp unresponsive (short-circuited) |
| `signature_help` | FAIL | lsp unresponsive (short-circuited) |
| `format_document` | FAIL | lsp unresponsive (short-circuited) |
| `code_actions` | FAIL | lsp unresponsive (short-circuited) |
| `rename_preview` | FAIL | lsp unresponsive (short-circuited) |
| `inlay_hints` | FAIL | lsp unresponsive (short-circuited) |
| `semantic_tokens` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_incoming_calls` | FAIL | lsp unresponsive (short-circuited) |
| `call_hierarchy_outgoing_calls` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_prepare` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_supertypes` | FAIL | lsp unresponsive (short-circuited) |
| `type_hierarchy_subtypes` | FAIL | lsp unresponsive (short-circuited) |
| `lsp_request_raw` | FAIL | lsp unresponsive (short-circuited) |
| `apply_workspace_edit` | FAIL | lsp unresponsive (short-circuited) |

## zig (18/22)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (182b) |
| `document_symbols` | OK | ok (89045b) |
| `workspace_symbols` | OK | ok (4b) |
| `get_diagnostics` | OK | ok (316b) |
| `goto_definition` | OK | ok (333b) |
| `goto_type_definition` | OK | ok (4b) |
| `goto_implementation` | OK | ok (333b) |
| `find_references` | OK | ok (52140b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | OK | ok (57b) |
| `code_actions` | OK | ok (5128b) |
| `rename_preview` | OK | ok (11370b) |
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
