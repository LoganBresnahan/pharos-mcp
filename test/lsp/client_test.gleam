//// Tests for `llm_lsp_mcp/lsp/client`.
////
//// Round-trip framed messages through `cat` as a stand-in subprocess.
//// `cat` echoes whatever bytes we write, so framed-in equals
//// framed-out from cat's perspective and the framing parser on the
//// receive side recovers our original body.

import gleam/bit_array
import gleeunit/should
import llm_lsp_mcp/lsp/client

pub fn round_trip_one_body_through_cat_test() {
  let assert Ok(c) = client.start("/bin/cat", [], "/tmp")

  let body = bit_array.from_string("{\"jsonrpc\":\"2.0\",\"id\":1}")
  let assert Ok(Nil) = client.send_body(c, body)

  let assert Ok(#(received, _c2)) = client.next_message(c, 2000)
  received |> should.equal(body)

  client.close(c)
}

pub fn round_trip_two_bodies_drains_queue_test() {
  let assert Ok(c0) = client.start("/bin/cat", [], "/tmp")

  let body_a = bit_array.from_string("{\"id\":1}")
  let body_b = bit_array.from_string("{\"id\":2}")
  let assert Ok(Nil) = client.send_body(c0, body_a)
  let assert Ok(Nil) = client.send_body(c0, body_b)

  let assert Ok(#(first, c1)) = client.next_message(c0, 2000)
  let assert Ok(#(second, _c2)) = client.next_message(c1, 2000)

  first |> should.equal(body_a)
  second |> should.equal(body_b)

  client.close(c0)
}

pub fn next_message_times_out_when_nothing_sent_test() {
  let assert Ok(c) = client.start("/bin/cat", [], "/tmp")

  case client.next_message(c, 100) {
    Error(client.PortReceiveError(_)) -> Nil
    other -> {
      should.fail()
      let _ = other
      Nil
    }
  }

  client.close(c)
}
