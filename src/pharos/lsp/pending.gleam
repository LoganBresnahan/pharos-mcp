//// Pending LSP request tracker.
////
//// LSP responses are asynchronous and identified only by the `id`
//// echoed from the original request. The LSP client actor (see
//// `lsp/client`) needs a map from outgoing request id to the caller
//// awaiting that response so it can route the reply without blocking
//// its I/O loop.
////
//// This module is the typed map. It is pure — no processes, no
//// state machines — so it can be tested in isolation. The LSP
//// client's actor state owns one of these and updates it on each
//// outgoing request and each incoming response.
////
//// Generic over `reply`: each LSP method has a different response
//// shape. Callers parameterize on whatever type they want delivered
//// to their `Subject(reply)`.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}

pub opaque type Pending(reply) {
  Pending(map: Dict(Int, Subject(reply)))
}

/// Build an empty tracker.
pub fn new() -> Pending(reply) {
  Pending(map: dict.new())
}

/// Register a caller for a future response with this id.
///
/// If the same id is already registered (which would indicate a bug
/// in the id-generation strategy), the existing entry is replaced
/// silently. Callers should never reuse an id that is still in
/// flight.
pub fn register(
  pending: Pending(reply),
  id: Int,
  subject: Subject(reply),
) -> Pending(reply) {
  let Pending(map) = pending
  Pending(map: dict.insert(map, id, subject))
}

/// Look up and remove the caller for an id. Returns the subject if
/// found, plus the updated tracker without that entry.
///
/// Returns `Error(Nil)` if no caller is waiting on this id — usually
/// means the response arrived after the caller's timeout, or the id
/// was never ours.
pub fn take(
  pending: Pending(reply),
  id: Int,
) -> #(Result(Subject(reply), Nil), Pending(reply)) {
  let Pending(map) = pending
  case dict.get(map, id) {
    Ok(subject) -> #(Ok(subject), Pending(map: dict.delete(map, id)))
    Error(Nil) -> #(Error(Nil), pending)
  }
}

/// Number of in-flight requests. Useful for diagnostics and for
/// supervisor decisions (e.g. refuse new requests when too many are
/// pending).
pub fn size(pending: Pending(reply)) -> Int {
  let Pending(map) = pending
  dict.size(map)
}

/// Whether any callers are waiting.
pub fn is_empty(pending: Pending(reply)) -> Bool {
  size(pending) == 0
}

/// All currently-registered ids. Order is unspecified.
pub fn ids(pending: Pending(reply)) -> List(Int) {
  let Pending(map) = pending
  dict.keys(map)
}
