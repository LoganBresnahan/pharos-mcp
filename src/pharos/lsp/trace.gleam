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
  // M10 emit-side prefilter. Without this short-circuit, every wire
  // chunk in BOTH directions casts an Emit message to the writer
  // actor, even when the trace target is silenced. A
  // parallel-issued runtime_trace_lsp + producer race left the very
  // first emit at the OLD filter (sync filter set in M9.5 closed the
  // in-actor race but not the at-emitter race). Reading the cache
  // here means producers see the new filter as soon as
  // `set_target_global` returns, with no mailbox-ordering dependency.
  case trace_filter_is_on() {
    False -> Nil
    True -> {
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
      // M11: write the trace line directly to the ring buffer instead
      // of relying solely on the writer actor's mailbox path. The
      // writer applies a producer-side mailbox-depth cap (defaults to
      // 1000) so under heavy LSP traffic, trace casts get coalesced
      // into a single `dropped=N` warn line — runtime_trace_lsp then
      // returns no actual wire entries. ETS inserts are lock-free and
      // bypass the cap, so the ring is the guaranteed capture.
      // `pharos/log/writer.fan_out` skips the ring for this target so
      // the entry is not double-inserted when the writer keeps up.
      let log_entry = build_entry(fields)
      let line = entry.render(log_entry)
      ring.insert(line, Debug)
      // Best-effort fan-out for stderr / file sinks. May still drop
      // at the mailbox cap; ring already has the entry.
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
