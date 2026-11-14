//// term: Erlang terms built from Gleam, and their external term format.
////
//// A frame of the to-silica TCP transport contract is one ETF term (T4.2). The
//// values are built with `gleam/dynamic` (integers, binaries, booleans, lists,
//// tuples, maps); this module adds the two things the standard library has no
//// function for: atoms, and `term_to_binary` / `binary_to_term`. Each is an
//// external to one of OTP's own functions; there is no hand-written Erlang.

import gleam/dynamic.{type Dynamic}
import gleam/list

/// An atom. Atoms appear on the wire only where the contract writes one
/// (tags, record keys, enumerated values); identifiers are binaries (T4.4).
@external(erlang, "erlang", "binary_to_atom")
pub fn atom(name: String) -> Dynamic

/// A contract record: a map with atom keys (T4.5).
pub fn record(fields: List(#(String, Dynamic))) -> Dynamic {
  dynamic.properties(list.map(fields, fn(field) { #(atom(field.0), field.1) }))
}

/// A tagged tuple: the atom tag first, then the fields (T4.6).
pub fn tagged(tag: String, fields: List(Dynamic)) -> Dynamic {
  dynamic.array([atom(tag), ..fields])
}

/// A list of integers, as the contract's index lists are.
pub fn ints(values: List(Int)) -> Dynamic {
  dynamic.list(list.map(values, dynamic.int))
}

/// A list of binaries.
pub fn strings(values: List(String)) -> Dynamic {
  dynamic.list(list.map(values, dynamic.string))
}

/// `term_to_binary/1` with no options, as T4.2 asks.
@external(erlang, "erlang", "term_to_binary")
pub fn encode(term: Dynamic) -> BitArray

/// `binary_to_term/1`. Used only on the transpiler's replies.
@external(erlang, "erlang", "binary_to_term")
pub fn decode(bytes: BitArray) -> Dynamic

/// True when the value is an atom.
@external(erlang, "erlang", "is_atom")
pub fn is_atom(value: Dynamic) -> Bool

/// The name of an atom. Call only when `is_atom` is true.
@external(erlang, "erlang", "atom_to_binary")
pub fn atom_name(value: Dynamic) -> String
