//// MCP tool set: symbol-layer operations above the raw LSP
//// primitives (ADR-026).
////
//// Surface (4 tools):
////
////   find_symbol(name_path, scope_uri, policy)
////   get_symbols_overview(file_uri)
////   find_referencing_symbols(symbol_handle)
////   edit_at_symbol(symbol_handle, mode, content)
////
//// All four compose existing LSP primitives — `workspace/symbol`,
//// `textDocument/documentSymbol`, `textDocument/references`,
//// `textDocument/prepareRename`, and the `apply_workspace_edit`
//// preview pipeline. No persistent state; every call re-queries the
//// LSP so the LSP server's index stays the source of truth.
////
//// Non-determinism model (ADR-026 decision 3-4): `find_symbol`
//// returns the `Resolution` set, not a collapsed value. The LLM
//// receives every candidate that matches the `name_path`, with
//// container / kind / location metadata for disambiguation. Edit
//// operations take a `SymbolHandle` returned by a prior
//// `find_symbol`, never a `name_path` directly — the two-call
//// protocol forces the LLM to acknowledge which match it wants.

import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import pharos/lsp/capabilities
import pharos/lsp/proc
import pharos/lsp/pool.{type Pool}
import pharos/tools/session
import pharos/tools/tool_helpers

pub const default_timeout_ms: Int = 30_000

/// Cap on Multiple result size when tier-2 fuzzy fires. Tight enough
/// to keep response payloads bounded (substring matches against a
/// 5000-symbol tree could otherwise return hundreds); loose enough
/// that an LLM can still browse the candidates. Beyond this, callers
/// should narrow the `name_path` with a container segment.
pub const fuzzy_match_cap: Int = 20

// -- Types ---------------------------------------------------------------

/// `name_path` — a slash-delimited path through the symbol tree.
/// Examples: `"User"`, `"User/authenticate"`, `"module/Class/method"`.
/// Opaque so the constructor can validate. Empty paths and
/// whitespace-only segments are rejected.
pub opaque type NamePath {
  NamePath(parts: List(String))
}

/// Parse a slash-delimited string into a `NamePath`. Leading and
/// trailing slashes are tolerated and stripped. Empty input or any
/// whitespace-only segment is rejected.
pub fn parse_name_path(raw: String) -> Result(NamePath, SymbolsError) {
  let trimmed = string.trim(raw)
  case trimmed {
    "" -> Error(InvalidNamePath("empty name_path"))
    _ -> {
      let parts =
        trimmed
        |> string.split("/")
        |> list.map(string.trim)
        |> list.filter(fn(p) { p != "" })
      case parts {
        [] -> Error(InvalidNamePath("name_path resolves to no segments"))
        _ -> Ok(NamePath(parts: parts))
      }
    }
  }
}

/// Inspect the parsed segments. Used by `find_symbol` and exposed for
/// tests; the constructor stays opaque so call sites cannot bypass
/// validation.
pub fn name_path_parts(np: NamePath) -> List(String) {
  let NamePath(parts) = np
  parts
}

/// Render the `name_path` back as the canonical slash-form. Useful
/// for surfacing in error messages and tool responses.
pub fn name_path_to_string(np: NamePath) -> String {
  let NamePath(parts) = np
  parts |> list.intersperse("/") |> string.concat
}

pub type Position {
  Position(line: Int, character: Int)
}

pub type Range {
  Range(start: Position, end: Position)
}

/// Sanitized projection of LSP's `DocumentSymbol` plus enough
/// container context that the LLM can disambiguate.
pub type SymbolMatch {
  SymbolMatch(
    /// Identifier name (`"authenticate"`).
    name: String,
    /// LSP `SymbolKind` enum value (5=Class, 6=Method, 12=Function,
    /// 13=Variable, …). LLM-facing render maps to human names.
    kind: Int,
    /// File the symbol lives in.
    uri: String,
    /// Whole-symbol range — signature + body for callables, full
    /// definition for types.
    range: Range,
    /// Range covering just the identifier. Used as the seed for
    /// `prepareRename` and as the body-range boundary.
    selection_range: Range,
    /// Slash-joined containers up to the match. `["User",
    /// "authenticate"]` for a method on a class.
    full_path: List(String),
    /// Optional human-readable detail from the LSP — signature
    /// string, return type, etc. Server-supplied; may be empty.
    detail: Option(String),
    /// Which name_matches/2 strategy admitted this candidate.
    /// `"exact"` is the high-confidence baseline; anything else is a
    /// heuristic that widened the net to surface a Multiple instead
    /// of dead-ending in NotFound. LLM uses this to weight its
    /// disambiguation picks.
    matched_via: String,
    /// SHA-256 of the symbol's line-range body text, hex-encoded.
    /// Empty when the file couldn't be read at handle-mint time;
    /// edit_at_symbol skips the drift check in that case rather
    /// than refusing the call.
    body_hash: String,
  )
}

/// Compact reference to a previously-found symbol. Passed back to
/// edit / reference operations so the LLM never re-encodes the
/// match — and so a stale handle is detectable.
///
/// Carries enough to verify the symbol still exists at the recorded
/// position: a fresh `documentSymbol` call against `uri` should turn
/// up a `(name, selection_range.start.line)` match. If not, the
/// handle is reported as stale and the LLM re-runs `find_symbol`.
pub type SymbolHandle {
  SymbolHandle(
    uri: String,
    name: String,
    selection_line: Int,
    selection_character: Int,
    kind: Int,
    /// SHA-256 (lowercase hex) of the symbol's body text at the time
    /// the handle was minted. `edit_at_symbol` re-computes the hash
    /// from the freshly-fetched documentSymbol range and rejects with
    /// `HandleStale` if it doesn't match. Catches the case where an
    /// external edit between `find_symbol` and `edit_at_symbol` left
    /// the symbol's identity intact (same name + line) but changed
    /// its body content — the LLM may have reasoned its replacement
    /// against the old body and applying it would silently corrupt
    /// the new one.
    body_hash: String,
  )
}

/// How to collapse the candidate set returned by `find_symbol`.
/// `AllMatches` is the default — return the set, let the caller
/// (typically an LLM) pick. The collapsing variants are for callers
/// that have committed to a heuristic.
pub type Disambiguation {
  AllMatches
  FirstMatch
  ClosestScope
  StrictSingle
}

/// Non-deterministic resolution result. See ADR-026 decision 3.
pub type Resolution {
  Single(SymbolMatch)
  Multiple(List(SymbolMatch))
  NotFound(near_misses: List(String))
}

/// LLM-friendly outline of a single file. LSP's
/// `DocumentSymbol[]` is reshaped to drop noise kinds and surface
/// only the line number — the LLM needs scope structure, not a
/// pixel-perfect outline.
pub type SymbolTree {
  SymbolTree(roots: List(SymbolTreeNode))
}

pub type SymbolTreeNode {
  SymbolTreeNode(
    name: String,
    kind: Int,
    /// `selection_range.start.line` — line of the identifier.
    line: Int,
    /// `selection_range.start.character` — column of the identifier.
    /// Lets an LLM pipe an outline entry straight into a positional
    /// call (`find_references` / `goto_definition`) without a second
    /// `find_symbol` round-trip to resolve the cursor.
    character: Int,
    /// `range.end.line` — last line of the symbol's full body.
    /// Together with `line` it lets the agent slice the file
    /// (`Read(uri, offset=line, limit=end_line-line+1)`) instead of
    /// loading the whole document just to inspect one function.
    end_line: Int,
    /// `range.end.character` — column where the body closes. Same
    /// slice-extraction use case as `end_line`, kept for symmetry
    /// with positional LSP requests that need a full Range.
    end_character: Int,
    detail: Option(String),
    children: List(SymbolTreeNode),
  )
}

/// Which boundary of a symbol an `edit_at_symbol` call targets.
pub type EditMode {
  ReplaceBody
  InsertBefore
  InsertAfter
}

pub fn edit_mode_from_string(s: String) -> Result(EditMode, SymbolsError) {
  case s {
    "replace_body" | "ReplaceBody" -> Ok(ReplaceBody)
    "insert_before" | "InsertBefore" -> Ok(InsertBefore)
    "insert_after" | "InsertAfter" -> Ok(InsertAfter)
    _ ->
      Error(InvalidEditMode(
        "mode must be: replace_body | insert_before | insert_after",
      ))
  }
}

/// Edit operations never write by default. They return the proposed
/// `WorkspaceEdit` shape plus a rendered before/after summary; the
/// LLM reviews and calls `apply_workspace_edit` separately.
pub type EditPreview {
  EditPreview(
    uri: String,
    range: Range,
    new_text: String,
    rendered: String,
  )
}

pub type SymbolsError {
  InvalidNamePath(reason: String)
  InvalidEditMode(reason: String)
  SessionFailed(reason: String)
  RequestFailed(reason: String)
  DecodeFailed(reason: String)
  HandleStale(reason: String)
  BodyRangeUnknown(reason: String)
}

// -- find_symbol ---------------------------------------------------------

/// Locate symbols by `name_path` within `scope_uri` (any file inside
/// the target workspace works). Returns the set of matches; the
/// caller applies the desired `Disambiguation` policy.
pub fn find_symbol(
  pool: Pool,
  scope_uri: String,
  name_path: NamePath,
  policy: Disambiguation,
) -> Result(Resolution, SymbolsError) {
  let NamePath(parts) = name_path
  case parts {
    [] -> Error(InvalidNamePath("empty path post-construction"))
    [head, ..rest] -> {
      // ADR-026 fallback: when the server's InitializeResult does
      // not advertise `workspaceSymbolProvider` (e.g. gleam_lsp),
      // skip the cross-file workspace query and drill `scope_uri`
      // directly. Honours the LSP's capability surface instead of
      // burning the per-call budget on a method that will never
      // respond — and still gives the LLM a usable handle for the
      // common "edit a symbol I know lives in this file" workflow.
      use ws_supported <- result.try(workspace_symbol_supported(
        pool,
        scope_uri,
      ))
      use unique_uris <- result.try(case ws_supported {
        False -> Ok([scope_uri])
        True -> {
          use ws_results <- result.try(workspace_symbol_query(
            pool,
            scope_uri,
            head,
            default_timeout_ms,
          ))
          // Each workspace_symbol result is a `(name, kind,
          // location.uri)` pointer to a file containing a top-level
          // match for `head`. Bias toward `scope_uri` first so a
          // single-file caller hits its target without paying for
          // unrelated repo-wide candidates.
          //
          // Empty result list: some servers advertise
          // `workspaceSymbolProvider` but never return matches
          // (jdtls on freshly-opened workspaces; ELP doesn't
          // workspace-index `.erl` file functions globally; some
          // language servers return [] until a save event occurs).
          // Fall back to single-file drill the same way as the
          // unsupported-capability branch — gives the LLM a usable
          // resolution against `scope_uri` rather than a misleading
          // not_found.
          let uris =
            ws_results
            |> list.map(fn(s) { s.uri })
            |> list.unique
          case uris {
            [] -> Ok([scope_uri])
            _ -> Ok(uris)
          }
        }
      })
      // workspace_symbol can return URIs that the same LSP cannot
      // open (eg cpp's clangd surfacing `/usr/include/...` matches —
      // outside the fixture's workspace root). Swallow SessionFailed
      // per URI rather than failing the whole resolution; other
      // candidates still get drilled. Decode / request errors still
      // propagate so we don't mask LSP bugs.
      //
      // Two-tier match: drill first with the strict strategy. If
      // every URI yields zero candidates, retry once with the
      // fuzzy-fallback strategy. Resolution.Multiple absorbs the
      // wider net safely (LLM disambiguates via `matched_via`);
      // results are capped at `fuzzy_match_cap` to keep payloads
      // bounded.
      use trees <- result.try(
        list.try_map(unique_uris, fn(uri) {
          case document_symbol_query(pool, uri, default_timeout_ms) {
            Ok(tree) -> Ok(Some(#(uri, tree)))
            Error(SessionFailed(_)) -> Ok(None)
            Error(other) -> Error(other)
          }
        })
        |> result.map(list.filter_map(_, fn(o) {
          case o {
            Some(pair) -> Ok(pair)
            None -> Error(Nil)
          }
        })),
      )
      let strict =
        list.flat_map(trees, fn(pair) {
          let #(uri, tree) = pair
          drill(tree, [head, ..rest], [], uri, name_match_strategy)
        })
      let matches = case strict {
        [] -> {
          let fuzzy =
            list.flat_map(trees, fn(pair) {
              let #(uri, tree) = pair
              drill(
                tree,
                [head, ..rest],
                [],
                uri,
                name_match_strategy_with_fuzzy,
              )
            })
          list.take(fuzzy, fuzzy_match_cap)
        }
        _ -> strict
      }
      // Decorate with body_hash so the handle returned to the LLM
      // carries a drift-detection seed for the eventual edit_at_symbol
      // call. Batched per-uri so multiple matches in one file share a
      // single read.
      let hashed = enrich_with_body_hashes(matches)
      Ok(apply_policy(hashed, policy))
    }
  }
}

/// True iff the LSP backing `scope_uri` advertises
/// `workspaceSymbolProvider` in its InitializeResult. `Unknown`
/// (no capabilities record on file) falls through to True so we
/// preserve the pre-gate optimistic-dispatch behaviour. Used by
/// `find_symbol` to decide between cross-file and single-file
/// drill paths.
fn workspace_symbol_supported(
  pool: Pool,
  scope_uri: String,
) -> Result(Bool, SymbolsError) {
  case
    session.with_workspace_session_and_retry(pool, scope_uri, fn(lsp) {
      case capabilities.check(lsp, "workspace/symbol") {
        capabilities.Unsupported -> Ok(False)
        _ -> Ok(True)
      }
    })
  {
    Ok(b) -> Ok(b)
    Error(session.RetrySessionError(err)) ->
      Error(SessionFailed(describe_session_error(err)))
    Error(session.RetryRequestError(err)) ->
      Error(RequestFailed(tool_helpers.describe_request_error(err)))
  }
}

/// Tree-walk the LSP-returned `DocumentSymbol[]` looking for a
/// trailing-segment match for `remaining_path`. Two recursive arms:
///
/// 1. **exact-match-then-drill**: when a child's `name` equals the
///    head of `remaining_path`, descend into its children with
///    `tail`.
/// 2. **shadow recursion**: also descend into every child with the
///    same `remaining_path`. Lets us find `M/foo` where `foo` is
///    nested under an unnamed block or a same-name shadowed scope.
///
/// Returns SymbolMatch records anchored at `uri` with `full_path`
/// reconstructed by prepending each visited container name.
fn drill(
  symbols: List(DocumentSymbolDecoded),
  remaining_path: List(String),
  path_so_far: List(String),
  uri: String,
  strategy: fn(String, String) -> Option(String),
) -> List(SymbolMatch) {
  case remaining_path {
    [] -> []
    [last] -> {
      let matches_here =
        symbols
        |> list.filter_map(fn(s) {
          case strategy(s.name, last) {
            Some(via) ->
              Ok(SymbolMatch(
                name: s.name,
                kind: s.kind,
                uri: uri,
                range: s.range,
                selection_range: s.selection_range,
                full_path: list.reverse([s.name, ..path_so_far]),
                detail: s.detail,
                matched_via: via,
                body_hash: "",
              ))
            None -> Error(Nil)
          }
        })
      // Even at the leaf, descend into children — a deeply-nested
      // namesake can shadow a top-level one and the LLM may have
      // meant either.
      let nested =
        list.flat_map(symbols, fn(s) {
          drill(s.children, [last], [s.name, ..path_so_far], uri, strategy)
        })
      list.append(matches_here, nested)
    }
    [head, ..rest] -> {
      let exact =
        symbols
        |> list.filter(fn(s) { strategy(s.name, head) != None })
        |> list.flat_map(fn(s) {
          drill(s.children, rest, [s.name, ..path_so_far], uri, strategy)
        })
      let shadowed =
        list.flat_map(symbols, fn(s) {
          drill(
            s.children,
            remaining_path,
            [s.name, ..path_so_far],
            uri,
            strategy,
          )
        })
      list.append(exact, shadowed)
    }
  }
}

/// Tier-1 + tier-2 chained. Tier 2 fires only on tier-1 None.
fn name_match_strategy_with_fuzzy(
  symbol_name: String,
  query: String,
) -> Option(String) {
  case name_match_strategy(symbol_name, query) {
    Some(s) -> Some(s)
    None -> name_match_strategy_fuzzy(symbol_name, query)
  }
}

/// Compare a documentSymbol name against a name_path segment with
/// LSP-server-quirk tolerance. Two-tier:
///
/// **Tier 1 (high confidence, returns specific strategy):**
///   - `"exact"` — string equality. Always tried first.
///   - `"arity_strip"` — `main/1` matches `main` (Erlang/Elixir
///     function conventions).
///   - `"kind_strip"` — `KafkaClient class` matches `KafkaClient`
///     (jdtls / metals sometimes append kind words).
///   - `"trailing_segment"` — `resource.vpc` matches `vpc`
///     (terraform-ls block-type prefix).
///
/// **Tier 2 (lower confidence, only when tier 1 yields zero results):**
///   - `"case_insensitive"` — `User` matches `user`. Useful for
///     case-meaningful languages when the LLM didn't capitalize. May
///     over-collide; SymbolMatch carries `matched_via` so the LLM
///     can weight accordingly.
///   - `"substring"` — `KafkaClientImpl` matches `KafkaClient`.
///     Widens to surface plausible Multiple candidates instead of
///     dead-ending in NotFound. Capped (see `find_symbol`) to keep
///     response sizes bounded.
///
/// Returns `Some(strategy)` on a hit, `None` otherwise. Drill's
/// caller treats `None` as "no match, do not include this candidate."
fn name_match_strategy(
  symbol_name: String,
  query: String,
) -> Option(String) {
  let is_exact = symbol_name == query
  let is_arity = strip_arity_suffix(symbol_name) == query
  let is_kind = strip_kind_suffix(symbol_name) == query
  let is_trailing = trailing_segment(symbol_name) == query
  case is_exact, is_arity, is_kind, is_trailing {
    True, _, _, _ -> Some("exact")
    _, True, _, _ -> Some("arity_strip")
    _, _, True, _ -> Some("kind_strip")
    _, _, _, True -> Some("trailing_segment")
    _, _, _, _ -> None
  }
}

/// Tier 2 fuzzy: only fires when tier 1 returned zero matches across
/// the whole drill walk. Surfaced via `matched_via` so the LLM knows
/// these are heuristic candidates, not exact resolutions.
fn name_match_strategy_fuzzy(
  symbol_name: String,
  query: String,
) -> Option(String) {
  let is_ci = string.lowercase(symbol_name) == string.lowercase(query)
  let is_substring = string.contains(symbol_name, query)
  case is_ci, is_substring {
    True, _ -> Some("case_insensitive")
    _, True -> Some("substring")
    _, _ -> None
  }
}

fn strip_arity_suffix(name: String) -> String {
  case string.split(name, "/") {
    [base, arity] ->
      case int.parse(arity) {
        Ok(_) -> base
        Error(_) -> name
      }
    _ -> name
  }
}

fn strip_kind_suffix(name: String) -> String {
  // "KafkaClient class" → "KafkaClient". Only strip when the tail is
  // a known LSP kind word (avoid false positives on multi-word
  // function names from Markdown headings etc.).
  case string.split(name, " ") {
    [base, kind_word] ->
      case kind_word {
        "class" | "interface" | "struct" | "enum" | "trait"
        | "object" | "module" | "namespace" | "function"
        | "method" | "field" | "property" | "type"
        | "macro" | "constant" | "variable" | "constructor" -> base
        _ -> name
      }
    _ -> name
  }
}

fn trailing_segment(name: String) -> String {
  // "resource.vpc" → "vpc". Some LSPs (terraform-ls) prefix block
  // names with their block type. Take the trailing dot-separated
  // segment if multi-part.
  case string.split(name, ".") {
    [_] -> name
    parts ->
      case list.last(parts) {
        Ok(tail) -> tail
        Error(_) -> name
      }
  }
}

fn apply_policy(
  matches: List(SymbolMatch),
  policy: Disambiguation,
) -> Resolution {
  case matches, policy {
    [], _ -> NotFound(near_misses: [])
    [single], _ -> Single(single)
    many, FirstMatch ->
      case many {
        [first, ..] -> Single(first)
        [] -> NotFound(near_misses: [])
      }
    many, ClosestScope -> closest_scope(many)
    many, StrictSingle -> Multiple(many)
    many, AllMatches -> Multiple(many)
  }
}

fn closest_scope(matches: List(SymbolMatch)) -> Resolution {
  // Shortest full_path wins. Tie-break by first occurrence (list
  // order from drill is depth-first left-to-right, so the
  // earliest-scoped match comes first).
  let sorted =
    list.sort(matches, fn(a, b) {
      int.compare(list.length(a.full_path), list.length(b.full_path))
    })
  case sorted {
    [winner, ..] -> Single(winner)
    [] -> NotFound(near_misses: [])
  }
}

// -- get_symbols_overview ------------------------------------------------

/// Reshape the LSP `documentSymbol` tree into the LLM-friendly
/// outline defined in ADR-026 decision 8: only top-level + nested
/// symbols, line numbers in selection_range.start, noise kinds
/// (block-scope variables, inline lambdas) suppressed.
pub fn get_symbols_overview(
  pool: Pool,
  file_uri: String,
) -> Result(SymbolTree, SymbolsError) {
  use raw <- result.try(document_symbol_query(
    pool,
    file_uri,
    default_timeout_ms,
  ))
  let roots = list.map(raw, render_node) |> list.filter(node_is_outline_worthy)
  Ok(SymbolTree(roots: roots))
}

fn render_node(s: DocumentSymbolDecoded) -> SymbolTreeNode {
  SymbolTreeNode(
    name: s.name,
    kind: s.kind,
    line: s.selection_range.start.line,
    character: s.selection_range.start.character,
    end_line: s.range.end.line,
    end_character: s.range.end.character,
    detail: s.detail,
    children: s.children
      |> list.map(render_node)
      |> list.filter(node_is_outline_worthy),
  )
}

fn node_is_outline_worthy(node: SymbolTreeNode) -> Bool {
  // SymbolKind: 13=Variable, 14=Constant, 15=String, 16=Number,
  // 17=Boolean, 18=Array, 19=Object, 20=Key, 21=Null. The
  // editor-oriented outline shows these; the LLM rarely cares about
  // a function-local variable's existence. Keep top-level constants
  // (which usually carry semantic weight) by surfacing 14=Constant.
  case node.kind {
    13 -> False
    15 | 16 | 17 | 18 | 19 | 20 | 21 -> False
    _ -> True
  }
}

// -- find_referencing_symbols -------------------------------------------

/// Project LSP `textDocument/references` results through
/// `documentSymbol` so each call site comes back as a SymbolMatch
/// (named owner + container) rather than a bare `(uri, range)` pair.
pub fn find_referencing_symbols(
  pool: Pool,
  handle: SymbolHandle,
) -> Result(List(SymbolMatch), SymbolsError) {
  use locations <- result.try(references_query(
    pool,
    handle,
    default_timeout_ms,
  ))
  // For each reference location, fetch the documentSymbol tree of
  // its file and find the smallest symbol whose `range` contains the
  // reference position. That symbol is the "owner" of the reference.
  //
  // Mirrors find_symbol's fix-A behaviour: references can include
  // cross-workspace URIs (rust-analyzer surfacing stdlib refs at
  // ~/.rustup/...; clangd's system header includes) that the LSP
  // session can't open. Drop them per-URI rather than failing the
  // whole call.
  let unique_uris =
    locations
    |> list.map(fn(loc) { loc.uri })
    |> list.unique
  use trees_by_uri <- result.try(
    list.try_map(unique_uris, fn(uri) {
      case document_symbol_query(pool, uri, default_timeout_ms) {
        Ok(tree) -> Ok(Some(#(uri, tree)))
        Error(SessionFailed(_)) -> Ok(None)
        Error(other) -> Error(other)
      }
    })
    |> result.map(list.filter_map(_, fn(o) {
      case o {
        Some(pair) -> Ok(pair)
        None -> Error(Nil)
      }
    })),
  )
  let tree_map: Dict(String, List(DocumentSymbolDecoded)) =
    dict.from_list(trees_by_uri)
  let owners =
    list.filter_map(locations, fn(loc) {
      case dict.get(tree_map, loc.uri) {
        Error(_) -> Error(Nil)
        Ok(tree) ->
          case smallest_containing(tree, loc.range.start, [], loc.uri) {
            None -> Error(Nil)
            Some(sym) -> Ok(sym)
          }
      }
    })
  Ok(enrich_with_body_hashes(owners))
}

fn smallest_containing(
  symbols: List(DocumentSymbolDecoded),
  pos: Position,
  path_so_far: List(String),
  uri: String,
) -> Option(SymbolMatch) {
  // Depth-first; track the smallest range that still contains pos.
  list.fold(symbols, None, fn(best: Option(SymbolMatch), sym) {
    case range_contains(sym.range, pos) {
      False -> best
      True -> {
        let here =
          Some(SymbolMatch(
            name: sym.name,
            kind: sym.kind,
            uri: uri,
            range: sym.range,
            selection_range: sym.selection_range,
            full_path: list.reverse([sym.name, ..path_so_far]),
            detail: sym.detail,
            matched_via: "containing_range",
            body_hash: "",
          ))
        let nested =
          smallest_containing(
            sym.children,
            pos,
            [sym.name, ..path_so_far],
            uri,
          )
        case nested {
          Some(_) -> nested
          None ->
            case best {
              None -> here
              Some(SymbolMatch(range: best_range, ..)) ->
                case range_size(sym.range) < range_size(best_range) {
                  True -> here
                  False -> best
                }
            }
        }
      }
    }
  })
}

fn range_contains(r: Range, p: Position) -> Bool {
  let after_start = case p.line > r.start.line {
    True -> True
    False ->
      p.line == r.start.line && p.character >= r.start.character
  }
  let before_end = case p.line < r.end.line {
    True -> True
    False -> p.line == r.end.line && p.character <= r.end.character
  }
  after_start && before_end
}

fn range_size(r: Range) -> Int {
  // Approximate. Used only to break ties on "smallest containing
  // range". Line-major: bigger line-span dominates, character delta
  // is the tie-breaker.
  let line_span = r.end.line - r.start.line
  let char_delta = r.end.character - r.start.character
  line_span * 10_000 + char_delta
}

// -- edit_at_symbol ------------------------------------------------------

/// Produce an `EditPreview` for the requested mode against the
/// symbol identified by `handle`. Never writes — the caller routes
/// the preview through `apply_workspace_edit` if it wants to commit.
pub fn edit_at_symbol(
  pool: Pool,
  handle: SymbolHandle,
  mode: EditMode,
  content: String,
) -> Result(EditPreview, SymbolsError) {
  // Re-fetch the documentSymbol tree to verify the handle's
  // (name, selection_line) still exists at handle.uri. Without this
  // check a stale handle (file edited between find_symbol and
  // edit_at_symbol) would target a phantom range.
  use tree <- result.try(document_symbol_query(
    pool,
    handle.uri,
    default_timeout_ms,
  ))
  use sym <- result.try(verify_handle(tree, handle))
  // Drift check: recompute body_hash from the freshly-fetched range
  // and compare. Catches external edits that left identity intact
  // (same name + selection line) but changed the body — the LLM's
  // replacement content was reasoned against the OLD body.
  use _ <- result.try(verify_body_unchanged(handle, sym))
  let edit_range = case mode {
    ReplaceBody -> body_range_of(sym)
    InsertBefore -> Range(start: sym.range.start, end: sym.range.start)
    InsertAfter -> Range(start: sym.range.end, end: sym.range.end)
  }
  let new_text = case mode {
    ReplaceBody -> content
    InsertBefore -> append_newline(content)
    InsertAfter -> prepend_newline(content)
  }
  let rendered = render_preview(handle.uri, edit_range, new_text, mode)
  Ok(EditPreview(
    uri: handle.uri,
    range: edit_range,
    new_text: new_text,
    rendered: rendered,
  ))
}

fn append_newline(s: String) -> String {
  case string.ends_with(s, "\n") {
    True -> s
    False -> s <> "\n"
  }
}

fn prepend_newline(s: String) -> String {
  case string.starts_with(s, "\n") {
    True -> s
    False -> "\n" <> s
  }
}

fn verify_handle(
  tree: List(DocumentSymbolDecoded),
  handle: SymbolHandle,
) -> Result(DocumentSymbolDecoded, SymbolsError) {
  case find_matching_symbol(tree, handle) {
    Some(sym) -> Ok(sym)
    None ->
      Error(HandleStale(
        "symbol '"
        <> handle.name
        <> "' no longer at "
        <> handle.uri
        <> " line "
        <> int.to_string(handle.selection_line)
        <> "; call find_symbol again to refresh the handle",
      ))
  }
}

/// Compare handle's recorded body_hash to the current body's hash.
/// Empty recorded hash skips the check (graceful degradation when
/// the original handle-mint couldn't read the file). Mismatch =
/// HandleStale with a strong reconsider-content cue — the LLM must
/// re-run find_symbol AND rethink its replacement, not just retry
/// the edit.
fn verify_body_unchanged(
  handle: SymbolHandle,
  sym: DocumentSymbolDecoded,
) -> Result(Nil, SymbolsError) {
  case handle.body_hash {
    "" -> Ok(Nil)
    expected ->
      case body_hash_for(handle.uri, sym.range) {
        "" -> Ok(Nil)
        current ->
          case current == expected {
            True -> Ok(Nil)
            False ->
              Error(HandleStale(
                "body drift for '"
                <> handle.name
                <> "' at "
                <> handle.uri
                <> " line "
                <> int.to_string(handle.selection_line)
                <> "; file changed since handle minted. Re-run "
                <> "find_symbol + recheck replacement against new body.",
              ))
          }
      }
  }
}

fn find_matching_symbol(
  symbols: List(DocumentSymbolDecoded),
  handle: SymbolHandle,
) -> Option(DocumentSymbolDecoded) {
  case symbols {
    [] -> None
    [first, ..rest] -> {
      let here =
        first.name == handle.name
        && first.selection_range.start.line == handle.selection_line
        && first.kind == handle.kind
      case here {
        True -> Some(first)
        False ->
          case find_matching_symbol(first.children, handle) {
            Some(s) -> Some(s)
            None -> find_matching_symbol(rest, handle)
          }
      }
    }
  }
}

/// Compute the body range of a symbol. ADR-026 decision 2: derive
/// from `range` minus `selection_range`. For single-line definitions
/// (constants, type aliases) we fall back to the symbol's full
/// `range` because there's no separate body.
fn body_range_of(sym: DocumentSymbolDecoded) -> Range {
  case sym.range.start.line == sym.range.end.line {
    True -> sym.range
    False ->
      Range(
        start: Position(
          line: sym.selection_range.end.line + 1,
          character: 0,
        ),
        end: sym.range.end,
      )
  }
}

fn render_preview(
  uri: String,
  range: Range,
  new_text: String,
  mode: EditMode,
) -> String {
  let mode_str = case mode {
    ReplaceBody -> "replace_body"
    InsertBefore -> "insert_before"
    InsertAfter -> "insert_after"
  }
  let header =
    "edit_at_symbol mode="
    <> mode_str
    <> " uri="
    <> uri
    <> " range="
    <> int.to_string(range.start.line)
    <> ":"
    <> int.to_string(range.start.character)
    <> "-"
    <> int.to_string(range.end.line)
    <> ":"
    <> int.to_string(range.end.character)
  let preview_body = case string.length(new_text) > 400 {
    True ->
      string.slice(new_text, 0, 400) <> "\n…(" <> int.to_string(
        string.length(new_text) - 400,
      ) <> " more chars)"
    False -> new_text
  }
  header <> "\n---\n" <> preview_body
}

// -- Body-hash helpers (handle-staleness detection) ---------------------

/// Hex-encoded SHA-256 of the lines that fall inside `range`. Lines
/// are split on `\n` and joined with `\n` (no trailing newline) so
/// any column-level edit inside those lines flips the hash. Range is
/// inclusive on both ends. Returns `""` when the URI can't be read
/// (binary file, file deleted, etc.) — handle still mints, but
/// edit_at_symbol's drift check becomes a no-op.
fn body_hash_for(uri: String, range: Range) -> String {
  case read_uri_lines(uri) {
    Error(_) -> ""
    Ok(all_lines) -> hash_lines_at_range(all_lines, range)
  }
}

fn read_uri_lines(uri: String) -> Result(List(String), Nil) {
  let path = case string.starts_with(uri, "file://") {
    True -> string.drop_start(uri, 7)
    False -> uri
  }
  case fs_read_file(path) {
    Ok(bytes) ->
      case bit_array.to_string(bytes) {
        Ok(text) -> Ok(string.split(text, "\n"))
        Error(_) -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}

fn int_max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}

@external(erlang, "pharos_fs_ffi", "read_file")
fn fs_read_file(path: String) -> Result(BitArray, String)

/// Decorate a freshly-drilled SymbolMatch list with `body_hash`
/// values, batching reads so one file is opened at most once per
/// resolution. Called by `find_symbol` after drill so the JSON
/// response carries hashes the caller can later present back via
/// edit_at_symbol.
fn enrich_with_body_hashes(
  matches: List(SymbolMatch),
) -> List(SymbolMatch) {
  let unique_uris =
    matches
    |> list.map(fn(m) { m.uri })
    |> list.unique
  let file_cache: Dict(String, List(String)) =
    list.fold(unique_uris, dict.new(), fn(acc, uri) {
      case read_uri_lines(uri) {
        Ok(lines) -> dict.insert(acc, uri, lines)
        Error(_) -> acc
      }
    })
  list.map(matches, fn(m) {
    case dict.get(file_cache, m.uri) {
      Error(_) -> SymbolMatch(..m, body_hash: "")
      Ok(lines) -> SymbolMatch(..m, body_hash: hash_lines_at_range(lines, m.range))
    }
  })
}

fn hash_lines_at_range(all_lines: List(String), range: Range) -> String {
  let start = int_max(range.start.line, 0)
  let end = int_max(range.end.line, start)
  let total = list.length(all_lines)
  let end_clamped = case end < total {
    True -> end
    False -> total - 1
  }
  let slice =
    all_lines
    |> list.drop(start)
    |> list.take(end_clamped - start + 1)
  let joined = string.join(slice, "\n")
  crypto.hash(crypto.Sha256, <<joined:utf8>>)
  |> bit_array.base16_encode
  |> string.lowercase
}

// -- LSP request helpers -------------------------------------------------

/// Local shape of an LSP `WorkspaceSymbol` / `SymbolInformation`
/// entry. Only the fields we actually use.
type WorkspaceSymbolRow {
  WorkspaceSymbolRow(name: String, kind: Int, uri: String)
}

/// Local shape of an LSP `DocumentSymbol` entry. Fully recursive.
type DocumentSymbolDecoded {
  DocumentSymbolDecoded(
    name: String,
    kind: Int,
    range: Range,
    selection_range: Range,
    detail: Option(String),
    children: List(DocumentSymbolDecoded),
  )
}

type ReferenceLocation {
  ReferenceLocation(uri: String, range: Range)
}

fn workspace_symbol_query(
  pool: Pool,
  scope_uri: String,
  query: String,
  timeout_ms: Int,
) -> Result(List(WorkspaceSymbolRow), SymbolsError) {
  let params = json.object([#("query", json.string(query))])
  case
    session.with_workspace_session_and_retry(pool, scope_uri, fn(lsp) {
      tool_helpers.with_capability_gate(lsp, "workspace/symbol", fn() {
        session.request_with_content_modified_retry(fn() {
          proc.request(lsp, "workspace/symbol", params, timeout_ms)
        })
      })
    })
  {
    Ok(raw) ->
      decode.run(raw, decode.list(workspace_symbol_decoder()))
      |> result.map_error(fn(_) {
        DecodeFailed("workspace/symbol returned an unrecognised shape")
      })
    Error(session.RetrySessionError(err)) ->
      Error(SessionFailed(describe_session_error(err)))
    Error(session.RetryRequestError(err)) ->
      Error(RequestFailed(tool_helpers.describe_request_error(err)))
  }
}

fn document_symbol_query(
  pool: Pool,
  file_uri: String,
  timeout_ms: Int,
) -> Result(List(DocumentSymbolDecoded), SymbolsError) {
  let params =
    json.object([
      #("textDocument", json.object([#("uri", json.string(file_uri))])),
    ])
  case
    session.with_session_and_retry(pool, file_uri, fn(lsp) {
      tool_helpers.with_capability_gate(
        lsp,
        "textDocument/documentSymbol",
        fn() {
          session.request_with_content_modified_retry(fn() {
            proc.request(lsp, "textDocument/documentSymbol", params, timeout_ms)
          })
        },
      )
    })
  {
    Ok(raw) ->
      decode.run(raw, decode.list(document_symbol_decoder()))
      |> result.map_error(fn(_) {
        DecodeFailed("textDocument/documentSymbol returned an unrecognised shape")
      })
    Error(session.RetrySessionError(err)) ->
      Error(SessionFailed(describe_session_error(err)))
    Error(session.RetryRequestError(err)) ->
      Error(RequestFailed(tool_helpers.describe_request_error(err)))
  }
}

fn references_query(
  pool: Pool,
  handle: SymbolHandle,
  timeout_ms: Int,
) -> Result(List(ReferenceLocation), SymbolsError) {
  let params =
    json.object([
      #("textDocument", json.object([#("uri", json.string(handle.uri))])),
      #(
        "position",
        json.object([
          #("line", json.int(handle.selection_line)),
          #("character", json.int(handle.selection_character)),
        ]),
      ),
      #("context", json.object([#("includeDeclaration", json.bool(False))])),
    ])
  case
    session.with_session_and_retry(pool, handle.uri, fn(lsp) {
      tool_helpers.with_capability_gate(lsp, "textDocument/references", fn() {
        session.request_with_content_modified_retry(fn() {
          proc.request(lsp, "textDocument/references", params, timeout_ms)
        })
      })
    })
  {
    Ok(raw) ->
      // textDocument/references can return `Location[]` (modern),
      // `LocationLink[]` (rare; servers that opted into 3.14
      // declarationLink), or `null` (no references — lua-language-server
      // emits this when includeDeclaration=false yields nothing).
      // Accept all three; the loose decoder maps each to a flat
      // `ReferenceLocation` list.
      decode.run(raw, references_response_decoder())
      |> result.map_error(fn(_) {
        DecodeFailed("textDocument/references returned an unrecognised shape")
      })
    Error(session.RetrySessionError(err)) ->
      Error(SessionFailed(describe_session_error(err)))
    Error(session.RetryRequestError(err)) ->
      Error(RequestFailed(tool_helpers.describe_request_error(err)))
  }
}

// -- Decoders ------------------------------------------------------------

fn workspace_symbol_decoder() -> decode.Decoder(WorkspaceSymbolRow) {
  use name <- decode.field("name", decode.string)
  use kind <- decode.field("kind", decode.int)
  // LSP `SymbolInformation` puts uri at `location.uri`; some
  // servers shipping `WorkspaceSymbol` put it at `location.uri`
  // too, others use a string `location`. Try both.
  use uri <- decode.field(
    "location",
    decode.one_of(
      {
        use u <- decode.field("uri", decode.string)
        decode.success(u)
      },
      [decode.string],
    ),
  )
  decode.success(WorkspaceSymbolRow(name: name, kind: kind, uri: uri))
}

fn document_symbol_decoder() -> decode.Decoder(DocumentSymbolDecoded) {
  // textDocument/documentSymbol may return either:
  //   - DocumentSymbol[] (modern, hierarchical, with `selectionRange`
  //     + `children`), or
  //   - SymbolInformation[] (legacy, flat, with `location.range` +
  //     `containerName`).
  // bash-language-server, vscode-html-language-server, perlnavigator
  // and a few others still ship the legacy shape. Accept both.
  decode.one_of(modern_document_symbol_decoder(), [
    legacy_symbol_information_decoder(),
  ])
}

fn modern_document_symbol_decoder() -> decode.Decoder(DocumentSymbolDecoded) {
  use name <- decode.field("name", decode.string)
  use kind <- decode.field("kind", decode.int)
  use range <- decode.field("range", range_decoder())
  use selection_range <- decode.field("selectionRange", range_decoder())
  use detail <- decode.optional_field(
    "detail",
    None,
    decode.optional(decode.string),
  )
  use children <- decode.optional_field(
    "children",
    [],
    decode.list(document_symbol_decoder()),
  )
  decode.success(DocumentSymbolDecoded(
    name: name,
    kind: kind,
    range: range,
    selection_range: selection_range,
    detail: detail,
    children: children,
  ))
}

/// Legacy `SymbolInformation` shape — flat (no `children`), single
/// range carried under `location.range`. We synthesize the modern
/// fields: `range` and `selection_range` both take the location's
/// range (no separate identifier-vs-body range available), and the
/// hierarchical container info from `containerName` is dropped
/// (drill's shadow-recursion fallback still finds nested symbols
/// because legacy servers return them all at the top level anyway).
fn legacy_symbol_information_decoder() -> decode.Decoder(
  DocumentSymbolDecoded,
) {
  use name <- decode.field("name", decode.string)
  use kind <- decode.field("kind", decode.int)
  use range <- decode.field("location", {
    use r <- decode.field("range", range_decoder())
    decode.success(r)
  })
  decode.success(DocumentSymbolDecoded(
    name: name,
    kind: kind,
    range: range,
    selection_range: range,
    detail: None,
    children: [],
  ))
}

fn reference_location_decoder() -> decode.Decoder(ReferenceLocation) {
  use uri <- decode.field("uri", decode.string)
  use range <- decode.field("range", range_decoder())
  decode.success(ReferenceLocation(uri: uri, range: range))
}

/// `LocationLink` is the spec's link-style alternative to `Location`.
/// Servers that respond to `textDocument/references` with LocationLink
/// (rare, but spec-compliant under client linkSupport) put the URI at
/// `targetUri` and the range at `targetRange`.
fn location_link_decoder() -> decode.Decoder(ReferenceLocation) {
  use uri <- decode.field("targetUri", decode.string)
  use range <- decode.field("targetRange", range_decoder())
  decode.success(ReferenceLocation(uri: uri, range: range))
}

/// Loose decoder for `textDocument/references` responses. Accepts:
///   - `Location[]` (canonical)
///   - `LocationLink[]` (clients with linkSupport opt-in)
///   - `null` or `[]` (no references; lua-language-server emits null
///     when `includeDeclaration=false` and the symbol has no other
///     uses)
fn references_response_decoder() -> decode.Decoder(List(ReferenceLocation)) {
  decode.one_of(decode.list(reference_location_decoder()), [
    decode.list(location_link_decoder()),
    decode.success([]),
  ])
}

fn range_decoder() -> decode.Decoder(Range) {
  use start <- decode.field("start", position_decoder())
  use end <- decode.field("end", position_decoder())
  decode.success(Range(start: start, end: end))
}

fn position_decoder() -> decode.Decoder(Position) {
  use line <- decode.field("line", decode.int)
  use character <- decode.field("character", decode.int)
  decode.success(Position(line: line, character: character))
}

fn describe_session_error(err: session.SessionError) -> String {
  case err {
    session.NotAFileUri(uri) -> "not a file:// URI: " <> uri
    session.WorkspaceNotFound(uri) ->
      "no workspace root marker found ascending from " <> uri
    session.UnsupportedFileType(uri) -> "unsupported file type: " <> uri
    session.SpawnFailed(reason) -> "LSP spawn failed: " <> reason
    session.HandshakeFailed(reason) ->
      "LSP initialize handshake failed: " <> reason
  }
}

pub fn describe_symbols_error(err: SymbolsError) -> String {
  case err {
    InvalidNamePath(reason) -> "invalid name_path: " <> reason
    InvalidEditMode(reason) -> "invalid edit mode: " <> reason
    SessionFailed(reason) -> "session failed: " <> reason
    RequestFailed(reason) -> "request failed: " <> reason
    DecodeFailed(reason) -> "decode failed: " <> reason
    HandleStale(reason) -> "stale handle: " <> reason
    BodyRangeUnknown(reason) -> "body range unknown: " <> reason
  }
}

// -- JSON serializers (for MCP tool replies) ----------------------------

/// Wrap find_referencing_symbols's owner list in a Resolution-shaped
/// envelope so the LLM gets the same `{status, count, ...}` shape it
/// already knows from find_symbol. `status: "owners"` distinguishes
/// this from the Single/Multiple/NotFound trichotomy on find_symbol —
/// these are reference owners, not name resolutions.
pub fn referencing_symbols_to_json(owners: List(SymbolMatch)) -> json.Json {
  case owners {
    [] ->
      json.object([
        #("status", json.string("no_references")),
        #("count", json.int(0)),
      ])
    _ ->
      json.object([
        #("status", json.string("owners")),
        #("count", json.int(list.length(owners))),
        #(
          "owners",
          json.preprocessed_array(list.map(owners, symbol_match_to_json)),
        ),
      ])
  }
}

pub fn resolution_to_json(res: Resolution) -> json.Json {
  case res {
    Single(m) ->
      json.object([
        #("status", json.string("single")),
        #("match", symbol_match_to_json(m)),
      ])
    Multiple(ms) ->
      json.object([
        #("status", json.string("multiple")),
        #("count", json.int(list.length(ms))),
        #(
          "matches",
          json.preprocessed_array(list.map(ms, symbol_match_to_json)),
        ),
      ])
    NotFound(near_misses) ->
      json.object([
        #("status", json.string("not_found")),
        #(
          "near_misses",
          json.preprocessed_array(list.map(near_misses, json.string)),
        ),
      ])
  }
}

pub fn symbol_match_to_json(m: SymbolMatch) -> json.Json {
  json.object([
    #("name", json.string(m.name)),
    #("kind", json.int(m.kind)),
    #("kind_name", json.string(kind_name(m.kind))),
    #("uri", json.string(m.uri)),
    #("range", range_to_json(m.range)),
    #("selection_range", range_to_json(m.selection_range)),
    #(
      "full_path",
      json.preprocessed_array(list.map(m.full_path, json.string)),
    ),
    #(
      "detail",
      case m.detail {
        Some(d) -> json.string(d)
        None -> json.null()
      },
    ),
    #("matched_via", json.string(m.matched_via)),
    #("handle", symbol_handle_to_json(symbol_handle_of_match(m))),
  ])
}

pub fn symbol_handle_of_match(m: SymbolMatch) -> SymbolHandle {
  SymbolHandle(
    uri: m.uri,
    name: m.name,
    selection_line: m.selection_range.start.line,
    selection_character: m.selection_range.start.character,
    kind: m.kind,
    body_hash: m.body_hash,
  )
}

pub fn symbol_handle_to_json(h: SymbolHandle) -> json.Json {
  json.object([
    #("uri", json.string(h.uri)),
    #("name", json.string(h.name)),
    #("selection_line", json.int(h.selection_line)),
    #("selection_character", json.int(h.selection_character)),
    #("kind", json.int(h.kind)),
    #("body_hash", json.string(h.body_hash)),
  ])
}

/// Decode a SymbolHandle from a Dynamic argument (the MCP layer
/// passes args as Dynamic). Exposed so the MCP wrapper can parse
/// the `symbol_handle` field on inbound tool calls. `body_hash` is
/// optional for backwards compatibility — handles minted by
/// pre-staleness pharos versions carry no hash and skip the drift
/// check downstream.
pub fn symbol_handle_decoder() -> decode.Decoder(SymbolHandle) {
  use uri <- decode.field("uri", decode.string)
  use name <- decode.field("name", decode.string)
  use selection_line <- decode.field("selection_line", decode.int)
  use selection_character <- decode.field("selection_character", decode.int)
  use kind <- decode.field("kind", decode.int)
  use body_hash <- decode.optional_field("body_hash", "", decode.string)
  decode.success(SymbolHandle(
    uri: uri,
    name: name,
    selection_line: selection_line,
    selection_character: selection_character,
    kind: kind,
    body_hash: body_hash,
  ))
}

pub fn symbol_tree_to_json(t: SymbolTree) -> json.Json {
  json.object([
    #(
      "roots",
      json.preprocessed_array(list.map(t.roots, symbol_tree_node_to_json)),
    ),
  ])
}

fn symbol_tree_node_to_json(n: SymbolTreeNode) -> json.Json {
  json.object([
    #("name", json.string(n.name)),
    #("kind", json.int(n.kind)),
    #("kind_name", json.string(kind_name(n.kind))),
    #("line", json.int(n.line)),
    #("character", json.int(n.character)),
    #("end_line", json.int(n.end_line)),
    #("end_character", json.int(n.end_character)),
    #(
      "detail",
      case n.detail {
        Some(d) -> json.string(d)
        None -> json.null()
      },
    ),
    #(
      "children",
      json.preprocessed_array(list.map(n.children, symbol_tree_node_to_json)),
    ),
  ])
}

pub fn edit_preview_to_json(p: EditPreview) -> json.Json {
  json.object([
    #("uri", json.string(p.uri)),
    #("range", range_to_json(p.range)),
    #("new_text", json.string(p.new_text)),
    #("rendered", json.string(p.rendered)),
  ])
}

fn range_to_json(r: Range) -> json.Json {
  json.object([
    #("start", position_to_json(r.start)),
    #("end", position_to_json(r.end)),
  ])
}

fn position_to_json(p: Position) -> json.Json {
  json.object([
    #("line", json.int(p.line)),
    #("character", json.int(p.character)),
  ])
}

/// LSP `SymbolKind` enum → human name. Surfaced in tool responses so
/// the LLM does not have to memorise the integer mapping.
fn kind_name(k: Int) -> String {
  case k {
    1 -> "File"
    2 -> "Module"
    3 -> "Namespace"
    4 -> "Package"
    5 -> "Class"
    6 -> "Method"
    7 -> "Property"
    8 -> "Field"
    9 -> "Constructor"
    10 -> "Enum"
    11 -> "Interface"
    12 -> "Function"
    13 -> "Variable"
    14 -> "Constant"
    15 -> "String"
    16 -> "Number"
    17 -> "Boolean"
    18 -> "Array"
    19 -> "Object"
    20 -> "Key"
    21 -> "Null"
    22 -> "EnumMember"
    23 -> "Struct"
    24 -> "Event"
    25 -> "Operator"
    26 -> "TypeParameter"
    _ -> "Unknown"
  }
}
