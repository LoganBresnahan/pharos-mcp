//// #39: stripping a generic type's parameters from a symbol name.

import gleam/list
import gleam/option.{None}
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

fn at(name: String, kind: Int, from: Int, to: Int, via: String) {
  let range = symbols.Range(symbols.Position(from, 0), symbols.Position(to, 0))
  symbols.SymbolMatch(
    name: name,
    kind: kind,
    uri: "file:///a.cpp",
    range: range,
    selection_range: range,
    full_path: [name],
    detail: None,
    matched_via: via,
    body_hash: "",
  )
}

pub fn an_exact_name_outranks_a_stripped_one_test() {
  [
    at("Pair<int, int>", 5, 10, 20, "exact"),
    at("Pair", 5, 0, 8, "type_params_strip"),
  ]
  |> symbols.exact_outranks_stripped
  |> list.map(fn(m) { m.name })
  |> should.equal(["Pair<int, int>"])
  // No exact match: the stripped ones are the answer.
  [at("Box<T>", 5, 0, 8, "type_params_strip")]
  |> symbols.exact_outranks_stripped
  |> list.length
  |> should.equal(1)
}

pub fn a_specializations_constructor_goes_with_the_class_test() {
  // clangd: the template `Pair` (0-8), and the specialization's
  // constructor `Pair` inside `Pair<int, int>` (10-20), outside it.
  [at("Pair", 5, 0, 8, "exact"), at("Pair", 9, 12, 13, "exact")]
  |> symbols.drop_own_constructors
  |> list.map(fn(m) { m.kind })
  |> should.equal([5])
  // Asked for the constructor alone (`Pair/Pair`): it stays.
  [at("Pair", 9, 12, 13, "exact")]
  |> symbols.drop_own_constructors
  |> list.length
  |> should.equal(1)
}
