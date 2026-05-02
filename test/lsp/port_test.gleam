//// Tests for `llm_lsp_mcp/lsp/port`.
////
//// The Port FFI wraps an Erlang `port()` connected to a subprocess.
//// Verifying it requires actually spawning a subprocess; pure unit
//// testing is not meaningful for this layer (the FFI is mostly a
//// passthrough to BEAM primitives).
////
//// We use `cat` as a trivial stand-in for a real LSP. `cat` reads
//// stdin and writes the same bytes to stdout, which is enough to
//// exercise spawn / send / receive / close end-to-end. Tests are
//// gated on `cat` being on the test runner's PATH; both Linux and
//// macOS GitHub runners ship coreutils, so this is reliable.

import gleam/bit_array
import gleeunit/should
import llm_lsp_mcp/lsp/port

pub fn spawn_send_receive_close_roundtrip_test() {
  let assert Ok(p) = port.spawn("/bin/cat", [], "/tmp")

  let payload = bit_array.from_string("hello, lsp port\n")
  let assert Ok(Nil) = port.send(p, payload)

  let assert Ok(echoed) = port.receive_data(p, 2000)
  echoed |> should.equal(payload)

  port.close(p)
}

pub fn receive_data_times_out_when_subprocess_is_silent_test() {
  let assert Ok(p) = port.spawn("/bin/cat", [], "/tmp")

  // We never send anything, so cat has nothing to echo. The receive
  // call should report Timeout, not block forever.
  case port.receive_data(p, 100) {
    Error(port.Timeout) -> Nil
    other -> {
      should.fail()
      let _ = other
      Nil
    }
  }

  port.close(p)
}

pub fn spawning_a_nonexistent_binary_returns_error_test() {
  // Burrito-supported platforms all reject this path; the FFI catches
  // the error from open_port and returns a SpawnFailed instead of
  // panicking.
  case port.spawn("/definitely/not/a/real/binary", [], "/tmp") {
    Error(port.SpawnFailed(_)) -> Nil
    other -> {
      should.fail()
      let _ = other
      Nil
    }
  }
}
