//// Document sync with the disk (ADR-038).
////
//// pharos answers about saved files. Every question to a server
//// re-reads, from disk, the file asked about and every other document
//// pharos holds open on that server; this module decides what each
//// needs sent so the server's copy matches the disk, and builds those
//// notifications. Pure: the pool keeps the per-document state, the
//// proc holds the server's sync capability and writes the bodies.

import gleam/bit_array
import gleam/crypto
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// What the server wants after a save.
pub type SaveMode {
  NoSave
  Save
  SaveWithText
}

/// The parts of `ServerCapabilities.textDocumentSync` pharos acts on.
/// `change` is the `TextDocumentSyncKind`: 0 None, 1 Full,
/// 2 Incremental. `open_close` is whether the server asked for
/// `didOpen` / `didClose`.
pub type SyncCaps {
  SyncCaps(change: Int, save: SaveMode, open_close: Bool)
}

/// What pharos last sent the server for one document. A closed
/// document keeps its version, so reopening it never goes backwards.
pub type DocState {
  DocState(version: Int, hash: BitArray, open: Bool, sent_end: #(Int, Int))
}

/// A document's file as read just now.
pub type DiskState {
  OnDisk(text: String, hash: BitArray)
  Gone
}

/// What one document needs sent before the question.
pub type Plan {
  /// The server's copy already matches the disk.
  Unchanged
  /// Not open on the server: `didOpen` at `version`.
  Open(version: Int)
  /// The disk differs from the server's copy: re-sync at `version`.
  Change(version: Int)
  /// The file is gone, or the document fell out of the open set:
  /// `didClose`, so the server goes back to the disk.
  Close
}

/// One document's sync, as the proc writes it.
pub type SyncOp {
  OpOpen(uri: String, language_id: String, version: Int, text: String)
  OpChange(
    uri: String,
    language_id: String,
    version: Int,
    text: String,
    /// The end of the text last sent to the server, when it was open.
    previous_end: Option(#(Int, Int)),
    /// ADR-038 amendment (A): None sends the form the sync kind asks for;
    /// Some(True) forces the ranged form, Some(False) the range-less one.
    form: Option(Bool),
    /// The text last sent has a lone `\r`: a ranged change goes as
    /// `didClose` + `didOpen` instead (servers that count lines at `\n`
    /// only would place its end past their last line).
    previous_lone_cr: Bool,
  )
  OpClose(uri: String)
  /// ADR-043: a notification about no open document (the files changed
  /// on disk), already encoded. Sent first in its batch, so the batch's
  /// freshness rule covers what it tells the server.
  OpNotify(body: String)
}

/// #38: the LSP position just past the end of `text`, as (line,
/// character): lines end at `\r\n`, `\n` or a lone `\r`, and characters
/// count UTF-16 code units (the spec's default encoding; pharos doesn't
/// negotiate another). A text ending in a line break ends at the start of
/// the line after it; the empty text ends at (0, 0).
pub fn end_position(text: String) -> #(Int, Int) {
  let #(line, character, _) =
    string.to_utf_codepoints(text)
    |> list.fold(#(0, 0, False), fn(acc, cp) {
      let #(line, character, after_cr) = acc
      case string.utf_codepoint_to_int(cp) {
        13 -> #(line + 1, 0, True)
        10 if after_cr -> #(line, 0, False)
        10 -> #(line + 1, 0, False)
        c if c > 0xFFFF -> #(line, character + 2, False)
        _ -> #(line, character + 1, False)
      }
    })
  #(line, character)
}

/// Whether `text` has a `\r` not followed by `\n`. LSP 3.17 counts one
/// as a line break, and pharos computes a ranged change's end that way;
/// rust-analyzer, clangd and ruby-lsp count lines at `\n` only, and gopls
/// tolerates one but not a file of them, so after such a text a ranged
/// change's end lands past their last line.
pub fn has_lone_cr(text: String) -> Bool {
  string.contains(text, "\r")
  && string.contains(string.replace(text, "\r\n", ""), "\r")
}

/// SHA-256 of the text as it would be sent.
pub fn content_hash(text: String) -> BitArray {
  crypto.hash(crypto.Sha256, bit_array.from_string(text))
}

/// The plan for the document a question is about. A file that is gone
/// is answered as one that never existed: closed if pharos holds it
/// open, otherwise left alone.
pub fn plan_subject(existing: Result(DocState, Nil), disk: DiskState) -> Plan {
  case disk, existing {
    Gone, Ok(DocState(open: True, ..)) -> Close
    Gone, _ -> Unchanged
    OnDisk(..), Error(Nil) -> Open(1)
    OnDisk(..), Ok(DocState(version:, open: False, ..)) -> Open(version + 1)
    OnDisk(hash:, ..), Ok(DocState(version:, hash: sent, open: True, ..)) ->
      case sent == hash {
        True -> Unchanged
        False -> Change(version + 1)
      }
  }
}

/// The plan for another document already open on the same server.
pub fn plan_open(existing: DocState, disk: DiskState) -> Plan {
  case existing.open, disk {
    False, _ -> Unchanged
    True, Gone -> Close
    True, OnDisk(hash:, ..) ->
      case existing.hash == hash {
        True -> Unchanged
        False -> Change(existing.version + 1)
      }
  }
}

/// Which open documents to close so at most `cap` stay open, least
/// recently used first. `open` is `(uri, last_used)`; `keep` is never
/// chosen.
pub fn lru_victims(
  open: List(#(String, Int)),
  keep: String,
  cap: Int,
) -> List(String) {
  let excess = list.length(open) - cap
  case excess > 0 {
    False -> []
    True ->
      open
      |> list.filter(fn(entry) { entry.0 != keep })
      |> list.sort(fn(a, b) { int.compare(a.1, b.1) })
      |> list.take(excess)
      |> list.map(fn(entry) { entry.0 })
  }
}

/// Read the sync capability out of `InitializeResult.capabilities`,
/// the way VS Code's client resolves it.
///
/// - Left out: the spec's default, None, with no open/close.
/// - The number form: that kind. A non-None kind also means open/close
///   and a plain `didSave`; None means neither.
/// - The options form: its `change` (default None), its `openClose`
///   (default false) and its `save` (`true`, or `{includeText}`; left
///   out or `false` means none).
pub fn caps_from_capabilities(capabilities: Dynamic) -> SyncCaps {
  case decode.run(capabilities, sync_decoder()) {
    Ok(caps) -> caps
    Error(_) -> none()
  }
}

fn none() -> SyncCaps {
  SyncCaps(change: 0, save: NoSave, open_close: False)
}

fn sync_decoder() -> decode.Decoder(SyncCaps) {
  decode.optional_field(
    "textDocumentSync",
    none(),
    decode.one_of(
      decode.int
        |> decode.map(fn(kind) {
          case kind {
            0 -> none()
            _ -> SyncCaps(change: kind, save: Save, open_close: True)
          }
        }),
      [options_decoder()],
    ),
    decode.success,
  )
}

fn options_decoder() -> decode.Decoder(SyncCaps) {
  use change <- decode.optional_field("change", 0, decode.int)
  use open_close <- decode.optional_field("openClose", False, decode.bool)
  use save <- decode.optional_field("save", NoSave, save_decoder())
  decode.success(SyncCaps(change:, save:, open_close:))
}

fn save_decoder() -> decode.Decoder(SaveMode) {
  decode.one_of(
    decode.bool
      |> decode.map(fn(wanted) {
        case wanted {
          True -> Save
          False -> NoSave
        }
      }),
    [
      {
        use include_text <- decode.optional_field(
          "includeText",
          False,
          decode.bool,
        )
        decode.success(case include_text {
          True -> SaveWithText
          False -> Save
        })
      },
    ],
  )
}

/// The notifications, in order, that carry out one document's sync.
///
/// - Open: a `didOpen`. pharos opens every document it asks about,
///   whatever the server's `openClose` says (unchanged behaviour; which
///   servers advertise otherwise is ADR-038 follow-up data).
/// - Close: a `didClose`, so the server goes back to the disk.
/// - Change, sync kind Full or Incremental: one `didChange` with a single
///   content change carrying the whole `text`, then a `didSave` when the
///   server asks for one. Its form follows `ranged_end` (ADR-038
///   amendment (A)): for Incremental, a replace ranged from (0,0) to the
///   end of the text last sent; for Full, the range-less form;
///   `full_change_as_range` forces either.
/// - Change in the ranged form after a text with a lone `\r`: `didClose`
///   then `didOpen` instead, since servers disagree on where such a text
///   ends (`has_lone_cr`), then a `didSave` when the server asks for one.
/// - Change, sync kind None: `didClose` then `didOpen` at the new
///   version (never a second `didOpen` without a close), then a `didSave`
///   when the server asks for one. Since pharos
///   opened the document whatever `openClose` said, it mirrors that on
///   change; a server that really reads the disk ignores both. Sending
///   such servers nothing at all waits on the capability survey.
pub fn notifications(caps: SyncCaps, op: SyncOp) -> List(String) {
  case op, caps.change {
    OpOpen(uri:, language_id:, version:, text:), _ -> [
      did_open(uri, language_id, version, text),
    ]
    OpClose(uri:), _ -> [did_close(uri)]
    OpNotify(body:), _ -> [body]
    OpChange(uri:, language_id:, version:, text:, ..), 0 ->
      reopen(caps, uri, language_id, version, text)
    OpChange(
      uri:,
      language_id:,
      version:,
      text:,
      previous_end:,
      form:,
      previous_lone_cr:,
    ),
      kind
    ->
      case ranged_end(kind, form, previous_end), previous_lone_cr {
        // A ranged change after a text with a lone \r: the server may
        // count that text's lines differently, so reopen instead, as for
        // sync kind None. Correct whatever its line counting.
        Some(_), True -> reopen(caps, uri, language_id, version, text)
        end, _ -> [
          did_change(uri, version, text, end),
          ..saved(caps, uri, text)
        ]
      }
  }
}

/// #56: does `op` go out as a `didClose` + `didOpen` (a change to a server
/// with sync kind None, or a ranged change after a text with a lone `\r`)?
pub fn reopens(caps: SyncCaps, op: SyncOp) -> Bool {
  case op, caps.change {
    OpChange(..), 0 -> True
    OpChange(previous_end:, form:, previous_lone_cr:, ..), kind ->
      case ranged_end(kind, form, previous_end), previous_lone_cr {
        Some(_), True -> True
        _, _ -> False
      }
    _, _ -> False
  }
}

/// A change carried out as `didClose` + `didOpen`, then the `didSave` a
/// server that asks for saves gets after any change (#45): without it
/// rust-analyzer's cargo check didn't re-run, and its entries from the
/// text before the reopen were answered as fresh.
fn reopen(
  caps: SyncCaps,
  uri: String,
  language_id: String,
  version: Int,
  text: String,
) -> List(String) {
  [
    did_close(uri),
    did_open(uri, language_id, version, text),
    ..saved(caps, uri, text)
  ]
}

/// The `didSave` that follows a change, when the server asks for one.
fn saved(caps: SyncCaps, uri: String, text: String) -> List(String) {
  case caps.save {
    NoSave -> []
    Save -> [did_save(uri, Error(Nil))]
    SaveWithText -> [did_save(uri, Ok(text))]
  }
}

/// ADR-038 amendment (A): the end a didChange's range runs to, or None
/// for the range-less form. LSP 3.17's Incremental kind reads "only
/// incremental updates after open": a ranged replace of the whole text
/// is one, and ruby-lsp rejects the range-less form. A Full server gets
/// the full text without a range, as the spec asks.
pub fn ranged_end(
  kind: Int,
  form: Option(Bool),
  previous_end: Option(#(Int, Int)),
) -> Option(#(Int, Int)) {
  case form, kind {
    Some(False), _ -> None
    Some(True), _ -> previous_end
    None, 2 -> previous_end
    None, _ -> None
  }
}

fn notification(method: String, params: json.Json) -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("method", json.string(method)),
    #("params", params),
  ])
  |> json.to_string
}

fn did_open(uri: String, language_id: String, version: Int, text: String) {
  notification(
    "textDocument/didOpen",
    json.object([
      #(
        "textDocument",
        json.object([
          #("uri", json.string(uri)),
          #("languageId", json.string(language_id)),
          #("version", json.int(version)),
          #("text", json.string(text)),
        ]),
      ),
    ]),
  )
}

fn did_close(uri: String) -> String {
  notification(
    "textDocument/didClose",
    json.object([
      #("textDocument", json.object([#("uri", json.string(uri))])),
    ]),
  )
}

fn did_change(
  uri: String,
  version: Int,
  text: String,
  previous_end: Option(#(Int, Int)),
) -> String {
  // The range-less full-content form, or the same replace with a range
  // over the whole text the server was last sent, as `ranged_end` picks
  // (ADR-038 amendment (A)).
  let change = case previous_end {
    None -> [#("text", json.string(text))]
    Some(#(line, character)) -> [
      #(
        "range",
        json.object([
          #("start", position(0, 0)),
          #("end", position(line, character)),
        ]),
      ),
      #("text", json.string(text)),
    ]
  }
  notification(
    "textDocument/didChange",
    json.object([
      #(
        "textDocument",
        json.object([
          #("uri", json.string(uri)),
          #("version", json.int(version)),
        ]),
      ),
      #("contentChanges", json.preprocessed_array([json.object(change)])),
    ]),
  )
}

fn position(line: Int, character: Int) -> json.Json {
  json.object([#("line", json.int(line)), #("character", json.int(character))])
}

fn did_save(uri: String, text: Result(String, Nil)) -> String {
  let document = #("textDocument", json.object([#("uri", json.string(uri))]))
  notification(
    "textDocument/didSave",
    json.object(case text {
      Ok(t) -> [document, #("text", json.string(t))]
      Error(Nil) -> [document]
    }),
  )
}
