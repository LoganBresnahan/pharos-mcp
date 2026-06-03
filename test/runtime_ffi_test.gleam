//// FFI shape tests for `pharos_runtime_ffi` (and a handful of
//// stdlib FFIs that pharos relies on directly). The goal is to
//// catch the failure class that hit us during M14: a Gleam
//// `@external` declares a return type the Erlang function never
//// actually produces, and the next pattern match against that
//// value crashes the calling process silently.
////
//// We exercise each FFI with safe inputs and assert the value
//// matches the Gleam-side type signature shape. Compile-time
//// already enforces argument types; this layer catches runtime
//// shape drift.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/list
import gleam/string
import gleeunit/should

// -- pharos_runtime_ffi: iolist_to_binary_safe ---------------------------
//
// The original `unicode:characters_to_binary` had a return shape mismatch
// that crashed pool when describe_dynamic was called on a non-trivial
// reason. iolist_to_binary_safe absorbs every documented return shape
// of that primitive: raw binary, {error, Bin, Rest}, {incomplete, ...}.

@external(erlang, "pharos_runtime_ffi", "iolist_to_binary_safe")
fn iolist_to_binary_safe(io: Dynamic) -> String

@external(erlang, "pharos_runtime_ffi", "as_dynamic")
fn as_dynamic(x: anything) -> Dynamic

pub fn iolist_safe_binary_input_test() {
  // Plain binary in → same binary out.
  let bin = "hello world"
  let out = iolist_to_binary_safe(as_dynamic(bin))
  should.equal(out, "hello world")
}

pub fn iolist_safe_charlist_input_test() {
  // Erlang charlist (list of codepoints) in → utf-8 binary out.
  // We round-trip through the FFI to guarantee no pattern crash.
  // `string_to_codepoint_list` returns the proper codepoint list
  // (not raw bytes) so `unicode:characters_to_binary` round-trips
  // utf-8 correctly.
  let charlist = string_to_codepoint_list("héllo")
  let out = iolist_to_binary_safe(charlist)
  should.equal(out, "héllo")
}

pub fn iolist_safe_iolist_input_test() {
  // Mixed iolist (the usual io_lib:format output): list of binaries
  // and codepoint integers. Must round-trip without crashing.
  let mixed = mixed_iolist()
  let out = iolist_to_binary_safe(mixed)
  // Length is non-zero — exact bytes depend on the iolist helper.
  let _ = out
  should.equal(string.length(out) > 0, True)
}

pub fn iolist_safe_garbage_input_test() {
  // Garbage in: an atom is not iolist-compatible. The shim catches
  // and returns the fallback sentinel; the caller process must not
  // crash.
  let garbage = wildcard_atom()
  let out = iolist_to_binary_safe(garbage)
  should.equal(out, "<unprintable>")
}

// -- pharos_runtime_ffi: safe_call_0 -------------------------------------
//
// try/catch wrapper around a zero-arg gleam closure. Catches `error`,
// `exit`, `throw` and returns Error(String) with a printable reason.
// On success returns Ok(closure_return).

@external(erlang, "pharos_runtime_ffi", "safe_call_0")
fn safe_call_0(closure: fn() -> a) -> Result(a, String)

pub fn safe_call_returns_ok_on_normal_return_test() {
  let result = safe_call_0(fn() { 42 })
  should.equal(result, Ok(42))
}

pub fn safe_call_catches_erlang_error_test() {
  // Division by zero (or any other erlang:error) must surface as
  // Error(_) rather than killing the test process.
  let result = safe_call_0(fn() { divide_by_zero() })
  case result {
    Error(reason) -> {
      // Reason is a printable binary, content not asserted —
      // the absence of a crash is the test.
      let _ = reason
      should.equal(string.length(reason) > 0, True)
    }
    Ok(_) -> should.fail()
  }
}

pub fn safe_call_catches_exit_test() {
  // Explicit erlang:exit call — should be caught.
  let result = safe_call_0(fn() { explicit_exit() })
  case result {
    Error(reason) -> {
      let _ = reason
      should.equal(string.length(reason) > 0, True)
    }
    Ok(_) -> should.fail()
  }
}

// -- pharos_runtime_ffi: self_mailbox_len --------------------------------
//
// Reports erlang:process_info(self(), message_queue_len). Must always
// return a non-negative Int; never raises.

@external(erlang, "pharos_runtime_ffi", "self_mailbox_len")
fn self_mailbox_len() -> Int

pub fn self_mailbox_len_returns_int_test() {
  let n = self_mailbox_len()
  // Test process generally has 0 messages waiting; assert non-
  // negative as a shape guard rather than an exact value.
  should.equal(n >= 0, True)
}

// -- pharos_runtime_ffi: pool_diag ---------------------------------------
//
// Returns a nested record. Verify that calling it doesn't crash even
// when pool isn't registered (returns sentinel values).

type PoolInfoRow {
  PoolInfoRow(
    pid: String,
    name: String,
    mailbox_len: Int,
    memory: Int,
    current_function: String,
    status: String,
  )
}

type TopProc {
  TopProc(
    pid: String,
    name: String,
    mailbox_len: Int,
    memory: Int,
    current_function: String,
  )
}

type SpawnerTrace {
  SpawnerTrace(pid: String, current_function: String, stack: String)
}

type PoolDiag {
  PoolDiag(
    pool: PoolInfoRow,
    top_mailboxes: List(TopProc),
    pool_state_dump: String,
    spawners: List(SpawnerTrace),
  )
}

@external(erlang, "pharos_runtime_ffi", "pool_diag")
fn pool_diag(top_n: Int) -> PoolDiag

pub fn pool_diag_shape_test() {
  // No pool registered in test context — pool_diag should still
  // return a well-typed PoolDiag with sentinel pool row. The
  // nested patterns below pull each inner record apart so the
  // shape contract is enforced one level deeper than the outer
  // PoolDiag destructure: any drift in the Erlang-side tuple
  // shape for `pool_info_row`, `top_proc`, or `spawner_trace`
  // shows up as a pattern-match failure here rather than as a
  // surprise at the call site of `runtime_lsp_state`.
  let d = pool_diag(5)
  let PoolDiag(
    pool: PoolInfoRow(pid: _, ..),
    top_mailboxes: top,
    pool_state_dump: dump,
    spawners: spawners,
  ) = d
  let _ = dump
  let _ =
    list.map(top, fn(t) {
      let TopProc(pid: _, ..) = t
      Nil
    })
  let _ =
    list.map(spawners, fn(s) {
      let SpawnerTrace(pid: _, ..) = s
      Nil
    })
}

// -- pharos_runtime_ffi: beam_version_info -------------------------------

type BeamInfo {
  BeamInfo(erts: String, otp_release: String, system_version: String)
}

@external(erlang, "pharos_runtime_ffi", "beam_version_info")
fn beam_version_info() -> Result(BeamInfo, Nil)

pub fn beam_version_info_shape_test() {
  case beam_version_info() {
    Ok(BeamInfo(erts: erts, otp_release: otp, system_version: sys)) -> {
      should.equal(string.length(erts) > 0, True)
      should.equal(string.length(otp) > 0, True)
      should.equal(string.length(sys) > 0, True)
    }
    Error(_) -> should.fail()
  }
}

// -- pharos_runtime_ffi: memory_breakdown --------------------------------

@external(erlang, "pharos_runtime_ffi", "memory_breakdown")
fn memory_breakdown() -> List(#(String, Int))

pub fn memory_breakdown_shape_test() {
  let entries = memory_breakdown()
  should.equal(entries != [], True)
  // First entry must be a 2-tuple of (binary, integer).
  case entries {
    [#(key, value), ..] -> {
      should.equal(string.length(key) > 0, True)
      should.equal(value >= 0, True)
    }
    [] -> should.fail()
  }
}

// -- pharos_runtime_ffi: pid_to_text + parse_pid round-trip --------------

@external(erlang, "pharos_runtime_ffi", "pid_to_text")
fn pid_to_text(pid: process.Pid) -> String

@external(erlang, "pharos_runtime_ffi", "parse_pid")
fn parse_pid(text: String) -> Result(process.Pid, Nil)

pub fn pid_text_round_trip_test() {
  let self_pid = process.self()
  let text = pid_to_text(self_pid)
  should.equal(string.starts_with(text, "<"), True)
  case parse_pid(text) {
    Ok(parsed) -> should.equal(parsed, self_pid)
    Error(_) -> should.fail()
  }
}

pub fn parse_pid_invalid_returns_error_test() {
  case parse_pid("not a pid") {
    Error(_) -> should.equal(1, 1)
    Ok(_) -> should.fail()
  }
}

// -- pharos_runtime_ffi: argv --------------------------------------------

@external(erlang, "pharos_runtime_ffi", "argv")
fn argv() -> List(String)

pub fn argv_returns_list_test() {
  let args = argv()
  // List of binaries — content not asserted (depends on how the
  // test runner invokes the BEAM), length non-negative.
  should.equal(list.length(args) >= 0, True)
}

// -- pharos_runtime_ffi: int_to_dynamic / as_dynamic --------------------

@external(erlang, "pharos_runtime_ffi", "int_to_dynamic")
fn int_to_dynamic(n: Int) -> Dynamic

pub fn int_to_dynamic_test() {
  let d = int_to_dynamic(42)
  let _ = d
  // No crash = pass; the value is opaque on the gleam side.
  should.equal(1, 1)
}

pub fn as_dynamic_passthrough_test() {
  // as_dynamic is an identity FFI used to widen any term to
  // Dynamic. Must not panic on any input shape — exercise a few.
  let _ = as_dynamic(42)
  let _ = as_dynamic("hello")
  let _ = as_dynamic([1, 2, 3])
  let _ = as_dynamic(Ok("nested"))
  should.equal(1, 1)
}

// -- pharos_runtime_ffi: pool_register / pool_lookup round-trip ----------
//
// Persistent-term backed Subject registry. We can't write a real
// pool Subject here (would require starting the pool); instead
// verify the round-trip when nothing is registered: lookup returns
// Error(Nil) without crashing.

@external(erlang, "pharos_runtime_ffi", "pool_lookup")
fn pool_lookup() -> Result(Dynamic, Nil)

pub fn pool_lookup_handles_absent_test() {
  // Either Ok(subject) (if a pool is already registered globally
  // when tests run) or Error(Nil). Either is well-typed; the
  // shape contract is what we verify.
  case pool_lookup() {
    Ok(_) | Error(_) -> should.equal(1, 1)
  }
}

// -- pharos_runtime_ffi: wildcard ----------------------------------------

@external(erlang, "pharos_runtime_ffi", "wildcard")
fn wildcard() -> Dynamic

pub fn wildcard_returns_atom_test() {
  let w = wildcard()
  let _ = w
  // Used as the underscore-atom for trace patterns. Calling it
  // here verifies it doesn't crash; the value is opaque.
  should.equal(1, 1)
}

// -- support helpers (test-local FFIs) -----------------------------------

@external(erlang, "pharos_runtime_ffi_test_support", "string_to_codepoint_list")
fn string_to_codepoint_list(s: String) -> Dynamic

@external(erlang, "pharos_runtime_ffi_test_support", "mixed_iolist")
fn mixed_iolist() -> Dynamic

@external(erlang, "pharos_runtime_ffi_test_support", "divide_by_zero")
fn divide_by_zero() -> Int

@external(erlang, "pharos_runtime_ffi_test_support", "explicit_exit")
fn explicit_exit() -> Int

@external(erlang, "pharos_runtime_ffi", "wildcard")
fn wildcard_atom() -> Dynamic

// -- Burrito cache path FFI (v0.1.2 fix) ---------------------------------
//
// Pin the path-shape contract burrito_cache_root/0 + list_pharos_extracts/0
// must satisfy. The pre-v0.1.2 FFI used filename:basedir(user_cache, ...)
// joined with "burrito_runtime/_/pharos" — a path Burrito never creates.
// These tests fail loudly if anyone reintroduces that bug class.

@external(erlang, "pharos_runtime_ffi", "burrito_cache_root")
fn burrito_cache_root() -> String

@external(erlang, "pharos_runtime_ffi", "list_pharos_extracts")
fn list_pharos_extracts() -> List(String)

@external(erlang, "pharos_fs_ffi", "setenv")
fn setenv(key: String, value: String) -> Nil

@external(erlang, "pharos_fs_ffi", "mkdir_p")
fn mkdir_p(path: String) -> Result(Nil, String)

@external(erlang, "pharos_fs_ffi", "rm_rf")
fn rm_rf(path: String) -> Result(Nil, String)

@external(erlang, "pharos_fs_ffi", "atomic_write_text")
fn atomic_write_text(path: String, text: String) -> Result(Nil, String)

pub fn burrito_cache_root_shape_test() {
  // Must end with ".burrito" and must never reference the old buggy
  // segments anywhere in the path.
  let path = burrito_cache_root()
  string.ends_with(path, ".burrito") |> should.be_true
  string.contains(path, "burrito_runtime") |> should.be_false
  string.contains(path, "_/pharos") |> should.be_false
  string.contains(path, ".cache/.burrito") |> should.be_false
}

pub fn burrito_cache_root_honors_pharos_install_dir_test() {
  // Override should win unconditionally.
  setenv("PHAROS_INSTALL_DIR", "/tmp/pharos-test-override")
  let path = burrito_cache_root()
  should.equal(path, "/tmp/pharos-test-override/.burrito")
  // Empty-string env should fall back to default (same semantics as
  // unset, per the FFI's contract).
  setenv("PHAROS_INSTALL_DIR", "")
  let default_path = burrito_cache_root()
  string.contains(default_path, "/tmp/pharos-test-override") |> should.be_false
  string.ends_with(default_path, ".burrito") |> should.be_true
}

pub fn list_pharos_extracts_missing_root_test() {
  // Point at a path that does not exist; expect empty list, no crash.
  setenv("PHAROS_INSTALL_DIR", "/tmp/pharos-test-does-not-exist-xyz")
  let extracts = list_pharos_extracts()
  should.equal(list.length(extracts), 0)
  setenv("PHAROS_INSTALL_DIR", "")
}

pub fn list_pharos_extracts_filters_test() {
  // Stage a scratch .burrito root with two pharos_* dirs, one sibling
  // app dir, and one stray regular file. Confirm list_pharos_extracts
  // returns only the two pharos_* directories.
  let scratch_root = "/tmp/pharos-test-list-filter"
  let burrito_dir = scratch_root <> "/.burrito"
  let _ = rm_rf(scratch_root)
  let assert Ok(_) = mkdir_p(burrito_dir <> "/pharos_erts-16.1_0.1.2")
  let assert Ok(_) = mkdir_p(burrito_dir <> "/pharos_erts-16.1_0.1.1")
  let assert Ok(_) = mkdir_p(burrito_dir <> "/next_ls_erts-15.2_0.23.4")
  let assert Ok(_) = atomic_write_text(burrito_dir <> "/stray.txt", "")

  setenv("PHAROS_INSTALL_DIR", scratch_root)
  let extracts = list_pharos_extracts()
  should.equal(list.length(extracts), 2)
  list.each(extracts, fn(p) {
    string.starts_with(p, burrito_dir <> "/pharos_") |> should.be_true
  })

  setenv("PHAROS_INSTALL_DIR", "")
  let _ = rm_rf(scratch_root)
}

