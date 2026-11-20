//// #39: stripping a generic type's parameters from a symbol name.

import gleeunit/should
import pharos/tools/symbols

pub fn type_params_are_stripped_test() {
  symbols.strip_type_params("Box<T>") |> should.equal("Box")
  symbols.strip_type_params("Pair<A, B>") |> should.equal("Pair")
  symbols.strip_type_params("<T> wrap") |> should.equal("wrap")
  symbols.strip_type_params("Sorted<T extends Comparable<T>>")
  |> should.equal("Sorted")
  symbols.strip_type_params("Plain") |> should.equal("Plain")
}

pub fn operator_names_keep_their_brackets_test() {
  symbols.strip_type_params("operator<=>") |> should.equal("operator<=>")
  symbols.strip_type_params("operator<") |> should.equal("operator<")
  symbols.strip_type_params("operator std::vector<int>")
  |> should.equal("operator std::vector<int>")
}
