# Dogfood pass — 23 languages × 43 tools + memory probe

**Label:** pass-27-pre-v0.1.0
**Binary:** `/home/oof/pharos-mcp/burrito_out/pharos_linux_x64`
**Transport:** `stdio`
**Profile:** `all`
**Result:** **565/656 cells PASS** (86%)

Per-language LSP-bound tools (27): hover, document_symbols, workspace_symbols, get_diagnostics, goto_definition, goto_type_definition, goto_implementation, find_references, signature_help, format_document, code_actions, rename_preview, inlay_hints, semantic_tokens, call_hierarchy_prepare, call_hierarchy_incoming_calls, call_hierarchy_outgoing_calls, type_hierarchy_prepare, type_hierarchy_supertypes, type_hierarchy_subtypes, find_symbol, get_symbols_overview, containing_symbol, find_referencing_symbols, edit_at_symbol, lsp_request_raw, apply_workspace_edit.

Global one-shot tools (17): echo, runtime_processes, runtime_supervision_tree, runtime_ets_tables, runtime_memory, runtime_applications, runtime_scheduler_util, runtime_log_tail, runtime_log_level, runtime_log_clear, runtime_trace_lsp, runtime_kill_lsp, runtime_trace_calls, runtime_language_config, runtime_set_tool_timeout, runtime_effective_tool_config, runtime_pid_info.

Result keys: `OK` = response without isError. `server gap` = isError carrying -32601 / Method not found / unsupported file type — plumbing fine, LSP doesn't implement it. `FAIL` = anything else. `OK (after retry …)` = first call timed out, harness fired `runtime_set_tool_timeout` to bump the budget, retry passed. `filter rejected (default profile)` rows mark tools the default profile is configured to deny — graceful filter, not a defect.

## (global) (18/18)

| Tool | Result | Note |
|------|--------|------|
| `echo` | OK | ok (14b) |
| `runtime_processes` | OK | ok (13425b) |
| `runtime_supervision_tree` | OK | ok (6167b) |
| `runtime_ets_tables` | OK | ok (3400b) |
| `runtime_memory` | OK | ok (165b) |
| `runtime_applications` | OK | ok (1683b) |
| `runtime_scheduler_util` | OK | ok (864b) |
| `runtime_log_tail` | OK | ok (44542b) |
| `runtime_log_level` | OK | ok (34b) |
| `runtime_log_clear` | OK | ok (16b) |
| `runtime_trace_lsp` | OK | ok (11578b) |
| `runtime_kill_lsp` | OK | ok (66b) |
| `runtime_trace_calls` | OK | config-gated (disabled in config) |
| `runtime_language_config` | OK | ok (755b) |
| `runtime_set_tool_timeout` | OK | ok (71b) |
| `runtime_effective_tool_config` | OK | ok (196b) |
| `runtime_pid_info` | OK | ok (630b) |
| `runtime_lsp_state` | OK | ok (10826b) |

## (memory) (17/17)

| Tool | Result | Note |
|------|--------|------|
| `memory_list (empty)` | OK | ok (24b) |
| `memory_save project` | OK | ok (199b) |
| `memory_get` | OK | ok (199b) |
| `memory_list (filtered)` | OK | ok (162b) |
| `memory_save dup (expect conflict)` | OK | isError=true: memory 'dogfood-pass-probe' exists; pass overwrite=true to replace |
| `memory_save overwrite` | OK | ok (182b) |
| `memory_save user-layer` | OK | ok (180b) |
| `memory_list (cross-layer)` | OK | ok (284b) |
| `memory_audit (clean)` | OK | ok (74b) |
| `memory_save dup-seed` | OK | ok (187b) |
| `memory_audit (dup detected)` | OK | ok (142b) |
| `memory_audit (no dup scan)` | OK | ok (74b) |
| `memory_audit (threshold=0)` | OK | ok (511b) |
| `memory_prune dup-seed` | OK | ok (31b) |
| `memory_prune project` | OK | ok (31b) |
| `memory_get after prune (expect not_found)` | OK | isError=true: memory not found: dogfood-pass-probe |
| `memory_prune user-layer` | OK | ok (29b) |

## bash (23/27)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (4b) |
| `document_symbols` | OK | ok (2179b) |
| `workspace_symbols` | OK | ok (48b) |
| `get_diagnostics` | OK | ok (167b) |
| `goto_definition` | OK | ok (2b) |
| `goto_type_definition` | GAP | server gap (-32601 / unsupported) |
| `goto_implementation` | GAP | server gap (-32601 / unsupported) |
| `find_references` | OK | ok (2b) |
| `signature_help` | GAP | server gap (-32601 / unsupported) |
| `format_document` | OK | ok (57b) |
| `code_actions` | OK | ok (2b) |
| `rename_preview` | OK | ok (43b) |
| `inlay_hints` | GAP | server gap (-32601 / unsupported) |
| `semantic_tokens` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_incoming_calls` | FAIL | prepare returned no item |
| `call_hierarchy_outgoing_calls` | FAIL | prepare returned no item |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `find_symbol` | OK | ok (1193b) |
| `get_symbols_overview` | OK | ok (415b) |
| `containing_symbol` | OK | ok (14b) |
| `find_referencing_symbols` | OK | ok (36b) |
| `edit_at_symbol` | OK | ok (358b) |
| `lsp_request_raw` | OK | ok (4b) |
| `apply_workspace_edit` | OK | ok (149b) |

## clojure (25/27)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (372b) |
| `document_symbols` | OK | ok (143040b) |
| `workspace_symbols` | OK | ok (1045b) |
| `get_diagnostics` | OK | ok (38881b) |
| `goto_definition` | OK | ok (160b) |
| `goto_type_definition` | GAP | server gap (-32601 / unsupported) |
| `goto_implementation` | OK | ok (2b) |
| `find_references` | OK | ok (162b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | OK | ok (292075b) |
| `code_actions` | OK | ok (2154b) |
| `rename_preview` | OK | ok (108b) |
| `inlay_hints` | GAP | server gap (-32601 / unsupported) |
| `semantic_tokens` | OK | ok (168010b) |
| `call_hierarchy_prepare` | OK | ok (309b) |
| `call_hierarchy_incoming_calls` | OK | ok (2b) |
| `call_hierarchy_outgoing_calls` | OK | ok (2b) |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `find_symbol` | OK | ok (628b) |
| `get_symbols_overview` | OK | ok (91391b) |
| `containing_symbol` | OK | ok (557b) |
| `find_referencing_symbols` | OK | ok (36b) |
| `edit_at_symbol` | OK | ok (378b) |
| `lsp_request_raw` | OK | ok (802b) |
| `apply_workspace_edit` | OK | ok (149b) |

## cpp (25/27)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (254b) |
| `document_symbols` | OK | ok (20216b) |
| `workspace_symbols` | OK | ok (5232b) |
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
| `find_symbol` | OK | ok (1318b) |
| `get_symbols_overview` | OK | ok (11884b) |
| `containing_symbol` | OK | ok (582b) |
| `find_referencing_symbols` | OK | ok (5691b) |
| `edit_at_symbol` | OK | ok (384b) |
| `lsp_request_raw` | OK | ok (254b) |
| `apply_workspace_edit` | OK | ok (149b) |

## css (23/27)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (226b) |
| `document_symbols` | OK | ok (648173b) |
| `workspace_symbols` | GAP | server gap (-32601 / unsupported) |
| `get_diagnostics` | OK | ok (220b) |
| `goto_definition` | OK | ok (151b) |
| `goto_type_definition` | GAP | server gap (-32601 / unsupported) |
| `goto_implementation` | GAP | server gap (-32601 / unsupported) |
| `find_references` | OK | ok (625b) |
| `signature_help` | GAP | server gap (-32601 / unsupported) |
| `format_document` | OK | ok (330009b) |
| `code_actions` | OK | ok (2b) |
| `rename_preview` | OK | ok (190b) |
| `inlay_hints` | GAP | server gap (-32601 / unsupported) |
| `semantic_tokens` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_incoming_calls` | FAIL | prepare returned no item |
| `call_hierarchy_outgoing_calls` | FAIL | prepare returned no item |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `find_symbol` | OK | ok (3019b) |
| `get_symbols_overview` | OK | ok (455616b) |
| `containing_symbol` | OK | ok (529b) |
| `find_referencing_symbols` | OK | ok (2410b) |
| `edit_at_symbol` | OK | ok (372b) |
| `lsp_request_raw` | OK | ok (226b) |
| `apply_workspace_edit` | OK | ok (149b) |

## elixir (16/27)

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
| `find_symbol` | FAIL | isError=true: request failed: server error -32603: Timeout |
| `get_symbols_overview` | OK | ok (1932b) |
| `containing_symbol` | OK | ok (525b) |
| `find_referencing_symbols` | FAIL | find_symbol returned no handle |
| `edit_at_symbol` | FAIL | find_symbol returned no handle |
| `lsp_request_raw` | OK | ok (4b) |
| `apply_workspace_edit` | OK | ok (149b) |

## erlang (25/27)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (163b) |
| `document_symbols` | OK | ok (8166b) |
| `workspace_symbols` | OK | ok (48b) |
| `get_diagnostics` | OK | ok (6258b) |
| `goto_definition` | OK | ok (356b) |
| `goto_type_definition` | OK | ok (4b) |
| `goto_implementation` | GAP | server gap (-32601 / unsupported) |
| `find_references` | OK | ok (161b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | GAP | server gap (-32601 / unsupported) |
| `code_actions` | OK | ok (2b) |
| `rename_preview` | OK | ok (163b) |
| `inlay_hints` | OK | ok (322b) |
| `semantic_tokens` | OK | ok (183b) |
| `call_hierarchy_prepare` | OK | ok (273b) |
| `call_hierarchy_incoming_calls` | OK | ok (2b) |
| `call_hierarchy_outgoing_calls` | OK | ok (748b) |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `find_symbol` | OK | ok (1248b) |
| `get_symbols_overview` | OK | ok (5130b) |
| `containing_symbol` | OK | ok (553b) |
| `find_referencing_symbols` | OK | ok (36b) |
| `edit_at_symbol` | OK | ok (378b) |
| `lsp_request_raw` | OK | ok (163b) |
| `apply_workspace_edit` | OK | ok (149b) |

## gleam (20/27)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (530b) |
| `document_symbols` | OK | ok (30215b) |
| `workspace_symbols` | FAIL | no response within 945s |
| `get_diagnostics` | FAIL | no response within 945s |
| `goto_definition` | OK | ok (154b) |
| `goto_type_definition` | OK | ok (2b) |
| `goto_implementation` | FAIL | no response within 945s |
| `find_references` | OK | ok (1942b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | OK | ok (60941b) |
| `code_actions` | OK | ok (2b) |
| `rename_preview` | OK | ok (677b) |
| `inlay_hints` | GAP | server gap (-32601 / unsupported) |
| `semantic_tokens` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_incoming_calls` | FAIL | prepare returned no item |
| `call_hierarchy_outgoing_calls` | FAIL | prepare returned no item |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `find_symbol` | OK | ok (628b) |
| `get_symbols_overview` | OK | ok (21638b) |
| `containing_symbol` | OK | ok (557b) |
| `find_referencing_symbols` | OK | ok (7961b) |
| `edit_at_symbol` | OK | ok (362b) |
| `lsp_request_raw` | OK | ok (530b) |
| `apply_workspace_edit` | OK | ok (149b) |

## go (24/27)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (1582b) |
| `document_symbols` | OK | ok (39320b) |
| `workspace_symbols` | OK | ok (5543b) |
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
| `find_symbol` | OK | ok (634b) |
| `get_symbols_overview` | OK | ok (25567b) |
| `containing_symbol` | OK | ok (14b) |
| `find_referencing_symbols` | OK | ok (1350b) |
| `edit_at_symbol` | OK | ok (364b) |
| `lsp_request_raw` | OK | ok (1582b) |
| `apply_workspace_edit` | OK | ok (149b) |

## haskell (25/27)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (253b) |
| `document_symbols` | OK | ok (18766b) |
| `workspace_symbols` | OK | ok (3860b) |
| `get_diagnostics` | OK | ok (234b) |
| `goto_definition` | OK | ok (172b) |
| `goto_type_definition` | OK | ok (2b) |
| `goto_implementation` | OK | ok (2b) |
| `find_references` | OK | ok (1369b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | OK | ok (13435b) |
| `code_actions` | OK | ok (2b) |
| `rename_preview` | OK | ok (217b) |
| `inlay_hints` | OK | ok (11959b) |
| `semantic_tokens` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_prepare` | OK | ok (388b) |
| `call_hierarchy_incoming_calls` | OK | ok (2b) |
| `call_hierarchy_outgoing_calls` | OK | ok (983b) |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `find_symbol` | OK | ok (1344b) |
| `get_symbols_overview` | OK | ok (13632b) |
| `containing_symbol` | OK | ok (609b) |
| `find_referencing_symbols` | OK | ok (2004b) |
| `edit_at_symbol` | OK | ok (390b) |
| `lsp_request_raw` | OK | ok (440b) |
| `apply_workspace_edit` | OK | ok (149b) |

## html (23/27)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (4b) |
| `document_symbols` | OK | ok (684b) |
| `workspace_symbols` | GAP | server gap (-32601 / unsupported) |
| `get_diagnostics` | OK | ok (241b) |
| `goto_definition` | OK | ok (2b) |
| `goto_type_definition` | GAP | server gap (-32601 / unsupported) |
| `goto_implementation` | GAP | server gap (-32601 / unsupported) |
| `find_references` | OK | ok (2b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | OK | ok (199b) |
| `code_actions` | OK | ok (2b) |
| `rename_preview` | OK | ok (43b) |
| `inlay_hints` | GAP | server gap (-32601 / unsupported) |
| `semantic_tokens` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_incoming_calls` | FAIL | prepare returned no item |
| `call_hierarchy_outgoing_calls` | FAIL | prepare returned no item |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `find_symbol` | OK | ok (633b) |
| `get_symbols_overview` | OK | ok (391b) |
| `containing_symbol` | OK | ok (562b) |
| `find_referencing_symbols` | OK | ok (36b) |
| `edit_at_symbol` | OK | ok (416b) |
| `lsp_request_raw` | OK | ok (4b) |
| `apply_workspace_edit` | OK | ok (149b) |

## java (25/27)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (369b) |
| `document_symbols` | OK | ok (5367b) |
| `workspace_symbols` | OK | ok (956b) |
| `get_diagnostics` | OK | ok (206b) |
| `goto_definition` | OK | ok (199b) |
| `goto_type_definition` | OK | ok (199b) |
| `goto_implementation` | OK | ok (1307b) |
| `find_references` | OK | ok (16160b) |
| `signature_help` | OK | ok (17b) |
| `format_document` | OK | ok (1990b) |
| `code_actions` | OK | ok (517b) |
| `rename_preview` | OK | ok (43b) |
| `inlay_hints` | OK | ok (2b) |
| `semantic_tokens` | OK | ok (2323b) |
| `call_hierarchy_prepare` | OK | ok (4b) |
| `call_hierarchy_incoming_calls` | FAIL | prepare returned no item |
| `call_hierarchy_outgoing_calls` | FAIL | prepare returned no item |
| `type_hierarchy_prepare` | OK | ok (534b) |
| `type_hierarchy_supertypes` | OK | ok (724b) |
| `type_hierarchy_subtypes` | OK | ok (1098b) |
| `find_symbol` | OK | ok (713b) |
| `get_symbols_overview` | OK | ok (3707b) |
| `containing_symbol` | OK | ok (642b) |
| `find_referencing_symbols` | OK | ok (51576b) |
| `edit_at_symbol` | OK | ok (450b) |
| `lsp_request_raw` | OK | ok (369b) |
| `apply_workspace_edit` | OK | ok (149b) |

## json (23/27)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (4b) |
| `document_symbols` | OK | ok (8580b) |
| `workspace_symbols` | GAP | server gap (-32601 / unsupported) |
| `get_diagnostics` | OK | ok (211b) |
| `goto_definition` | GAP | server gap (-32601 / unsupported) |
| `goto_type_definition` | GAP | server gap (-32601 / unsupported) |
| `goto_implementation` | GAP | server gap (-32601 / unsupported) |
| `find_references` | GAP | server gap (-32601 / unsupported) |
| `signature_help` | GAP | server gap (-32601 / unsupported) |
| `format_document` | OK | ok (1404b) |
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
| `find_symbol` | OK | ok (1188b) |
| `get_symbols_overview` | OK | ok (688b) |
| `containing_symbol` | OK | ok (14b) |
| `find_referencing_symbols` | GAP | server gap (-32601 / unsupported) |
| `edit_at_symbol` | OK | ok (294b) |
| `lsp_request_raw` | OK | ok (4b) |
| `apply_workspace_edit` | OK | ok (149b) |

## lua (23/27)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (67b) |
| `document_symbols` | OK | ok (201384b) |
| `workspace_symbols` | OK | ok (4503b) |
| `get_diagnostics` | OK | ok (7531b) |
| `goto_definition` | OK | ok (349b) |
| `goto_type_definition` | OK | ok (4b) |
| `goto_implementation` | OK | ok (349b) |
| `find_references` | OK | ok (4196b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | OK | ok (65956b) |
| `code_actions` | OK | ok (2b) |
| `rename_preview` | OK | ok (956b) |
| `inlay_hints` | OK | ok (4b) |
| `semantic_tokens` | OK | ok (34479b) |
| `call_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_incoming_calls` | FAIL | prepare returned no item |
| `call_hierarchy_outgoing_calls` | FAIL | prepare returned no item |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `find_symbol` | OK | ok (28986b) |
| `get_symbols_overview` | OK | ok (49925b) |
| `containing_symbol` | OK | ok (548b) |
| `find_referencing_symbols` | OK | ok (36b) |
| `edit_at_symbol` | OK | ok (430b) |
| `lsp_request_raw` | OK | ok (479b) |
| `apply_workspace_edit` | OK | ok (149b) |

## markdown (23/27)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (4b) |
| `document_symbols` | OK | ok (1061b) |
| `workspace_symbols` | OK | ok (6013b) |
| `get_diagnostics` | OK | ok (212b) |
| `goto_definition` | OK | ok (4b) |
| `goto_type_definition` | GAP | server gap (-32601 / unsupported) |
| `goto_implementation` | GAP | server gap (-32601 / unsupported) |
| `find_references` | OK | ok (308b) |
| `signature_help` | GAP | server gap (-32601 / unsupported) |
| `format_document` | GAP | server gap (-32601 / unsupported) |
| `code_actions` | OK | ok (596b) |
| `rename_preview` | OK | ok (43b) |
| `inlay_hints` | GAP | server gap (-32601 / unsupported) |
| `semantic_tokens` | OK | ok (11b) |
| `call_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_incoming_calls` | FAIL | prepare returned no item |
| `call_hierarchy_outgoing_calls` | FAIL | prepare returned no item |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `find_symbol` | OK | ok (630b) |
| `get_symbols_overview` | OK | ok (12b) |
| `containing_symbol` | OK | ok (597b) |
| `find_referencing_symbols` | OK | ok (36b) |
| `edit_at_symbol` | OK | ok (386b) |
| `lsp_request_raw` | OK | ok (4b) |
| `apply_workspace_edit` | OK | ok (149b) |

## perl (23/27)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (4b) |
| `document_symbols` | OK | ok (7186b) |
| `workspace_symbols` | OK | ok (48b) |
| `get_diagnostics` | OK | ok (161b) |
| `goto_definition` | OK | ok (156b) |
| `goto_type_definition` | GAP | server gap (-32601 / unsupported) |
| `goto_implementation` | GAP | server gap (-32601 / unsupported) |
| `find_references` | GAP | server gap (-32601 / unsupported) |
| `signature_help` | OK | ok (4b) |
| `format_document` | OK | ok (32132b) |
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
| `find_symbol` | OK | ok (13948b) |
| `get_symbols_overview` | OK | ok (5106b) |
| `containing_symbol` | OK | ok (534b) |
| `find_referencing_symbols` | GAP | server gap (-32601 / unsupported) |
| `edit_at_symbol` | OK | ok (366b) |
| `lsp_request_raw` | OK | ok (493b) |
| `apply_workspace_edit` | OK | ok (149b) |

## python (25/27)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (219b) |
| `document_symbols` | OK | ok (42034b) |
| `workspace_symbols` | OK | ok (454b) |
| `get_diagnostics` | OK | ok (8235b) |
| `goto_definition` | OK | ok (153b) |
| `goto_type_definition` | OK | ok (153b) |
| `goto_implementation` | GAP | server gap (-32601 / unsupported) |
| `find_references` | OK | ok (153b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | OK | ok (57b) |
| `code_actions` | OK | ok (209b) |
| `rename_preview` | OK | ok (99b) |
| `inlay_hints` | GAP | server gap (-32601 / unsupported) |
| `semantic_tokens` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_prepare` | OK | ok (274b) |
| `call_hierarchy_incoming_calls` | OK | ok (4b) |
| `call_hierarchy_outgoing_calls` | OK | ok (825b) |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `find_symbol` | OK | ok (1271b) |
| `get_symbols_overview` | OK | ok (6079b) |
| `containing_symbol` | OK | ok (563b) |
| `find_referencing_symbols` | OK | ok (36b) |
| `edit_at_symbol` | OK | ok (358b) |
| `lsp_request_raw` | OK | ok (219b) |
| `apply_workspace_edit` | OK | ok (149b) |

## ruby (21/27)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (4b) |
| `document_symbols` | OK | ok (65550b) |
| `workspace_symbols` | OK | ok (467b) |
| `get_diagnostics` | OK | ok (218b) |
| `goto_definition` | OK | ok (2b) |
| `goto_type_definition` | FAIL | no response within 165s |
| `goto_implementation` | FAIL | no response within 165s |
| `find_references` | OK | ok (55932b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | OK | ok (72665b) |
| `code_actions` | OK | ok (691b) |
| `rename_preview` | OK | ok (43b) |
| `inlay_hints` | OK | ok (2b) |
| `semantic_tokens` | OK | ok (15590b) |
| `call_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_incoming_calls` | FAIL | prepare returned no item |
| `call_hierarchy_outgoing_calls` | FAIL | prepare returned no item |
| `type_hierarchy_prepare` | OK | ok (4b) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `find_symbol` | OK | ok (613b) |
| `get_symbols_overview` | OK | ok (42799b) |
| `containing_symbol` | OK | ok (538b) |
| `find_referencing_symbols` | OK | ok (35878b) |
| `edit_at_symbol` | OK | ok (364b) |
| `lsp_request_raw` | OK | ok (4b) |
| `apply_workspace_edit` | OK | ok (149b) |

## rust (25/27)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (222b) |
| `document_symbols` | OK | ok (3287b) |
| `workspace_symbols` | OK | ok (247b) |
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
| `find_symbol` | OK | ok (673b) |
| `get_symbols_overview` | OK | ok (2081b) |
| `containing_symbol` | OK | ok (602b) |
| `find_referencing_symbols` | OK | ok (3043b) |
| `edit_at_symbol` | OK | ok (356b) |
| `lsp_request_raw` | OK | ok (222b) |
| `apply_workspace_edit` | OK | ok (149b) |

## scala (20/27)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (77b) |
| `document_symbols` | OK | ok (16453b) |
| `workspace_symbols` | FAIL | no response within 645s |
| `get_diagnostics` | FAIL | no response within 645s |
| `goto_definition` | OK | ok (163b) |
| `goto_type_definition` | OK | ok (167b) |
| `goto_implementation` | OK | ok (2b) |
| `find_references` | OK | ok (329b) |
| `signature_help` | OK | ok (57b) |
| `format_document` | OK | ok (57b) |
| `code_actions` | OK | ok (2b) |
| `rename_preview` | OK | ok (43b) |
| `inlay_hints` | FAIL | no response within 645s |
| `semantic_tokens` | FAIL | no response within 645s |
| `call_hierarchy_prepare` | OK | ok (434b) |
| `call_hierarchy_incoming_calls` | OK | ok (534b) |
| `call_hierarchy_outgoing_calls` | OK | ok (1237b) |
| `type_hierarchy_prepare` | OK | ok (330b) |
| `type_hierarchy_supertypes` | OK | ok (2b) |
| `type_hierarchy_subtypes` | OK | ok (2b) |
| `find_symbol` | FAIL | isError=true: request failed: tool timeout: LSP did not respond in time. The LSP may still be indexing — pass a larger `timeout_ms` on this tool call, or call `runtime_set_to |
| `get_symbols_overview` | OK | ok (11132b) |
| `containing_symbol` | OK | ok (563b) |
| `find_referencing_symbols` | FAIL | find_symbol returned no handle |
| `edit_at_symbol` | FAIL | find_symbol returned no handle |
| `lsp_request_raw` | OK | ok (77b) |
| `apply_workspace_edit` | OK | ok (149b) |

## terraform (22/27)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (271b) |
| `document_symbols` | OK | ok (154944b) |
| `workspace_symbols` | OK | ok (4359b) |
| `get_diagnostics` | OK | ok (211b) |
| `goto_definition` | FAIL | isError=true: server error -32098: no reference origin found |
| `goto_type_definition` | GAP | server gap (-32601 / unsupported) |
| `goto_implementation` | GAP | server gap (-32601 / unsupported) |
| `find_references` | OK | ok (2b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | OK | ok (57b) |
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
| `find_symbol` | OK | ok (12918b) |
| `get_symbols_overview` | OK | ok (43153b) |
| `containing_symbol` | OK | ok (514b) |
| `find_referencing_symbols` | OK | ok (36b) |
| `edit_at_symbol` | OK | ok (342b) |
| `lsp_request_raw` | OK | ok (271b) |
| `apply_workspace_edit` | OK | ok (149b) |

## typescript (25/27)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (308b) |
| `document_symbols` | OK | ok (9189b) |
| `workspace_symbols` | OK | ok (665b) |
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
| `find_symbol` | OK | ok (619b) |
| `get_symbols_overview` | OK | ok (5756b) |
| `containing_symbol` | OK | ok (548b) |
| `find_referencing_symbols` | OK | ok (4951b) |
| `edit_at_symbol` | OK | ok (356b) |
| `lsp_request_raw` | OK | ok (308b) |
| `apply_workspace_edit` | OK | ok (149b) |

## yaml (23/27)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (4b) |
| `document_symbols` | OK | ok (7843b) |
| `workspace_symbols` | GAP | server gap (-32601 / unsupported) |
| `get_diagnostics` | OK | ok (165b) |
| `goto_definition` | OK | ok (4b) |
| `goto_type_definition` | GAP | server gap (-32601 / unsupported) |
| `goto_implementation` | GAP | server gap (-32601 / unsupported) |
| `find_references` | GAP | server gap (-32601 / unsupported) |
| `signature_help` | GAP | server gap (-32601 / unsupported) |
| `format_document` | OK | ok (907b) |
| `code_actions` | OK | ok (2b) |
| `rename_preview` | OK | ok (43b) |
| `inlay_hints` | GAP | server gap (-32601 / unsupported) |
| `semantic_tokens` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_incoming_calls` | FAIL | prepare returned no item |
| `call_hierarchy_outgoing_calls` | FAIL | prepare returned no item |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `find_symbol` | OK | ok (614b) |
| `get_symbols_overview` | OK | ok (12b) |
| `containing_symbol` | OK | ok (14b) |
| `find_referencing_symbols` | GAP | server gap (-32601 / unsupported) |
| `edit_at_symbol` | OK | ok (362b) |
| `lsp_request_raw` | OK | ok (4b) |
| `apply_workspace_edit` | OK | ok (149b) |

## zig (23/27)

| Tool | Result | Note |
|------|--------|------|
| `hover` | OK | ok (183b) |
| `document_symbols` | OK | ok (89045b) |
| `workspace_symbols` | OK | ok (50b) |
| `get_diagnostics` | OK | ok (316b) |
| `goto_definition` | OK | ok (334b) |
| `goto_type_definition` | OK | ok (334b) |
| `goto_implementation` | OK | ok (334b) |
| `find_references` | OK | ok (52140b) |
| `signature_help` | OK | ok (4b) |
| `format_document` | OK | ok (57b) |
| `code_actions` | OK | ok (5128b) |
| `rename_preview` | OK | ok (11370b) |
| `inlay_hints` | OK | ok (2497b) |
| `semantic_tokens` | OK | ok (292567b) |
| `call_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `call_hierarchy_incoming_calls` | FAIL | prepare returned no item |
| `call_hierarchy_outgoing_calls` | FAIL | prepare returned no item |
| `type_hierarchy_prepare` | GAP | server gap (-32601 / unsupported) |
| `type_hierarchy_supertypes` | FAIL | prepare returned no item |
| `type_hierarchy_subtypes` | FAIL | prepare returned no item |
| `find_symbol` | OK | ok (578b) |
| `get_symbols_overview` | OK | ok (58693b) |
| `containing_symbol` | OK | ok (507b) |
| `find_referencing_symbols` | OK | ok (249074b) |
| `edit_at_symbol` | OK | ok (342b) |
| `lsp_request_raw` | OK | ok (183b) |
| `apply_workspace_edit` | OK | ok (149b) |
