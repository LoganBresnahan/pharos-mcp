//// Pure pieces of the shared daemon (ADR-034): argv parsing, the pid
//// file beside the socket, and NDJSON line framing. The socket, hello
//// and session lifecycle are driven end to end by the daemon
//// integration tests.

import gleam/bit_array
import gleam/erlang/charlist
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import pharos/cli
import pharos/daemon
import pharos/env

@external(erlang, "pharos_daemon_ffi", "split_lines")
fn split_lines_ffi(
  pending: #(List(BitArray), Int),
  data: BitArray,
) -> #(List(String), #(List(BitArray), Int))

/// Feed `chunks` one read at a time; return every line and the
/// still-pending bytes.
fn split_lines(chunks: List(BitArray)) -> #(List(String), BitArray) {
  let #(lines, pending) =
    list.fold(chunks, #([], #([], 0)), fn(acc, chunk) {
      let #(lines, pending) = acc
      let #(new, pending) = split_lines_ffi(pending, chunk)
      #(list.append(lines, new), pending)
    })
  let #(parts, _) = pending
  #(lines, bit_array.concat(list.reverse(parts)))
}

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
  split_lines([<<"{\"a\":1}\n{\"b\"":utf8>>, <<":2}\n{\"c\"":utf8>>])
  |> should.equal(#(["{\"a\":1}", "{\"b\":2}"], <<"{\"c\"":utf8>>))
}

pub fn split_lines_strips_crlf_test() {
  split_lines([<<"one\r\ntwo\n":utf8>>])
  |> should.equal(#(["one", "two"], <<>>))
}

pub fn split_lines_with_no_newline_buffers_everything_test() {
  split_lines([<<"par":utf8>>, <<"tial":utf8>>])
  |> should.equal(#([], <<"partial":utf8>>))
}

pub fn split_lines_joins_a_line_spread_over_many_reads_test() {
  split_lines([<<"a":utf8>>, <<"b":utf8>>, <<"c\nd":utf8>>, <<"e\n":utf8>>])
  |> should.equal(#(["abc", "de"], <<>>))
}

pub fn split_lines_counts_pending_bytes_test() {
  let #(_, #(_, bytes)) =
    split_lines_ffi(#([<<"abc":utf8>>], 3), <<"defg":utf8>>)
  bytes
  |> should.equal(7)
}

@external(erlang, "pharos_fs_ffi", "setenv")
fn setenv(key: String, value: String) -> Nil

@external(erlang, "os", "unsetenv")
fn os_unsetenv(key: charlist.Charlist) -> Bool

fn unsetenv(key: String) -> Nil {
  let _ = os_unsetenv(charlist.from_string(key))
  Nil
}

@external(erlang, "pharos_fs_ffi", "shell")
fn shell(cmd: String) -> String

pub fn doctor_reports_the_last_fallbacks_test() {
  let dir = "/tmp/pharos-fallbacks-test-" <> shell("printf %s $$")
  let _ = shell("rm -rf " <> dir <> " && mkdir -p " <> dir <> "/pharos/log")
  let _ =
    shell("printf 'a\\nb\\nc\\n' > " <> dir <> "/pharos/log/fallbacks.log")
  let previous = env.get("XDG_STATE_HOME")
  setenv("XDG_STATE_HOME", dir)
  let lines = cli.recent_fallbacks(2)
  case previous {
    Some(value) -> setenv("XDG_STATE_HOME", value)
    None -> unsetenv("XDG_STATE_HOME")
  }
  let _ = shell("rm -rf " <> dir)
  lines
  |> should.equal(["b", "c"])
}
