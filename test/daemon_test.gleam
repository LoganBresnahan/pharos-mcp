//// Pure pieces of the shared daemon (ADR-034): argv parsing, the pid
//// file beside the socket, and NDJSON line framing. The socket, hello
//// and session lifecycle are driven end to end by the daemon
//// integration tests.

import gleam/option.{None, Some}
import gleeunit/should
import pharos/daemon

@external(erlang, "pharos_daemon_ffi", "split_lines")
fn split_lines(buffer: BitArray, data: BitArray) -> #(List(String), BitArray)

pub fn parse_args_reads_socket_build_and_key_test() {
  daemon.parse_args([
    "daemon", "--socket", "/run/user/1/pharos/b-k.sock", "--build", "b", "--key",
    "k",
  ])
  |> should.equal(
    Some(daemon.Args(
      socket: "/run/user/1/pharos/b-k.sock",
      build: "b",
      key: "k",
    )),
  )
}

pub fn parse_args_defaults_the_key_test() {
  daemon.parse_args(["daemon", "--build", "b", "--socket", "/s.sock"])
  |> should.equal(Some(daemon.Args(socket: "/s.sock", build: "b", key: "0")))
}

pub fn parse_args_needs_socket_and_build_test() {
  daemon.parse_args(["daemon", "--socket", "/s.sock"])
  |> should.equal(None)
  daemon.parse_args(["--version"])
  |> should.equal(None)
  daemon.parse_args([])
  |> should.equal(None)
}

pub fn pid_file_sits_beside_the_socket_test() {
  daemon.pid_path("/run/user/1/pharos/abc-0.sock")
  |> should.equal("/run/user/1/pharos/abc-0.pid")
}

pub fn split_lines_keeps_the_unterminated_tail_test() {
  split_lines(<<"{\"a\":1}\n{\"b\"":utf8>>, <<":2}\n{\"c\"":utf8>>)
  |> should.equal(#(["{\"a\":1}", "{\"b\":2}"], <<"{\"c\"":utf8>>))
}

pub fn split_lines_strips_crlf_test() {
  split_lines(<<>>, <<"one\r\ntwo\n":utf8>>)
  |> should.equal(#(["one", "two"], <<>>))
}

pub fn split_lines_with_no_newline_buffers_everything_test() {
  split_lines(<<"par":utf8>>, <<"tial":utf8>>)
  |> should.equal(#([], <<"partial":utf8>>))
}
