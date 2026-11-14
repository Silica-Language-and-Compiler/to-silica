//// types: the types this codex works out, and how they are written into a
//// form's type table (contract 8.5, 8.6).
////
//// Contract 8.6 (T8.8): the language side decides every type. glance gives
//// syntax and no types, so the codex has its own typing pass (in `codex`),
//// and this module holds what that pass is made of:
////
////   Ty          a Gleam type as the codex knows it. `TyUnknown(why)` is a
////               type the codex could not work out, with the reason in
////               words; the codex turns it into a gap wherever the contract
////               requires a type (T8.10).
////   resolve     an annotation of the source (glance's `Type`) as a `Ty`.
////   bind, fill  how the result type of a call to a function with type
////               variables is found from its arguments.
////   Table       a form's type table, each entry written once (`intern`).
////   library_signature  the functions of other modules whose types the
////               codex knows.
////
//// To teach the codex a type of another module: add a variant to `Ty`, a
//// case to `library` (annotation -> Ty) and a case to `intern` (Ty -> the
//// entries that describe the value the codex sends for it).

import glance as g
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam_to_silica_poc/frame.{type TypeNode}
import gleam_to_silica_poc/names

pub type Ty {
  TyInt
  TyFloat
  TyBool
  TyString
  TyBits
  /// Gleam's Nil, which travels as the symbol `nil` (N5).
  TyNil
  /// A value that is always one of these symbols.
  TyAtoms(names: List(String))
  TyTuple(elems: List(Ty))
  TyFn(params: List(Ty), result: Ty)
  TyList(elem: Ty)
  /// A custom type of the module being sent, by its Gleam name.
  TyNamed(name: String, args: List(Ty))
  /// The prelude's Result.
  TyResult(ok: Ty, error: Ty)
  /// gleam/erlang/process: Subject(message), lowered to its owner's process.
  TySubject(message: Ty)
  /// gleam/erlang/process: Pid.
  TyPid
  /// gleam/erlang/process: Name(message), where the unit makes exactly one
  /// name for that message type (`Resolver.names`): `name` is its literal.
  /// It travels as the symbol of that literal.
  TyName(message: Ty, name: String)
  /// The value of `process.named_subject(name)`: the same symbol. A send to
  /// it is a send to the registered name (contract T9.14c); it is no
  /// process, so it cannot stand where a `Subject` is expected.
  TyNamedSubject(message: Ty, name: String)
  /// A tuple with a symbol first, stated as such: the pattern of a receive
  /// clause, and a message sent under the tag this sender makes for its type
  /// (`message_tag`; contract T9.12).
  TyTagged(tag: String, elems: List(Ty))
  /// gleam/otp/actor: Next(state, message).
  TyNext(state: Ty, message: Ty)
  /// gleam/otp/actor: Started(data).
  TyStarted(data: Ty)
  /// gleam/otp/actor: StartError.
  TyStartError
  /// A type variable of the enclosing function or type.
  TyVar(name: String)
  /// A value Gleam itself knows nothing about: a type of the module without
  /// constructors (an external type), or `Dynamic`.
  TyDynamic
  /// The type of `panic`: no value, so it fits anywhere (H26).
  TyNever
  /// Not known to this codex. `why` says what is missing, for a gap's note.
  TyUnknown(why: String)
}

/// What `resolve` needs to know about the module.
pub type Resolver {
  Resolver(
    /// The module's custom types that are sent as type forms.
    declared: List(String),
    /// The module's custom types without constructors (external types).
    external: List(String),
    /// The module's custom types that cannot be sent, with the reason.
    unsendable: Dict(String, String),
    aliases: List(String),
    /// The module's type aliases without parameters, and what each names.
    alias_types: Dict(String, g.Type),
    /// The module's external types that are processes: the result type of
    /// its external to erlang:self/0 or erlang:spawn/1.
    processes: List(String),
    /// Import alias -> module name.
    imports: Dict(String, String),
    /// Unqualified imported type -> module name.
    imported_types: Dict(String, String),
    /// The registered names the unit makes, by message type: the literal of
    /// the one `let n: Name(M) = process.new_name("literal")` for each `M`
    /// (contract T9.14b: a static child's name is a literal).
    names: List(#(Ty, String)),
  )
}

/// An annotation of the source as a type.
pub fn resolve(annotation: g.Type, r: Resolver) -> Ty {
  let all = fn(types) { list.map(types, resolve(_, r)) }
  case annotation {
    g.NamedType(name: "Int", module: None, ..) -> TyInt
    g.NamedType(name: "Float", module: None, ..) -> TyFloat
    g.NamedType(name: "Bool", module: None, ..) -> TyBool
    g.NamedType(name: "String", module: None, ..) -> TyString
    g.NamedType(name: "BitArray", module: None, ..) -> TyBits
    g.NamedType(name: "Nil", module: None, ..) -> TyNil
    g.NamedType(name:, module: None, parameters:, ..) ->
      case
        list.contains(r.declared, name),
        list.contains(r.external, name),
        dict.get(r.unsendable, name)
      {
        True, _, _ -> TyNamed(name, all(parameters))
        _, True, _ ->
          case list.contains(r.processes, name) {
            True -> TyPid
            False -> TyDynamic
          }
        _, _, Ok(why) -> TyUnknown(why)
        _, _, _ ->
          case
            dict.get(r.alias_types, name),
            list.contains(r.aliases, name),
            dict.get(r.imported_types, name)
          {
            // A type alias is another name for the type it names.
            Ok(aliased), _, _ -> resolve(aliased, r)
            _, True, _ ->
              TyUnknown(
                "the type alias " <> name <> " is not translated by this codex",
              )
            _, False, Ok(module) -> library(module, name, all(parameters), r)
            // The prelude: List and Result.
            _, False, Error(Nil) -> library("gleam", name, all(parameters), r)
          }
      }
    g.NamedType(name:, module: Some(alias), parameters:, ..) ->
      case dict.get(r.imports, alias) {
        Ok(module) -> library(module, name, all(parameters), r)
        Error(Nil) ->
          TyUnknown(
            "the type "
            <> alias
            <> "."
            <> name
            <> " names a module this file does not import",
          )
      }
    g.TupleType(elements:, ..) -> TyTuple(all(elements))
    g.FunctionType(parameters:, return:, ..) ->
      TyFn(all(parameters), resolve(return, r))
    g.VariableType(name:, ..) -> TyVar(name)
    g.HoleType(..) ->
      TyUnknown(
        "a type hole `_` is left to the Gleam compiler's inference, which this codex does not have",
      )
  }
}

/// The types of the prelude, `gleam_erlang` and `gleam_otp` the codex has an
/// entry for. Every other type of another module is not known.
fn library(
  module: String,
  name: String,
  parameters: List(Ty),
  r: Resolver,
) -> Ty {
  case module, name, parameters {
    // A name is a literal in the output (contract T9.14b, T9.14c), so the
    // type is known only when the unit makes one name for the message type.
    "gleam/erlang/process", "Name", [message] ->
      case list.key_find(r.names, message) {
        Ok(literal) -> TyName(message, literal)
        Error(Nil) -> TyUnknown(no_name)
      }
    "gleam", "List", [elem] -> TyList(elem)
    "gleam", "Result", [ok, error] -> TyResult(ok, error)
    "gleam/dynamic", "Dynamic", [] -> TyDynamic
    "gleam/erlang/process", "Subject", [message] -> TySubject(message)
    "gleam/erlang/process", "Pid", [] -> TyPid
    "gleam/otp/actor", "Next", [state, message] -> TyNext(state, message)
    "gleam/otp/actor", "Started", [data] -> TyStarted(data)
    "gleam/otp/actor", "StartError", [] -> TyStartError
    // StartResult(data) = Result(Started(data), StartError).
    "gleam/otp/actor", "StartResult", [data] ->
      TyResult(TyStarted(data), TyStartError)
    "gleam", _, _ ->
      TyUnknown("the type " <> name <> " is not known to this codex")
    _, _, _ ->
      TyUnknown(
        "the type "
        <> module
        <> "."
        <> name
        <> " is declared in another module, and this codex has no entry for it",
      )
  }
}

/// Why a `process.Name(message)` has no type: the rule the source missed.
pub const no_name =
  "a process.Name is a literal in the output (contract T9.14b, T9.14c), and this unit does not make exactly one name for this message type, as a statement `let name: Name(Message) = process.new_name(\"literal\")` of a function body whose literal is an identifier (README, \"A static supervisor\")"

/// The types a type is made of.
pub fn parts(ty: Ty) -> List(Ty) {
  case ty {
    TyTuple(elems:) -> elems
    TyFn(params:, result:) -> list.append(params, [result])
    TyList(elem:) -> [elem]
    TyNamed(args:, ..) -> args
    TyResult(ok:, error:) -> [ok, error]
    TySubject(message:) -> [message]
    TyTagged(elems:, ..) -> elems
    TyNext(state:, message:) -> [state, message]
    TyStarted(data:) -> [data]
    _ -> []
  }
}

/// Why a type is not known: the reason of the first unknown part of it.
pub fn why(ty: Ty) -> Result(String, Nil) {
  case ty {
    TyUnknown(why:) -> Ok(why)
    _ -> list.find_map(parts(ty), why)
  }
}

/// True when every part of the type is known.
pub fn known(ty: Ty) -> Bool {
  why(ty) == Error(Nil)
}

fn has_never(ty: Ty) -> Bool {
  ty == TyNever || list.any(parts(ty), has_never)
}

fn has_var(ty: Ty) -> Bool {
  case ty {
    TyVar(..) -> True
    _ -> list.any(parts(ty), has_var)
  }
}

/// True when the type can be written into a type table: known, and a value.
pub fn stateable(ty: Ty) -> Bool {
  known(ty) && !has_never(ty)
}

/// True when the type can be used as it stands for another expression:
/// stateable, with no type variable in it.
pub fn closed(ty: Ty) -> Bool {
  stateable(ty) && !has_var(ty)
}

/// The reason a type cannot be stated, in words.
pub fn reason(ty: Ty) -> String {
  case why(ty), has_never(ty) {
    Ok(why), _ -> why
    Error(Nil), True -> "the expression never gives a value (panic)"
    Error(Nil), False -> "its type is not known to this codex"
  }
}

/// Finds what the type variables of `declared` stand for, given the type an
/// argument has. A variable that is already bound keeps its binding.
pub fn bind(
  declared: Ty,
  actual: Ty,
  bound: Dict(String, Ty),
) -> Dict(String, Ty) {
  case declared, stateable(actual) {
    TyVar(name:), True ->
      case dict.has_key(bound, name) {
        True -> bound
        False -> dict.insert(bound, name, actual)
      }
    _, _ -> {
      let declared_parts = parts(declared)
      let actual_parts = parts(actual)
      case
        declared_parts != []
        && list.length(declared_parts) == list.length(actual_parts)
      {
        True ->
          list.fold(
            list.zip(declared_parts, actual_parts),
            bound,
            fn(acc, pair) { bind(pair.0, pair.1, acc) },
          )
        False -> bound
      }
    }
  }
}

/// `declared` with its type variables replaced. A variable with no binding
/// is not known: `unbound` says why, given the variable's name.
pub fn fill(
  declared: Ty,
  bound: Dict(String, Ty),
  unbound: fn(String) -> String,
) -> Ty {
  let go = fill(_, bound, unbound)
  case declared {
    TyVar(name:) ->
      case dict.get(bound, name) {
        Ok(ty) -> ty
        Error(Nil) -> TyUnknown(unbound(name))
      }
    TyTuple(elems:) -> TyTuple(list.map(elems, go))
    TyFn(params:, result:) -> TyFn(list.map(params, go), go(result))
    TyList(elem:) -> TyList(go(elem))
    TyNamed(name:, args:) -> TyNamed(name, list.map(args, go))
    TyResult(ok:, error:) -> TyResult(go(ok), go(error))
    TySubject(message:) -> TySubject(go(message))
    TyTagged(tag:, elems:) -> TyTagged(tag, list.map(elems, go))
    TyNext(state:, message:) -> TyNext(go(state), go(message))
    TyStarted(data:) -> TyStarted(go(data))
    _ -> declared
  }
}

// ------------------------------------------------------------ type tables

/// A type table being written (contract 8.5): a flat list, children before
/// their parent, each entry once.
pub type Table {
  Table(entries: List(TypeNode), index: Dict(TypeNode, Int), size: Int)
}

pub fn new_table() -> Table {
  Table(entries: [], index: dict.new(), size: 0)
}

/// The table's entries, in index order.
pub fn entries(table: Table) -> List(TypeNode) {
  list.reverse(table.entries)
}

/// The index of an entry, added if the table does not have it yet.
pub fn add(table: Table, entry: TypeNode) -> #(Int, Table) {
  case dict.get(table.index, entry) {
    Ok(index) -> #(index, table)
    Error(Nil) -> #(
      table.size,
      Table(
        entries: [entry, ..table.entries],
        index: dict.insert(table.index, entry, table.size),
        size: table.size + 1,
      ),
    )
  }
}

/// Writes a type into a table and gives its index. The entries describe the
/// value this codex sends for the type, not the one the BEAM holds: a
/// subject is the process that owns it (`t_actor`), a custom type is named
/// (`t_named`, rule N3), Nil is the symbol `nil`.
///
/// Call it only with a `stateable` type; a part that is not known would be
/// written `{t_basic, dynamic}`, which claims something.
pub fn intern(ty: Ty, table: Table, module: String) -> #(Int, Table) {
  let one = fn(ty, table) { intern(ty, table, module) }
  let many = fn(types, table) {
    let #(indices, table) =
      list.fold(types, #([], table), fn(acc, ty) {
        let #(index, table) = one(ty, acc.1)
        #([index, ..acc.0], table)
      })
    #(list.reverse(indices), table)
  }
  case ty {
    TyInt -> add(table, frame.TInt)
    TyFloat -> add(table, frame.TFloat)
    TyBool -> add(table, frame.TBool)
    TyString -> add(table, frame.TText)
    TyBits -> add(table, frame.TBytes)
    TyNil -> add(table, frame.TSymbols(["nil"]))
    TyAtoms(names:) -> add(table, frame.TSymbols(names))
    TyDynamic | TyNever | TyUnknown(..) -> add(table, frame.TDynamic)
    TyVar(name:) -> add(table, frame.TVar(name))
    TyTuple(elems:) -> {
      let #(elems, table) = many(elems, table)
      add(table, frame.TTuple(elems))
    }
    TyFn(params:, result:) -> {
      let #(params, table) = many(params, table)
      let #(result, table) = one(result, table)
      add(table, frame.TFun(params, result))
    }
    TyList(elem:) -> {
      let #(elem, table) = one(elem, table)
      add(table, frame.TList(elem))
    }
    TyNamed(name:, args:) -> {
      let #(args, table) = many(args, table)
      add(table, frame.TNamed(names.type_name(module, name), args))
    }
    TyResult(ok:, error:) -> {
      let #(ok, table) = one(ok, table)
      let #(ok, table) = add(table, frame.TTagged("ok", [ok]))
      let #(error, table) = one(error, table)
      let #(error, table) = add(table, frame.TTagged("error", [error]))
      add(table, frame.TUnion([ok, error]))
    }
    // A subject is lowered to the process that owns it, so its type is that
    // process, taking the subject's messages.
    TySubject(message:) -> {
      let #(message, table) = one(message, table)
      add(table, frame.TActor(message))
    }
    // A bare Pid says nothing about its messages.
    TyPid -> {
      let #(message, table) = add(table, frame.TDynamic)
      add(table, frame.TActor(message))
    }
    // A name, and the subject made of it, travel as the name's symbol.
    TyName(name:, ..) | TyNamedSubject(name:, ..) ->
      add(table, frame.TSymbols([name]))
    TyTagged(tag:, elems:) -> {
      let #(elems, table) = many(elems, table)
      add(table, frame.TTagged(tag, elems))
    }
    // Next(state, message), as this sender sends it: `{continue, State}`,
    // `stop`, or `{stop_abnormal, Reason}`.
    TyNext(state:, ..) -> {
      let #(state, table) = one(state, table)
      let #(continue, table) = add(table, frame.TTagged("continue", [state]))
      let #(stop, table) = add(table, frame.TSymbols(["stop"]))
      let #(text, table) = add(table, frame.TText)
      let #(abnormal, table) =
        add(table, frame.TTagged("stop_abnormal", [text]))
      add(table, frame.TUnion([continue, stop, abnormal]))
    }
    // Started(pid, data): a tuple with the symbol `started` first.
    TyStarted(data:) -> {
      let #(pid, table) = one(TyPid, table)
      let #(data, table) = one(data, table)
      add(table, frame.TTagged("started", [pid, data]))
    }
    // StartError: the names of its three constructors. The start of a plain
    // actor never gives one in this lowering, and their fields (a reason
    // Gleam itself types as Dynamic) are not sent.
    TyStartError ->
      add(table, frame.TSymbols(["init_timeout", "init_failed", "init_exited"]))
  }
}

/// The tag under which a message of this type travels through a subject:
/// `subject__` and the type's text. Constructors are sent in snake_case (N5),
/// which never has `__` in it, so no constructor's symbol is such a tag. One
/// type gives one tag, so a tag has one type in a unit (contract T9.12).
pub fn message_tag(ty: Ty) -> String {
  "subject__" <> type_key(ty)
}

fn type_key(ty: Ty) -> String {
  let all = fn(types) { string.join(list.map(types, type_key), "_") }
  case ty {
    TyInt -> "int"
    TyFloat -> "float"
    TyBool -> "bool"
    TyString -> "string"
    TyBits -> "bit_array"
    TyNil -> "nil"
    TyAtoms(names:) -> string.join(names, "_")
    TyTuple(elems:) ->
      "tuple" <> int.to_string(list.length(elems)) <> "_" <> all(elems)
    TyFn(..) -> "fn"
    TyList(elem:) -> "list_" <> type_key(elem)
    TyNamed(name:, args: []) -> names.snake(name)
    TyNamed(name:, args:) -> names.snake(name) <> "_" <> all(args)
    TyResult(ok:, error:) -> "result_" <> type_key(ok) <> "_" <> type_key(error)
    TySubject(message:) -> "subject_" <> type_key(message)
    TyPid -> "pid"
    TyName(name:, ..) -> "name_" <> name
    TyNamedSubject(name:, ..) -> "named_subject_" <> name
    TyTagged(tag:, elems:) -> tag <> "_" <> all(elems)
    TyNext(state:, ..) -> "next_" <> type_key(state)
    TyStarted(data:) -> "started_" <> type_key(data)
    TyStartError -> "start_error"
    TyVar(name:) -> name
    TyDynamic | TyNever | TyUnknown(..) -> "dynamic"
  }
}

// ------------------------------------------------------------ library functions

/// The functions of other modules whose parameter and result types this
/// codex knows: `#(parameters, result)`. A call to any other function of
/// another module has no known result type, and is a gap wherever the
/// contract needs that type (T8.10 d).
///
/// To add one: a line here, with the types its Gleam declaration has.
pub fn library_signature(
  module: String,
  name: String,
  arity: Int,
) -> Result(#(List(Ty), Ty), Nil) {
  let found = case module, name {
    "gleam/int", "to_float" -> Ok(#([TyInt], TyFloat))
    "gleam/int", "to_string" -> Ok(#([TyInt], TyString))
    "gleam/int", "absolute_value" -> Ok(#([TyInt], TyInt))
    "gleam/int", "min" | "gleam/int", "max" -> Ok(#([TyInt, TyInt], TyInt))
    "gleam/float", "truncate" | "gleam/float", "round" ->
      Ok(#([TyFloat], TyInt))
    "gleam/float", "to_string" -> Ok(#([TyFloat], TyString))
    "gleam/float", "floor"
    | "gleam/float", "ceiling"
    | "gleam/float", "absolute_value"
    -> Ok(#([TyFloat], TyFloat))
    "gleam/float", "min" | "gleam/float", "max" ->
      Ok(#([TyFloat, TyFloat], TyFloat))
    "gleam/io", "println"
    | "gleam/io", "print"
    | "gleam/io", "println_error"
    | "gleam/io", "print_error"
    -> Ok(#([TyString], TyNil))
    "gleam/string", "length" -> Ok(#([TyString], TyInt))
    "gleam/string", "is_empty" -> Ok(#([TyString], TyBool))
    "gleam/string", "append" -> Ok(#([TyString, TyString], TyString))
    "gleam/string", "uppercase"
    | "gleam/string", "lowercase"
    | "gleam/string", "reverse"
    | "gleam/string", "trim"
    -> Ok(#([TyString], TyString))
    "gleam/string", "inspect" -> Ok(#([TyVar("anything")], TyString))
    "gleam/list", "length" -> Ok(#([TyList(TyVar("element"))], TyInt))
    _, _ -> Error(Nil)
  }
  use signature <- result.try(found)
  case list.length(signature.0) == arity {
    True -> Ok(signature)
    False -> Error(Nil)
  }
}
