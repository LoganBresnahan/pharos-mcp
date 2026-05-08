//// LSP traffic tracer.
////
//// Emits one debug-level log line per chunk of bytes flowing in
//// either direction between pharos and an LSP subprocess. Off by
//// default; activate either by tuning the logger filter
//// (`PHAROS_LOG=info,pharos/lsp/trace=debug`), by setting
//// `[lsp] trace = true` in pharos.toml, or by setting
//// `PHAROS_TRACE_LSP=1`, which the config umbrella applies as the
//// same filter override at boot.
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
import pharos/log/entry.{type LogEntry, Debug, LogEntry}
import pharos/log/ring
import pharos/log/trace_ring

const target: String = "pharos/lsp/trace"

const max_body_bytes: Int = 2000

@external(erlang, "pharos_log_ffi", "iso_timestamp_ms")
fn now_ms() -> String

@external(erlang, "pharos_log_ffi", "cid_get")
fn cid_get_ffi() -> Result(String, Nil)

/// Trace bytes leaving pharos (write to LSP stdin).
pub fn out(bytes: BitArray) -> Nil {
  emit("out", bytes)
}

/// Trace bytes arriving from the LSP (read from stdout).
pub fn incoming(bytes: BitArray) -> Nil {
  emit("in", bytes)
}

fn emit(direction: String, bytes: BitArray) -> Nil {
  // Render once, write to the always-on `trace_ring` unconditionally,
  // then fall through to the gated log path.
  //
  // Why unconditional: the persistent_term emit-side filter check
  // (`trace_filter_is_on`) closes the at-emitter race for
  // sequentially-issued runtime_trace_lsp. The remaining residual is
  // parallel dispatch: when the MCP server hands hover and trace_lsp
  // to different worker processes at the same instant, hover's first
  // emit can fire before trace_lsp's `process.call` reaches the
  // writer. With an always-on dedicated trace ring, the producer
  // always writes; the consumer (`runtime_trace_lsp`) reads from the
  // ring. No filter toggle, no race.
  //
  // Cost: one ETS insert per wire chunk in production. Bounded by
  // `trace_ring.default_capacity` (100). At ~50-200 wire chunks/sec
  // under heavy LSP traffic, ~us per ETS insert = negligible CPU.
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
  let fields = [
    #("direction", direction),
    #("bytes", int.to_string(total)),
    #("body", body),
  ]
  let log_entry = build_entry(fields)
  let line = entry.render(log_entry)
  trace_ring.insert(line, Debug)

  // Gated path: fan out to the general log (stderr, file, log_ring
  // for runtime_log_tail) only when the trace target is enabled. The
  // M11 fix that wrote to the log ring directly stays — under heavy
  // traffic the writer's mailbox cap can drop entries, ETS bypasses.
  case trace_filter_is_on() {
    False -> Nil
    True -> {
      ring.insert(line, Debug)
      log.at_with_fields(target, Debug, "lsp wire", fields)
    }
  }
}

fn build_entry(fields: List(#(String, String))) -> LogEntry {
  let cid = case cid_get_ffi() {
    Ok(id) -> id
    Error(_) -> ""
  }
  LogEntry(
    timestamp_ms: now_ms(),
    level: Debug,
    target: target,
    correlation_id: cid,
    message: "lsp wire",
    fields: fields,
  )
}

@external(erlang, "pharos_runtime_ffi", "trace_filter_cache_is_on")
fn trace_filter_is_on() -> Bool

@external(erlang, "pharos_log_ffi", "render_trace_body")
fn render_bytes(bytes: BitArray) -> String
