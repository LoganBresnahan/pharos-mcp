//// #50: reading gopls's and rust-analyzer's method layouts.

import gleeunit/should
import pharos/tools/symbols

pub fn go_receivers_test() {
  symbols.go_receiver("(Box).Get") |> should.equal(Ok("Box"))
  symbols.go_receiver("(*Box).Put") |> should.equal(Ok("Box"))
  symbols.go_receiver("(Box[T]).Get") |> should.equal(Ok("Box"))
  symbols.go_receiver("Get") |> should.equal(Error(Nil))
  symbols.go_receiver("(Box)") |> should.equal(Error(Nil))
}

pub fn rust_impl_types_test() {
  symbols.rust_impl_type("impl Boxx<T>") |> should.equal(Ok("Boxx"))
  symbols.rust_impl_type("impl Tr<T> for Boxx<T>") |> should.equal(Ok("Boxx"))
  symbols.rust_impl_type("impl<K> Map<K> for a::b::Tree<K>")
  |> should.equal(Ok("Tree"))
  symbols.rust_impl_type("impl Display for &Wrapper")
  |> should.equal(Ok("Wrapper"))
  symbols.rust_impl_type("implement") |> should.equal(Error(Nil))
}
