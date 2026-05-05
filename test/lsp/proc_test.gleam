//// Tests for `pharos/lsp/proc` Phase B/C surface that does not
//// require an LSP subprocess.
////
//// Real LSP-driven tests live in dogfood (rebuilt Burrito binary
//// run against the *_dev/ workspaces). Here we verify the proc
//// module's helpers compile + behave for inputs that do not need
//// a live Port.

import gleeunit/should
import pharos/lsp/proc

/// `proc.cancel` constructs a `$/cancelRequest` body internally and
/// dispatches via `send_notification`. We can't exercise the wire
/// path without a Proc, but the public API exists at a stable name.
/// This test guards against accidental rename / removal — the type
/// signature is asserted by the compiler.
pub fn cancel_function_exists_test() {
  // Function reference takes a Proc + Int; just naming it forces
  // the compiler to verify the signature. The empty assertion
  // keeps gleeunit happy.
  let _ = proc.cancel
  should.equal(1, 1)
}
