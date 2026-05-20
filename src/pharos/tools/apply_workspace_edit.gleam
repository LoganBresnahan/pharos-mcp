//// MCP tool: `apply_workspace_edit`.
////
//// Companion to `rename_preview`, `format_document`, and
//// `code_actions` — those tools return a `WorkspaceEdit` rendered as
//// a human-readable summary; this tool takes a raw `WorkspaceEdit`
//// JSON object and writes it to disk. Closes the loop on the
//// "edit-as-data" tools that previously left application to the
//// LLM's own Edit tool.
////
//// Workflow:
////
////   1. Get a raw `WorkspaceEdit` JSON from the LSP. Today the typed
////      tools render the edit as text; pair this tool with
////      `lsp_request_raw` (`textDocument/rename` / `formatting` /
////      `codeAction`) to capture the raw JSON. A future change may
////      add a `return_raw` flag to the typed tools.
////   2. Call `apply_workspace_edit` with `dry_run: true` (the
////      default) — pharos validates the edit (no overlapping ranges,
////      no positions past EOF) and reports what would change.
////   3. Re-call with `dry_run: false` to actually write.
////
//// Safety:
////   - `dry_run` defaults to `true`. The user opts in to writing.
////   - Per-file atomic writes (write to `.tmp`, rename over original)
////     so a partial run never leaves a half-written file.
////   - Overlapping edits within the same file → error (no apply).
////   - LSP `documentChanges` with `resourceOperations` (CreateFile /
////     RenameFile / DeleteFile) → rejected. Plain text edits only.
////   - Per-file failures are NOT atomic across files. If file A
////     succeeds and file B fails the read step, A is already on
////     disk. The summary names every applied + failed file.
////
//// Position semantics: LSP positions are `(line, character)` where
//// `character` is a UTF-16 code-unit offset within the line. The
//// FFI in `pharos_apply_edit_ffi` approximates this via Unicode code
//// points — exact for the BMP (which covers all real source code
//// we have seen), off-by-one per surrogate-pair character (emoji,
//// supplementary plane). Document this in the tool description so
//// callers understand the edge case.

import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import pharos/lsp/registry as lsp_registry
import pharos/tools/session
import pharos/tools/workspace_edit.{type FileEdits, type TextEdit}
import pharos/workspace_root

pub type ApplyError {
  DecodeFailed(reason: String)
  /// At least one file URI was not a `file://` URI we can resolve to
  /// a local path. The string lists the offending URIs.
  InvalidUris(reason: String)
}

pub type ApplyOutcome {
  Applied(file: String, old_size: Int, new_size: Int)
  Failed(file: String, reason: String)
}

/// Tuple shape passed to the Erlang FFI. Mirrors the order in
/// `pharos_apply_edit_ffi:apply_to_file/3`.
type FfiEdit =
  #(Int, Int, Int, Int, String)

@external(erlang, "pharos_apply_edit_ffi", "apply_to_file")
fn apply_to_file_ffi(
  path: String,
  edits: List(FfiEdit),
  dry_run: Bool,
) -> Result(#(Int, Int), String)

/// Apply a `WorkspaceEdit` to disk (or simulate, when `dry_run`).
/// Returns the rendered summary; per-file failures appear inline so
/// the caller sees exactly what landed.
pub fn handle(
  edit: Dynamic,
  dry_run: Bool,
) -> Result(String, ApplyError) {
  use file_edits <- result.try(decode(edit))
  use _ <- result.try(reject_unresolvable(file_edits))
  let outcomes = list.map(file_edits, run_one(_, dry_run))
  Ok(render_summary(outcomes, dry_run))
}

fn decode(value: Dynamic) -> Result(List(FileEdits), ApplyError) {
  case workspace_edit.decode(value) {
    Ok(edits) -> Ok(edits)
    Error(workspace_edit.DecodeError(reason)) -> Error(DecodeFailed(reason))
  }
}

fn reject_unresolvable(
  file_edits: List(FileEdits),
) -> Result(Nil, ApplyError) {
  let bad =
    file_edits
    |> list.filter_map(fn(fe) {
      case workspace_root.uri_to_path(fe.uri) {
        Ok(_) -> Error(Nil)
        Error(_) -> Ok(fe.uri)
      }
    })
  case bad {
    [] -> Ok(Nil)
    _ -> Error(InvalidUris(describe_unresolvable_uris(bad)))
  }
}

/// ADR-029: produce a teaching error for virtual-URI edit attempts.
/// Virtual URIs (`jdt://...`, `csharp://...`) represent read-only
/// library code with no on-disk path to write to — even if the LSP
/// accepted the edit, nothing would persist. The error message
/// names the right alternative (project-local override or build
/// configuration change) so the LLM picks a productive next action
/// instead of retrying with different params.
///
/// Two cases:
///   - Known custom scheme (declared in `custom_uri_schemes`):
///     virtual-URI message naming the language.
///   - Other non-`file://` URIs: generic invalid-URI message.
fn describe_unresolvable_uris(bad: List(String)) -> String {
  let #(virtual, other) =
    list.partition(bad, fn(uri) {
      session.is_custom_uri(uri)
      && case lsp_registry.for_custom_uri(uri) {
        Ok(_) -> True
        Error(_) -> False
      }
    })
  let virtual_msg = case virtual {
    [] -> ""
    _ ->
      "cannot edit virtual URIs (read-only library code; modify deps via "
      <> "project override or build configuration): "
      <> string.join(virtual, ", ")
  }
  let other_msg = case other {
    [] -> ""
    _ -> "non-file:// URIs cannot be applied: " <> string.join(other, ", ")
  }
  case virtual_msg, other_msg {
    "", o -> o
    v, "" -> v
    v, o -> v <> "; " <> o
  }
}

fn run_one(file: FileEdits, dry_run: Bool) -> ApplyOutcome {
  case workspace_root.uri_to_path(file.uri) {
    Error(_) -> Failed(file.uri, "not a file:// URI")
    Ok(path) -> {
      let ffi_edits = list.map(file.edits, edit_to_ffi)
      case apply_to_file_ffi(path, ffi_edits, dry_run) {
        Ok(#(old_size, new_size)) -> Applied(file.uri, old_size, new_size)
        Error(reason) -> Failed(file.uri, reason)
      }
    }
  }
}

fn edit_to_ffi(edit: TextEdit) -> FfiEdit {
  #(
    edit.start_line,
    edit.start_character,
    edit.end_line,
    edit.end_character,
    edit.new_text,
  )
}

fn render_summary(
  outcomes: List(ApplyOutcome),
  dry_run: Bool,
) -> String {
  let header = case dry_run {
    True -> "Dry run — no files written. Re-call with dry_run=false to apply."
    False -> "Applied edits."
  }
  let lines = list.map(outcomes, render_outcome)
  let counts = render_counts(outcomes)
  string.join([header, counts, ..lines], "\n")
}

fn render_counts(outcomes: List(ApplyOutcome)) -> String {
  let #(ok, fail) =
    list.fold(outcomes, #(0, 0), fn(acc, o) {
      let #(ok, fail) = acc
      case o {
        Applied(_, _, _) -> #(ok + 1, fail)
        Failed(_, _) -> #(ok, fail + 1)
      }
    })
  int.to_string(ok)
  <> " file(s) ok, "
  <> int.to_string(fail)
  <> " failed."
}

fn render_outcome(o: ApplyOutcome) -> String {
  case o {
    Applied(file, old_size, new_size) ->
      "  ok    "
      <> file
      <> "  ("
      <> int.to_string(old_size)
      <> " → "
      <> int.to_string(new_size)
      <> " bytes)"
    Failed(file, reason) -> "  fail  " <> file <> "  — " <> reason
  }
}
