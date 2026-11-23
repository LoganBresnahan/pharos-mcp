//// Polish 6: a config file's warnings are logged once per content and
//// log-writer state, even when two checks run at the same moment (the
//// boot recheck and the first session's; an integration run logged one
//// twice).

import gleam/erlang/process
import gleam/list
import gleeunit/should
import pharos/config

@external(erlang, "pharos_runtime_ffi", "first_config_check")
fn first_config_check(path: String, bytes: BitArray, writer_up: Bool) -> Bool

pub fn concurrent_checks_warn_once_test() {
  config.checks_init()
  let results = process.new_subject()
  let bytes = <<"concurrent_checks_warn_once_test">>
  list.repeat(Nil, 50)
  |> list.each(fn(_) {
    process.spawn(fn() {
      process.send(results, first_config_check("/x/pharos.toml", bytes, True))
    })
  })
  list.repeat(Nil, 50)
  |> list.map(fn(_) {
    let assert Ok(first) = process.receive(results, 5000)
    first
  })
  |> list.filter(fn(first) { first })
  |> list.length
  |> should.equal(1)
}
