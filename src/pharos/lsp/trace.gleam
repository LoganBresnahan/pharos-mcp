//// LSP traffic tracer.
////
//// Emits one debug-level log line per chunk of bytes flowing in
//// either direction between pharos and an LSP subprocess. Off by
//// default; activate either by tuning the logger filter
//// (`PHAROS_LOG=info,pharos/lsp/trace=debug`) or by setting
//// `PHAROS_TRACE_LSP=1`, which the writer applies as the same
//// override at boot.
////
//// Output shape (one per direction per chunk):
////
////     ... debug pharos/lsp/trace cid=req-7 msg="lsp wire" \
////       direction=out bytes=137 body="Content-Length:..."
////
//// Body is truncated to `max_body_bytes` and control characters are
//// escaped so the line stays parseable. **Tracer output captures
//// file content of in-buffer documents** — keep traces in dev only;
//// do not ship them in support bundles without redaction.

import gleam/bit_array
import gleam/int
import pharos/log
import pharos/log/entry.{Debug}

const target: String = "pharos/lsp/trace"

const max_body_bytes: Int = 2000

/// Trace bytes leaving pharos (write to LSP stdin).
pub fn out(bytes: BitArray) -> Nil {
  emit("out", bytes)
}

/// Trace bytes arriving from the LSP (read from stdout).
pub fn incoming(bytes: BitArray) -> Nil {
  emit("in", bytes)
}

fn emit(direction: String, bytes: BitArray) -> Nil {
  let total = bit_array.byte_size(bytes)
  let truncated = case total > max_body_bytes {
    True ->
      case bit_array.slice(bytes, at: 0, take: max_body_bytes) {
        Ok(prefix) -> prefix
        Error(_) -> bytes
      }
    False -> bytes
  }
  let body = render_bytes(truncated)
  log.at_with_fields(
    target,
    Debug,
    "lsp wire",
    [
      #("direction", direction),
      #("bytes", int.to_string(total)),
      #("body", body),
    ],
  )
}

@external(erlang, "pharos_log_ffi", "render_trace_body")
fn render_bytes(bytes: BitArray) -> String
