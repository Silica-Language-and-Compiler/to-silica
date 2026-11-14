//// names: how this sender spells every name it puts in a frame. The three
//// proofs of concept (Erlang, Elixir, Gleam) use the same five rules, so that
//// units of several languages can share one session.
////
////   N1  silica_unit   prefix + the module path, each segment in snake_case,
////                     joined by `_`                       my/mod -> gl_my_mod
////   N2  unit_name and the module of a call or a function reference: the
////                     module as the user writes it (T5.2)        gleam/int
////   N3  type names    <N1 without the prefix>_<snake_case of the type>:
////                     type Tally of module actors -> actors_tally. Used for
////                     a type form's name, `t_named` and a record node.
////   N4  function, variable and field names: the source spelling through
////                     `ident`, which is injective. A Gleam name changes
////                     only if it has `__` in it. Names this codex makes up
////                     for functions end in `__g<n>`, which `ident` never
////                     writes.
////   N5  symbols       the atom's text at run time on the BEAM: for Gleam the
////                     constructor in snake_case, as Gleam's Erlang backend
////                     writes it (Ok -> ok, StopAbnormal -> stop_abnormal)
////
//// The contract asks only that `silica_unit` is an identifier with the
//// prefix (T5.2). The rest is this sender's decision (contract 1, "what you
//// own"); to change a rule, change it here.

import gleam/int
import gleam/list
import gleam/string

/// N1: the Silica unit a module asks for.
pub fn silica_unit(prefix: String, module: String) -> String {
  prefix <> module_ident(module)
}

/// The module part of N1 and N3: `my/mod` -> `my_mod`.
pub fn module_ident(module: String) -> String {
  module
  |> string.split("/")
  |> list.map(snake)
  |> string.join("_")
  |> plain
}

/// N3: the session-wide name of a type declared in a module.
pub fn type_name(module: String, name: String) -> String {
  module_ident(module) <> "_" <> plain(snake(name))
}

/// N5: the symbol of a Gleam constructor.
pub fn symbol(constructor: String) -> String {
  snake(constructor)
}

/// N4: a function, variable or field name. The rule is injective (two
/// source names never give the same spelling) and the same in the Erlang,
/// Elixir and Gleam senders. The source name is read left to right:
///
///   a letter or digit   is kept
///   `?`                 is `__q`
///   `!`                 is `__b`
///   `_`                 is kept when the character before it is not `_` and
///                       the character after it (if any) is neither `_` nor
///                       a character that is escaped; otherwise `__x5f_`
///   any other character is `__x<lowercase hex code point>_`
///
/// An empty name is `__e`, and a digit in first place is escaped
/// (`__x31_` for `1`). So an escape always starts with `__`, and a decoder
/// reading left to right gives the source name back (the tests have one).
/// Gleam has one arity for each function name, so no arity is written into
/// a name. A Gleam name changes only if it has two underscores in a row.
pub fn ident(text: String) -> String {
  let codes =
    list.map(string.to_utf_codepoints(text), string.utf_codepoint_to_int)
  case codes {
    [] -> "__e"
    [first, ..rest] ->
      case is_digit(first) {
        True -> escape(first) <> ident_loop(rest, first, [])
        False -> ident_loop(codes, -1, [])
      }
  }
}

fn ident_loop(codes: List(Int), previous: Int, done: List(String)) -> String {
  case codes {
    [] -> string.concat(list.reverse(done))
    [code, ..rest] -> {
      let written = case code {
        95 -> {
          let next_allows = case rest {
            [] -> True
            [next, ..] -> is_kept(next)
          }
          case previous != 95 && next_allows {
            True -> "_"
            False -> escape(95)
          }
        }
        63 -> "__q"
        33 -> "__b"
        _ ->
          case is_kept(code) {
            True -> {
              let assert Ok(codepoint) = string.utf_codepoint(code)
              string.from_utf_codepoints([codepoint])
            }
            False -> escape(code)
          }
      }
      ident_loop(rest, code, [written, ..done])
    }
  }
}

/// A character N4 writes as itself wherever it stands.
fn is_kept(code: Int) -> Bool {
  is_lower(code) || is_upper(code) || is_digit(code)
}

fn escape(code: Int) -> String {
  "__x" <> string.lowercase(int.to_base16(code)) <> "_"
}

/// The spelling of N1 and N3 (unit and type names), which are not N4 names:
/// letters, digits and `_` are kept, `?` is `_q`, `!` is `_b`, any other
/// character is `_x<hex code point>_`; a result that is empty or starts with
/// a digit gets `_` in front.
fn plain(text: String) -> String {
  let mapped =
    string.to_utf_codepoints(text)
    |> list.map(fn(codepoint) {
      let code = string.utf_codepoint_to_int(codepoint)
      case is_kept(code) || code == 95 {
        True -> string.from_utf_codepoints([codepoint])
        False ->
          case code {
            63 -> "_q"
            33 -> "_b"
            _ -> "_x" <> string.lowercase(int.to_base16(code)) <> "_"
          }
      }
    })
    |> string.concat
  case string.to_utf_codepoints(mapped) {
    [] -> "_"
    [first, ..] ->
      case is_digit(string.utf_codepoint_to_int(first)) {
        True -> "_" <> mapped
        False -> mapped
      }
  }
}

/// The suffix of every function name this codex makes up. `__g` is never
/// written by `ident` (after `__` it writes only `q`, `b`, `x` or `e`), so
/// such a name cannot be the spelling of a source name.
pub const generated = "__g"

/// snake_case: `_` goes between a lowercase letter or digit and an uppercase
/// letter, and between an uppercase letter and an uppercase letter followed
/// by a lowercase one; then everything is lowercased.
/// `HTTPServer` -> `http_server`.
pub fn snake(text: String) -> String {
  let codes =
    list.map(string.to_utf_codepoints(text), string.utf_codepoint_to_int)
  snake_loop(codes, -1, [])
  |> list.reverse
  |> string.concat
  |> string.lowercase
}

fn snake_loop(
  codes: List(Int),
  previous: Int,
  done: List(String),
) -> List(String) {
  case codes {
    [] -> done
    [code, ..rest] -> {
      let next_is_lower = case rest {
        [next, ..] -> is_lower(next)
        [] -> False
      }
      let boundary =
        is_upper(code)
        && {
          is_lower(previous)
          || is_digit(previous)
          || { is_upper(previous) && next_is_lower }
        }
      let assert Ok(codepoint) = string.utf_codepoint(code)
      let text = string.from_utf_codepoints([codepoint])
      case boundary {
        True -> snake_loop(rest, code, [text, "_", ..done])
        False -> snake_loop(rest, code, [text, ..done])
      }
    }
  }
}

fn is_lower(code: Int) -> Bool {
  code >= 97 && code <= 122
}

fn is_upper(code: Int) -> Bool {
  code >= 65 && code <= 90
}

fn is_digit(code: Int) -> Bool {
  code >= 48 && code <= 57
}
