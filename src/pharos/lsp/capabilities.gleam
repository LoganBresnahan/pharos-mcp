//// Static LSP method → ServerCapabilities-key map plus a typed
//// `supports/2` predicate. Used by tier-1 tools to short-circuit
//// optional methods (`textDocument/inlayHint`,
//// `textDocument/prepareTypeHierarchy`, etc.) that a given LSP
//// server did not advertise during initialize. Without this gate,
//// pharos burns a full request budget (often the harness's 285s
//// timeout per tool, multiplied by the auto-retry) on servers
//// that silently never respond rather than returning `-32601`.
////
//// Population: `pharos/lsp/proc.start_internal` writes the
//// `InitializeResult.capabilities` map into an ETS table keyed by
//// the lsp_proc actor's pid right after lifecycle.initialize
//// returns. Lookups happen from any process (the table is `public,
//// set, read_concurrency=true`).
////
//// Semantics: a method counts as "supported" if the capabilities
//// JSON has a truthy key at the configured path. We deliberately
//// allow `Bool true`, `Object { ... }`, and `Object { workDoneProgress
//// : ... }`-style declarations — they all mean "I implement this
//// method". `False` and missing key both mean unsupported.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid}
import gleam/option.{type Option}
import pharos/lsp/proc.{type Proc}

/// Decision result for `supports/2`.
pub type Support {
  /// Server advertised the capability — go ahead and dispatch.
  Supported
  /// Server explicitly did not advertise the capability — skip with
  /// a typed unsupported reply.
  Unsupported
  /// We have no capabilities record on file (server crashed before
  /// initialize completed, or proc was recovered from ETS bridge
  /// across a pool restart). Caller should fall back to dispatching
  /// the request optimistically — same behaviour as before the
  /// capability gate existed.
  Unknown
}

/// Look up the capability record for a Proc and decide whether
/// `lsp_method` is implemented. Convenience wrapper around
/// `lookup_by_pid/1` + `supports_method/2`.
pub fn check(lsp: Proc, lsp_method: String) -> Support {
  case lookup_by_pid(proc.pid(lsp)) {
    Error(_) -> Unknown
    Ok(capabilities) ->
      case supports_method(capabilities, lsp_method) {
        True -> Supported
        False -> Unsupported
      }
  }
}

/// Pid-keyed lookup of the cached `InitializeResult.capabilities`.
/// Returns `Error(Nil)` if the proc never registered (init failed,
/// table not seeded yet, etc.).
@external(erlang, "pharos_runtime_ffi", "lsp_capabilities_lookup")
pub fn lookup_by_pid(pid: Pid) -> Result(Dynamic, Nil)

/// Pid-keyed store. Called from `proc.start_internal` immediately
/// after `lifecycle.initialize/4` succeeds.
@external(erlang, "pharos_runtime_ffi", "lsp_capabilities_store")
pub fn store(pid: Pid, capabilities: Dynamic) -> Nil

/// Initialise the ETS-backed capabilities table. Called from
/// `pharos.do_boot/0` alongside the other pre-supervisor ETS
/// inits. Idempotent.
@external(erlang, "pharos_runtime_ffi", "lsp_capabilities_init")
pub fn init() -> Nil

/// Predicate against a raw `InitializeResult.capabilities` Dynamic.
/// Exposed for unit tests; production code goes through
/// `check/2`.
pub fn supports_method(
  capabilities: Dynamic,
  lsp_method: String,
) -> Bool {
  case capability_path(lsp_method) {
    option.None ->
      // Method not in the static map — be conservative and assume
      // supported. The static map is opt-in for methods where the
      // capability check is worth the per-call cost.
      True
    option.Some(path) -> walk_path(capabilities, path)
  }
}

/// Static map: LSP method string → dotted ServerCapabilities path.
/// Add entries here when a method's capability is worth gating on.
/// Paths use `/` as the delimiter and refer to JSON object keys
/// inside `capabilities`.
fn capability_path(lsp_method: String) -> Option(List(String)) {
  case lsp_method {
    "textDocument/inlayHint" -> option.Some(["inlayHintProvider"])
    "textDocument/semanticTokens/full" ->
      option.Some(["semanticTokensProvider"])
    "textDocument/semanticTokens/full/delta" ->
      option.Some(["semanticTokensProvider"])
    "textDocument/semanticTokens/range" ->
      option.Some(["semanticTokensProvider"])
    "textDocument/prepareTypeHierarchy" ->
      option.Some(["typeHierarchyProvider"])
    "typeHierarchy/supertypes" ->
      option.Some(["typeHierarchyProvider"])
    "typeHierarchy/subtypes" ->
      option.Some(["typeHierarchyProvider"])
    "textDocument/prepareCallHierarchy" ->
      option.Some(["callHierarchyProvider"])
    "callHierarchy/incomingCalls" ->
      option.Some(["callHierarchyProvider"])
    "callHierarchy/outgoingCalls" ->
      option.Some(["callHierarchyProvider"])
    "textDocument/codeAction" -> option.Some(["codeActionProvider"])
    "textDocument/rename" -> option.Some(["renameProvider"])
    "textDocument/prepareRename" -> option.Some(["renameProvider"])
    "textDocument/formatting" ->
      option.Some(["documentFormattingProvider"])
    "textDocument/rangeFormatting" ->
      option.Some(["documentRangeFormattingProvider"])
    "textDocument/onTypeFormatting" ->
      option.Some(["documentOnTypeFormattingProvider"])
    "textDocument/signatureHelp" ->
      option.Some(["signatureHelpProvider"])
    "textDocument/documentSymbol" ->
      option.Some(["documentSymbolProvider"])
    "workspace/symbol" -> option.Some(["workspaceSymbolProvider"])
    "textDocument/references" -> option.Some(["referencesProvider"])
    "textDocument/definition" -> option.Some(["definitionProvider"])
    "textDocument/typeDefinition" ->
      option.Some(["typeDefinitionProvider"])
    "textDocument/implementation" ->
      option.Some(["implementationProvider"])
    "textDocument/hover" -> option.Some(["hoverProvider"])
    _ -> option.None
  }
}

/// Walk a dotted path through the capabilities Dynamic. Returns
/// True if the resulting value is "advertised":
///   - Bool True
///   - any Object/Map
///   - any non-empty List (rare — for providers declared as arrays)
/// False on missing key or explicit False.
fn walk_path(value: Dynamic, path: List(String)) -> Bool {
  case path {
    [] -> truthy(value)
    [key, ..rest] ->
      case decode.run(value, decode.field(key, decode.dynamic, decode.success)) {
        Ok(nested) -> walk_path(nested, rest)
        Error(_) -> False
      }
  }
}

fn truthy(value: Dynamic) -> Bool {
  // Bool true → True. Object/Map → True. List with elements → True.
  // Everything else (Bool false, Nil, missing) → False.
  case decode.run(value, decode.bool) {
    Ok(b) -> b
    Error(_) ->
      // Not a bool. Try map / dict shape.
      case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
        Ok(_) -> True
        Error(_) ->
          // Try list shape — sometimes providers like
          // `tokenTypesProvider` come back as an array.
          case decode.run(value, decode.list(decode.dynamic)) {
            Ok([]) -> False
            Ok([_, ..]) -> True
            Error(_) -> False
          }
      }
  }
}
