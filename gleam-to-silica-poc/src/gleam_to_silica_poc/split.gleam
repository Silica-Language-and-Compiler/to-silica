//// split: Gleam's process semantics, lowered by the sender BEFORE anything is
//// typed or sent (glance syntax in, glance syntax out). The transpiler prints
//// what it is told: it writes a receive only in tail position of its
//// function (contract T9.13, T9.13a) and knows nothing of what Gleam does
//// around one. What Gleam does is this sender's business, exactly as every
//// type is (contract 8.6).
////
//// Gleam has no receive keyword: a process waits in a CALL,
//// `process.receive(subject, within)` or `process.receive_forever(subject)`
//// of gleam/erlang/process, whose value is used like any other. So in Gleam
//// every receive is "a receive with code after it":
////
////   code before the call        runs once, in the new process     -> stays where it is
////   code after the call         runs in the same process, with    -> a CONTINUATION function
////                               the variables it had
////   several receives            one after the other               -> one continuation for each
////   a call of a function that   the caller goes on with its       -> a COPY of the callee whose
////   receives, not in tail pos.  value when it returns                every end calls the continuation
////   a receive, or such a call,  its value is an operand           -> it is BOUND to a variable first
////   inside an expression                                             (`let _h1 = …`), then cut
////
//// After this pass every receive, and every call of a function that
//// receives, stands in tail position. The pieces are ordinary Gleam
//// functions (without annotations on the parameters the pass adds: the
//// codex takes those types from the calls of them, `codex.settle_made`).
////
////   fn ask(counter) {                       fn ask(counter) {
////     let reply: Subject(Report) = …          let reply: Subject(Report) = …
////     process.send(counter, Get(reply))       process.send(counter, Get(reply))
////     process.receive(reply, 1000)            ask__k1(reply)              // keeps only reply
////   }                                       }
////                                           fn ask__k1(reply) { process.receive(reply, 1000) }
////
////   pub fn main() {                         pub fn main() {
////     …                                       …
////     case ask(counter) {                     ask__c1(counter, auditor)   // ask, continued in main__k1
////       Ok(report) -> io.println(…)         }
////       Error(Nil) -> io.println(…)         fn ask__c1(counter, _k1) {
////     }                                       let reply: Subject(Report) = …
////     case summary(auditor) { … }             process.send(counter, Get(reply))
////   }                                         ask__c1__k1(reply, _k1)
////                                           }
////                                           fn ask__c1__k1(reply, _k1) {
////                                             <receive on reply, within 1000; its value, _received,
////                                              goes to main__k1(_k1, _received)>
////                                           }
////                                           fn main__k1(auditor, _h1) {
////                                             case _h1 { Ok(report) -> … Error(Nil) -> … }
////                                             summary__c1(auditor)        // and so on
////                                           }
////
//// Three things in the output are not Gleam source, and the codex knows
//// them (`codex.named_call`):
////
////   _split_receive(subject, within, then)    a receive whose value, bound to `_received`, is
////   _split_receive_forever(subject, then)    used by the expression `then` (a continuation call)
////   _split_gap("construct", "note")          a place this pass could not cut: a gap (T9.10)
////
//// and a function this pass made has a name with `:` in it (`main:k1`), which
//// no Gleam function has; it is sent as `main__k1` (README, N6).
////
//// WHAT IS NOT GLEAM'S BEHAVIOUR is said in the README ("Processes: what
//// this sender splits"): a subject does not select its messages, a message
//// no receive takes is dropped, and a function that waits must be called
//// where this pass can see the call (by its name, in the module).

import glance as g
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// The names the codex knows (see the head of this module).
pub const receive_marker = "_split_receive"

pub const forever_marker = "_split_receive_forever"

pub const gap_marker = "_split_gap"

/// The variable a receive's value is bound to for the expression that uses it.
pub const received = "_received"

const process_module = "gleam/erlang/process"

/// What a function this pass made is made from.
pub type Made {
  Made(
    /// The function (or made function) it continues or copies.
    base: String,
    /// What is appended to the base's sent name: `__k1`, `__c1`.
    suffix: String,
    /// What it is, for a diagnostic.
    what: String,
    /// The order in which the functions were made.
    index: Int,
  )
}

pub type Split {
  Split(
    functions: List(g.Function),
    made: Dict(String, Made),
    /// The public functions that wait only in a function they call: such a
    /// function is no process function itself, and it cannot be called as
    /// an ordinary function either (contract T9.13), so the codex sends it
    /// as not exported (README, "Processes: what this sender splits").
    unexported: List(String),
  )
}

type State {
  State(
    imports: Dict(String, String),
    imported: Dict(String, String),
    functions: Dict(String, g.Function),
    blocking: List(String),
    counts: Dict(#(String, String), Int),
    made: Dict(String, Made),
    out: List(#(Int, g.Function)),
    copies: Dict(#(String, String), String),
    fresh: Int,
    /// The function being cut, and the result annotation of the source
    /// function all of it is cut from.
    current: String,
    return: Option(g.Type),
  )
}

/// What happens with the value of the last expression of a body: it is
/// passed to the function `name` after `arguments`, or (`uses_value` False)
/// dropped before `name(arguments)` is called.
type Kont {
  Kont(name: String, arguments: List(g.Expression), uses_value: Bool)
}

/// The functions of a module with every receive, and every call of a
/// function that receives, in tail position. `imports` is import alias ->
/// module, `imported` unqualified imported value -> module.
pub fn functions(
  all: List(g.Function),
  imports: Dict(String, String),
  imported: Dict(String, String),
) -> Split {
  let state =
    State(
      imports:,
      imported:,
      functions: dict.from_list(list.map(all, fn(f) { #(f.name, f) })),
      blocking: [],
      counts: dict.new(),
      made: dict.new(),
      out: [],
      copies: dict.new(),
      fresh: 0,
      current: "",
      return: None,
    )
  let state = State(..state, blocking: blocking(all, state))
  let #(groups, state) =
    list.map_fold(all, state, fn(state, function) {
      case list.contains(state.blocking, function.name) {
        False -> #(state, [function])
        True -> {
          let state =
            State(
              ..state,
              out: [],
              current: function.name,
              return: function.return,
            )
          let #(body, state) =
            split_body(function.body, parameter_names(function), True, state)
          let made =
            list.sort(state.out, fn(a, b) { int.compare(a.0, b.0) })
            |> list.map(fn(pair) { pair.1 })
          #(state, [g.Function(..function, body:), ..made])
        }
      }
    })
    |> swap
  let kept = reached(list.flatten(groups), state)
  let unexported =
    list.filter(kept, fn(function) {
      function.publicity == g.Public
      && list.contains(state.blocking, function.name)
      && !list.any(statements_children(function.body, False), receives(_, state))
    })
    |> list.map(fn(function) { function.name })
  Split(
    functions: kept,
    made: dict.filter(state.made, fn(name, _) {
      list.any(kept, fn(function) { function.name == name })
    }),
    unexported:,
  )
}

/// A private function that waits, and whose every call this pass replaced by
/// a copy, is called by nothing any more: it is not sent, and neither are
/// the pieces made of it. (Other private functions nothing calls are left
/// to the Gleam compiler, which warns of them.)
fn reached(all: List(g.Function), state: State) -> List(g.Function) {
  let named =
    list.flat_map(all, fn(function) {
      list.filter(variables_of(function.body), fn(name) {
        name != function.name
      })
    })
  let kept =
    list.filter(all, fn(function) {
      let ours =
        dict.has_key(state.made, function.name)
        || list.contains(state.blocking, function.name)
      function.publicity == g.Public
      || !ours
      || list.contains(named, function.name)
    })
  case list.length(kept) == list.length(all) {
    True -> all
    False -> reached(kept, state)
  }
}

fn swap(pair: #(a, b)) -> #(b, a) {
  #(pair.1, pair.0)
}

fn parameter_names(function: g.Function) -> List(String) {
  list.filter_map(function.parameters, fn(parameter) {
    case parameter.name {
      g.Named(name) -> Ok(name)
      g.Discarded(_) -> Error(Nil)
    }
  })
}

// ------------------------------------------------------------ which functions wait

/// A function BLOCKS when it holds a receive, or calls (outside a closure) a
/// function of the module that blocks.
fn blocking(all: List(g.Function), state: State) -> List(String) {
  let now =
    list.filter(all, fn(f) { blocks_statements(f.body, state) })
    |> list.map(fn(f) { f.name })
  case list.length(now) == list.length(state.blocking) {
    True -> now
    False -> blocking(all, State(..state, blocking: now))
  }
}

/// `process.receive(subject, within)` or `process.receive_forever(subject)`:
/// the subject and the timeout.
fn receive_call(
  e: g.Expression,
  state: State,
) -> Option(#(g.Expression, Option(g.Expression))) {
  case e {
    g.Call(function:, arguments:, ..) -> {
      let name = case function {
        g.FieldAccess(container: g.Variable(name: alias, ..), label:, ..) ->
          case dict.get(state.imports, alias) {
            Ok(module) if module == process_module -> Some(label)
            _ -> None
          }
        g.Variable(name:, ..) ->
          case dict.get(state.imported, name) {
            Ok(module) if module == process_module -> Some(name)
            _ -> None
          }
        _ -> None
      }
      case name, list.map(arguments, field_item) {
        Some("receive"), [subject, within] -> Some(#(subject, Some(within)))
        Some("receive_forever"), [subject] -> Some(#(subject, None))
        _, _ -> None
      }
    }
    _ -> None
  }
}

/// A receive this pass has already given its continuation.
fn marker_call(e: g.Expression) -> Bool {
  case e {
    g.Call(function: g.Variable(name:, ..), ..) ->
      name == receive_marker || name == forever_marker
    _ -> False
  }
}

/// The function of the module a call names, when that function blocks.
fn blocking_call(e: g.Expression, state: State) -> Option(String) {
  case e {
    g.Call(function: g.Variable(name:, ..), ..) ->
      case list.contains(state.blocking, name) {
        True -> Some(name)
        False -> None
      }
    _ -> None
  }
}

/// Does this expression hold a receive itself (not a call of a function
/// that waits), outside a closure?
fn receives(e: g.Expression, state: State) -> Bool {
  receive_call(e, state) != None
  || marker_call(e)
  || list.any(children(e, False), receives(_, state))
}

/// Does this expression wait for a message somewhere inside it? A closure's
/// body runs when the closure is called, which is not here.
fn blocks(e: g.Expression, state: State) -> Bool {
  case e {
    g.BinaryOperator(location:, name: g.Pipe, left:, right:) ->
      blocks(pipe(location, left, right), state)
    _ ->
      receive_call(e, state) != None
      || marker_call(e)
      || blocking_call(e, state) != None
      || list.any(children(e, False), blocks(_, state))
  }
}

fn blocks_statement(statement: g.Statement, state: State) -> Bool {
  list.any(statements_children([statement], False), blocks(_, state))
}

fn blocks_statements(statements: List(g.Statement), state: State) -> Bool {
  list.any(statements_children(statements, False), blocks(_, state))
}

// ------------------------------------------------------------ walking the syntax

/// The value of an argument; `label:` alone is the variable of that name.
pub fn field_item(field: g.Field(g.Expression)) -> g.Expression {
  case field {
    g.LabelledField(item:, ..) -> item
    g.ShorthandField(label:, location:) -> g.Variable(location, label)
    g.UnlabelledField(item:) -> item
  }
}

fn with_item(
  field: g.Field(g.Expression),
  item: g.Expression,
) -> g.Field(g.Expression) {
  case field {
    g.LabelledField(label:, label_location:, ..) ->
      g.LabelledField(label, label_location, item)
    g.ShorthandField(label:, location:) ->
      g.LabelledField(label, location, item)
    g.UnlabelledField(..) -> g.UnlabelledField(item)
  }
}

/// The expressions directly inside an expression. `into_closures` False
/// leaves out what runs later: the body of a closure, and the statements
/// after a `use` (they are its callback).
pub fn children(e: g.Expression, into_closures: Bool) -> List(g.Expression) {
  case e {
    g.Int(..) | g.Float(..) | g.String(..) | g.Variable(..) -> []
    g.NegateInt(value:, ..) | g.NegateBool(value:, ..) -> [value]
    g.Block(statements:, ..) -> statements_children(statements, into_closures)
    g.Panic(message:, ..) | g.Todo(message:, ..) -> option.values([message])
    g.Tuple(elements:, ..) -> elements
    g.List(elements:, rest:, ..) -> list.append(elements, option.values([rest]))
    g.Fn(body:, ..) ->
      case into_closures {
        True -> statements_children(body, True)
        False -> []
      }
    g.RecordUpdate(location:, record:, fields:, ..) -> [
      record,
      ..list.map(fields, fn(field) {
        option.unwrap(field.item, g.Variable(location, field.label))
      })
    ]
    g.FieldAccess(container:, ..) -> [container]
    g.Call(function:, arguments:, ..) -> [
      function,
      ..list.map(arguments, field_item)
    ]
    g.TupleIndex(tuple:, ..) -> [tuple]
    g.FnCapture(function:, arguments_before:, arguments_after:, ..) -> [
      function,
      ..list.map(list.append(arguments_before, arguments_after), field_item)
    ]
    g.BitString(segments:, ..) -> list.map(segments, fn(segment) { segment.0 })
    g.Case(subjects:, clauses:, ..) ->
      list.append(
        subjects,
        list.flat_map(clauses, fn(clause) {
          list.append(option.values([clause.guard]), [clause.body])
        }),
      )
    g.BinaryOperator(left:, right:, ..) -> [left, right]
    g.Echo(expression:, message:, ..) -> option.values([expression, message])
  }
}

fn statements_children(
  statements: List(g.Statement),
  into_closures: Bool,
) -> List(g.Expression) {
  case statements {
    [] -> []
    [g.Use(function:, ..), ..rest] ->
      case into_closures {
        True -> [function, ..statements_children(rest, True)]
        False -> [function]
      }
    [g.Assignment(kind:, value:, ..), ..rest] -> {
      let message = case kind {
        g.LetAssert(message:) -> option.values([message])
        g.Let -> []
      }
      list.flatten([
        [value],
        message,
        statements_children(rest, into_closures),
      ])
    }
    [g.Assert(expression:, message:, ..), ..rest] ->
      list.flatten([
        [expression],
        option.values([message]),
        statements_children(rest, into_closures),
      ])
    [g.Expression(e), ..rest] -> [e, ..statements_children(rest, into_closures)]
  }
}

/// Every variable name that occurs in an expression, closures included.
fn variables(e: g.Expression) -> List(String) {
  case e {
    g.Variable(name:, ..) -> [name]
    _ -> list.flat_map(children(e, True), variables)
  }
}

pub fn variables_of(statements: List(g.Statement)) -> List(String) {
  list.flat_map(statements_children(statements, True), variables)
}

/// The variables a pattern binds.
pub fn pattern_names(p: g.Pattern) -> List(String) {
  let named = fn(name: g.AssignmentName) {
    case name {
      g.Named(name) -> [name]
      g.Discarded(_) -> []
    }
  }
  case p {
    g.PatternVariable(name:, ..) -> [name]
    g.PatternTuple(elements:, ..) -> list.flat_map(elements, pattern_names)
    g.PatternAssignment(pattern: inner, name:, ..) -> [
      name,
      ..pattern_names(inner)
    ]
    g.PatternList(elements:, tail:, ..) ->
      list.flat_map(list.append(elements, option.values([tail])), pattern_names)
    g.PatternConcatenate(prefix_name:, rest_name:, ..) ->
      list.flat_map(option.values([prefix_name, Some(rest_name)]), named)
    g.PatternBitString(segments:, ..) ->
      list.flat_map(segments, fn(segment) { pattern_names(segment.0) })
    g.PatternVariant(arguments:, ..) ->
      list.flat_map(arguments, fn(argument) {
        case argument {
          g.LabelledField(item:, ..) -> pattern_names(item)
          g.ShorthandField(label:, ..) -> [label]
          g.UnlabelledField(item:) -> pattern_names(item)
        }
      })
    g.PatternInt(..)
    | g.PatternFloat(..)
    | g.PatternString(..)
    | g.PatternDiscard(..) -> []
  }
}

fn binders(statement: g.Statement) -> List(String) {
  case statement {
    g.Assignment(pattern:, ..) -> pattern_names(pattern)
    _ -> []
  }
}

fn simple(e: g.Expression) -> Bool {
  case e {
    g.Int(..) | g.Float(..) | g.String(..) | g.Variable(..) -> True
    _ -> False
  }
}

/// `a |> f(b)` is `f(a, b)` and `a |> f` is `f(a)`. `a |> f(b, _)` is
/// `{ let _pipe = a  f(b, _pipe) }`, as the Gleam compiler writes it, so that
/// `a` is still evaluated before `b`. Gleam also reads `a |> f(b)` as
/// `f(b)(a)` when `f` does not take `a` first; that reading needs types,
/// which glance does not give.
pub fn pipe(
  at: g.Span,
  left: g.Expression,
  right: g.Expression,
) -> g.Expression {
  let argument = fn(label: Option(String), item: g.Expression) {
    case label {
      Some(label) -> g.LabelledField(label, at, item)
      None -> g.UnlabelledField(item)
    }
  }
  case right {
    g.Call(function:, arguments:, ..) ->
      g.Call(at, function, [g.UnlabelledField(left), ..arguments])
    g.FnCapture(label:, function:, arguments_before: [], arguments_after:, ..) ->
      g.Call(at, function, [argument(label, left), ..arguments_after])
    g.FnCapture(label:, function:, arguments_before:, arguments_after:, ..) ->
      g.Block(at, [
        g.Assignment(at, g.Let, g.PatternVariable(at, "_pipe"), None, left),
        g.Expression(g.Call(
          at,
          function,
          list.flatten([
            arguments_before,
            [argument(label, g.Variable(at, "_pipe"))],
            arguments_after,
          ]),
        )),
      ])
    _ -> g.Call(at, right, [g.UnlabelledField(left)])
  }
}

/// A pipe that waits is read as the call it is.
fn unpipe(e: g.Expression, state: State) -> g.Expression {
  case e {
    g.BinaryOperator(location:, name: g.Pipe, left:, right:) ->
      case blocks(e, state) {
        True -> unpipe(pipe(location, left, right), state)
        False -> e
      }
    _ -> e
  }
}

// ------------------------------------------------------------ the cut

/// A body whose last statement is in tail position of its function.
/// `bound`: the variables that have a value when the body starts.
/// `pristine`: nothing of the function has run before this body. The first
/// statement that waits is where the function is cut: the statements after
/// it become a continuation function, and the statement becomes the body's
/// last.
fn split_body(
  statements: List(g.Statement),
  bound: List(String),
  pristine: Bool,
  state: State,
) -> #(List(g.Statement), State) {
  case statements {
    [] -> #([], state)
    // The statements after a `use` are its callback: a closure.
    [g.Use(..), ..] -> #(statements, state)
    [last] -> split_last(last, bound, pristine, state)
    [statement, ..rest] ->
      case blocks_statement(statement, state) {
        False -> {
          let #(rest, state) =
            split_body(
              rest,
              list.append(bound, binders(statement)),
              False,
              state,
            )
          #([statement, ..rest], state)
        }
        True ->
          case shape(statement, state) {
            Some(#(binding, waits)) ->
              cut(binding, waits, rest, bound, pristine, state)
            None ->
              case hoist_statement(statement, state) {
                Some(#(first, second, state)) ->
                  split_body([first, second, ..rest], bound, pristine, state)
                // A gap ends its block: the program never gets past it.
                None -> #([gap(statement_location(statement))], state)
              }
          }
      }
  }
}

/// How the value of a statement that waits is bound.
type Binding {
  NoBinding
  Binding(
    at: g.Span,
    kind: g.AssignmentKind,
    pattern: g.Pattern,
    annotation: Option(g.Type),
  )
}

/// What can be cut: `let p = B` or `B` alone, where B waits and its value is
/// the value of its own tail positions.
fn shape(
  statement: g.Statement,
  state: State,
) -> Option(#(Binding, g.Expression)) {
  case statement {
    g.Assignment(location:, kind:, pattern:, annotation:, value:) -> {
      let value = unpipe(value, state)
      let plain = case kind {
        g.Let | g.LetAssert(None) -> True
        g.LetAssert(Some(_)) -> False
      }
      case plain && cuttable(value, state) {
        True -> Some(#(Binding(location, kind, pattern, annotation), value))
        False -> None
      }
    }
    g.Expression(e) -> {
      let e = unpipe(e, state)
      case cuttable(e, state) {
        True -> Some(#(NoBinding, e))
        False -> None
      }
    }
    _ -> None
  }
}

fn cuttable(e: g.Expression, state: State) -> Bool {
  let none_blocks = fn(all) { !list.any(all, blocks(_, state)) }
  case receive_call(e, state), e {
    Some(#(subject, within)), _ ->
      none_blocks([subject, ..option.values([within])])
    None, g.Call(arguments:, ..) ->
      { marker_call(e) || blocking_call(e, state) != None }
      && none_blocks(list.map(arguments, field_item))
    None, g.Case(subjects:, ..) -> none_blocks(subjects)
    None, g.Block(statements:, ..) ->
      !list.any(statements, fn(statement) {
        case statement {
          g.Use(..) -> True
          _ -> False
        }
      })
    None, _ -> False
  }
}

/// `let p = B  Rest` (no binding: `B  Rest`): B becomes the last expression,
/// every value B can have is passed to the continuation K, and K is
/// `fn K(live…, value) { let p = value  Rest }`. Live: the variables Rest
/// uses that have a value where B starts (what B's own branches bind does
/// not leave them, in Gleam).
fn cut(
  binding: Binding,
  waits: g.Expression,
  rest: List(g.Statement),
  bound: List(String),
  pristine: Bool,
  state: State,
) -> #(List(g.Statement), State) {
  let at = waits.location
  let #(value, annotation, body, state) = case binding {
    NoBinding -> #(None, None, rest, state)
    Binding(pattern: g.PatternDiscard(..), annotation: None, kind: g.Let, ..) -> #(
      None,
      None,
      rest,
      state,
    )
    Binding(at: let_at, kind:, pattern:, annotation:) ->
      case pattern {
        g.PatternVariable(name:, ..) ->
          case list.contains(bound, name) {
            False -> #(Some(name), annotation, rest, state)
            True -> {
              let #(name, state) = fresh("v", state)
              #(
                Some(name),
                annotation,
                [
                  g.Assignment(
                    let_at,
                    kind,
                    pattern,
                    None,
                    g.Variable(let_at, name),
                  ),
                  ..rest
                ],
                state,
              )
            }
          }
        _ -> {
          let #(name, state) = fresh("v", state)
          #(
            Some(name),
            annotation,
            [
              g.Assignment(
                let_at,
                kind,
                pattern,
                annotation,
                g.Variable(let_at, name),
              ),
              ..rest
            ],
            state,
          )
        }
      }
  }
  // The value of a call of a function of the module has the type that
  // function's result annotation says; any other value's type is the type
  // of what the continuation is called with (codex.settle_made).
  let annotation = case annotation, blocking_call(waits, state) {
    Some(_), _ -> annotation
    None, Some(callee) ->
      case dict.get(state.functions, callee) {
        Ok(function) -> function.return
        Error(Nil) -> None
      }
    None, None -> None
  }
  let used = variables_of(body)
  let live =
    list.filter(list.unique(bound), fn(name) {
      list.contains(used, name) && Some(name) != value
    })
  let #(name, state) =
    new_name(
      state.current,
      "k",
      "the code of " <> shown(state.current) <> " after it waits",
      state,
    )
  let kont =
    Kont(name, list.map(live, g.Variable(at, _)), uses_value: value != None)
  let #(waits, state) = wrap_last(waits, kont, state)
  let #(first, state) = split_tail(waits, bound, pristine, state)
  let parameters =
    list.append(
      list.map(live, fn(name) { g.FunctionParameter(None, g.Named(name), None) }),
      case value {
        Some(value) -> [g.FunctionParameter(None, g.Named(value), annotation)]
        None -> []
      },
    )
  let outer = state.current
  let #(body, state) =
    split_body(
      body,
      list.append(live, option.values([value])),
      True,
      State(..state, current: name),
    )
  let function =
    g.Function(
      location: at,
      name:,
      publicity: g.Private,
      parameters:,
      return: state.return,
      body:,
    )
  #(first, push(function, State(..state, current: outer)))
}

/// The last statement of a body.
fn split_last(
  statement: g.Statement,
  bound: List(String),
  pristine: Bool,
  state: State,
) -> #(List(g.Statement), State) {
  case statement, blocks_statement(statement, state) {
    _, False -> #([statement], state)
    g.Expression(e), True -> split_tail(e, bound, pristine, state)
    // The value of a `let` is its right side: it is bound first, and cut.
    g.Assignment(location:, kind:, pattern:, annotation:, value:), True -> {
      let #(name, state) = fresh("h", state)
      split_body(
        [
          g.Assignment(
            location,
            g.Let,
            g.PatternVariable(location, name),
            annotation,
            value,
          ),
          g.Assignment(
            location,
            kind,
            pattern,
            None,
            g.Variable(location, name),
          ),
        ],
        bound,
        pristine,
        state,
      )
    }
    _, True -> #([gap(statement_location(statement))], state)
  }
}

/// An expression in tail position: nothing of the function runs after it,
/// so a receive may stand here. Its own bodies are in tail position too.
fn split_tail(
  e: g.Expression,
  bound: List(String),
  pristine: Bool,
  state: State,
) -> #(List(g.Statement), State) {
  let e = unpipe(e, state)
  let is_receive = case receive_call(e, state) {
    Some(#(subject, within)) ->
      !list.any([subject, ..option.values([within])], blocks(_, state))
    None -> marker_call(e) && cuttable(e, state)
  }
  case blocks(e, state), is_receive, e {
    False, _, _ -> #([g.Expression(e)], state)
    // The state a waiting process keeps is the sender's business too: the
    // transpiler keeps every variable that has a value at the receive
    // (contract T9.13a). A receive that does not use all of them, or that
    // code of its function runs before, is put in a function of its own,
    // whose parameters are the variables it uses.
    True, True, _ -> {
      let used = variables(e)
      let all = list.unique(bound)
      let live = list.filter(all, list.contains(used, _))
      // A public function keeps its own receive, with every variable it
      // has bound (the transpiler keeps at most six): it is then a process
      // function itself, which is what an exported function that waits
      // must be (contract T9.13).
      let exported = case dict.get(state.functions, state.current) {
        Ok(g.Function(publicity: g.Public, ..)) -> list.length(all) <= 6
        _ -> False
      }
      case { pristine && list.length(live) == list.length(all) } || exported {
        True -> #([g.Expression(e)], state)
        False -> {
          let at = e.location
          let #(name, state) =
            new_name(
              state.current,
              "k",
              "a receive of " <> shown(state.current),
              state,
            )
          let function =
            g.Function(
              location: at,
              name:,
              publicity: g.Private,
              parameters: list.map(live, fn(name) {
                g.FunctionParameter(None, g.Named(name), None)
              }),
              return: state.return,
              body: [g.Expression(e)],
            )
          #(
            [
              g.Expression(g.Call(
                at,
                g.Variable(at, name),
                list.map(live, fn(name) {
                  g.UnlabelledField(g.Variable(at, name))
                }),
              )),
            ],
            push(function, state),
          )
        }
      }
    }
    True, False, g.Case(location:, subjects:, clauses:) ->
      case list.any(subjects, blocks(_, state)) {
        True -> hoisted_tail(e, bound, pristine, state)
        False -> {
          let #(state, clauses) =
            list.map_fold(clauses, state, fn(state, clause) {
              let names =
                list.flat_map(list.flatten(clause.patterns), pattern_names)
              let #(body, state) =
                split_tail(
                  clause.body,
                  list.append(bound, names),
                  pristine,
                  state,
                )
              #(
                state,
                g.Clause(..clause, body: as_expression(body, clause.body)),
              )
            })
          #([g.Expression(g.Case(location, subjects, clauses))], state)
        }
      }
    True, False, g.Block(location:, statements:) -> {
      let #(statements, state) = split_body(statements, bound, pristine, state)
      #([g.Expression(g.Block(location, statements))], state)
    }
    True, False, g.Call(arguments:, ..) ->
      // A tail call of a function that receives is what the contract asks
      // for (T9.13); its arguments must not wait.
      case
        blocking_call(e, state) != None
        && !list.any(list.map(arguments, field_item), blocks(_, state))
      {
        True -> #([g.Expression(e)], state)
        False -> hoisted_tail(e, bound, pristine, state)
      }
    True, False, _ -> hoisted_tail(e, bound, pristine, state)
  }
}

/// A tail expression with a receive inside it: the receive is bound first.
fn hoisted_tail(
  e: g.Expression,
  bound: List(String),
  pristine: Bool,
  state: State,
) -> #(List(g.Statement), State) {
  case hoist_statement(g.Expression(e), state) {
    Some(#(first, second, state)) ->
      split_body([first, second], bound, pristine, state)
    None -> #([gap(e.location)], state)
  }
}

fn as_expression(
  statements: List(g.Statement),
  original: g.Expression,
) -> g.Expression {
  case statements {
    [g.Expression(e)] -> e
    _ -> g.Block(original.location, statements)
  }
}

// ------------------------------------------------------------ binding a receive inside an expression first

/// `S[B]`, where B waits and is an operand inside the statement S: the two
/// statements `let _h = B` and `S[_h]`. Only when everything S evaluates
/// before B is a variable or a literal, so that nothing changes its order.
fn hoist_statement(
  statement: g.Statement,
  state: State,
) -> Option(#(g.Statement, g.Statement, State)) {
  let #(name, state) = fresh("h", state)
  let bind = fn(waits: g.Expression) {
    g.Assignment(
      waits.location,
      g.Let,
      g.PatternVariable(waits.location, name),
      None,
      waits,
    )
  }
  case statement {
    g.Assignment(location:, kind:, pattern:, annotation:, value:) ->
      option.map(hoist(value, name, state), fn(found) {
        #(
          bind(found.0),
          g.Assignment(location, kind, pattern, annotation, found.1),
          state,
        )
      })
    g.Expression(e) ->
      option.map(hoist(e, name, state), fn(found) {
        #(bind(found.0), g.Expression(found.1), state)
      })
    _ -> None
  }
}

/// The first thing `e` evaluates that waits and can be cut, and `e` with the
/// variable `name` in its place.
fn hoist(
  e: g.Expression,
  name: String,
  state: State,
) -> Option(#(g.Expression, g.Expression)) {
  let e = unpipe(e, state)
  let first = fn(items: List(g.Expression), rebuild) {
    let #(before, from) = list.split_while(items, fn(i) { !blocks(i, state) })
    case list.all(before, simple), from {
      True, [item, ..after] ->
        option.map(inner(item, name, state), fn(found) {
          #(found.0, rebuild(list.flatten([before, [found.1], after])))
        })
      _, _ -> None
    }
  }
  case e {
    g.Call(location:, function:, arguments:) ->
      case simple(function) || is_qualified(function) {
        True ->
          first(list.map(arguments, field_item), fn(items) {
            g.Call(location, function, list.map2(arguments, items, with_item))
          })
        False -> None
      }
    g.Case(location:, subjects:, clauses:) ->
      first(subjects, g.Case(location, _, clauses))
    g.Tuple(location:, elements:) -> first(elements, g.Tuple(location, _))
    g.BinaryOperator(location:, name: operator, left:, right:) ->
      case operator, blocks(left, state) {
        _, True ->
          option.map(inner(left, name, state), fn(found) {
            #(found.0, g.BinaryOperator(location, operator, found.1, right))
          })
        // The right side of && and || is not always evaluated.
        g.And, False | g.Or, False -> None
        _, False ->
          case simple(left) {
            True ->
              option.map(inner(right, name, state), fn(found) {
                #(found.0, g.BinaryOperator(location, operator, left, found.1))
              })
            False -> None
          }
      }
    g.NegateInt(location:, value:) ->
      option.map(inner(value, name, state), fn(found) {
        #(found.0, g.NegateInt(location, found.1))
      })
    g.NegateBool(location:, value:) ->
      option.map(inner(value, name, state), fn(found) {
        #(found.0, g.NegateBool(location, found.1))
      })
    g.FieldAccess(location:, container:, label:) ->
      option.map(inner(container, name, state), fn(found) {
        #(found.0, g.FieldAccess(location, found.1, label))
      })
    g.TupleIndex(location:, tuple:, index:) ->
      option.map(inner(tuple, name, state), fn(found) {
        #(found.0, g.TupleIndex(location, found.1, index))
      })
    _ -> None
  }
}

/// An operand that waits: itself when it can be cut, or what it evaluates
/// first.
fn inner(
  e: g.Expression,
  name: String,
  state: State,
) -> Option(#(g.Expression, g.Expression)) {
  let e = unpipe(e, state)
  case cuttable(e, state) {
    True -> Some(#(e, g.Variable(e.location, name)))
    False -> hoist(e, name, state)
  }
}

fn is_qualified(function: g.Expression) -> Bool {
  case function {
    g.FieldAccess(container: g.Variable(..), ..) -> True
    _ -> False
  }
}

// ------------------------------------------------------------ passing a value on

/// The expression `e` is the last of a body; `kont` says what happens with
/// its value. Answers the expression that takes its place.
fn wrap_last(
  e: g.Expression,
  kont: Kont,
  state: State,
) -> #(g.Expression, State) {
  let e = unpipe(e, state)
  let at = e.location
  case receive_call(e, state), e {
    Some(#(subject, within)), _ ->
      case list.any([subject, ..option.values([within])], blocks(_, state)) {
        True -> wrap_hoisted(e, kont, state)
        False -> {
          let then = pass(kont, g.Variable(at, received))
          let call = case within {
            Some(within) ->
              g.Call(at, g.Variable(at, receive_marker), [
                g.UnlabelledField(subject),
                g.UnlabelledField(within),
                g.UnlabelledField(then),
              ])
            None ->
              g.Call(at, g.Variable(at, forever_marker), [
                g.UnlabelledField(subject),
                g.UnlabelledField(then),
              ])
          }
          #(call, state)
        }
      }
    None, g.Case(location:, subjects:, clauses:) ->
      case list.any(subjects, blocks(_, state)) {
        True -> wrap_hoisted(e, kont, state)
        False -> {
          let #(state, clauses) =
            list.map_fold(clauses, state, fn(state, clause) {
              let #(body, state) = wrap_last(clause.body, kont, state)
              #(state, g.Clause(..clause, body:))
            })
          #(g.Case(location, subjects, clauses), state)
        }
      }
    None, g.Block(location:, statements:) ->
      case wrap_statements(statements, kont, state) {
        Some(#(statements, state)) -> #(g.Block(location, statements), state)
        None -> wrap_value(e, kont, state)
      }
    // The process ends here: no continuation runs.
    None, g.Panic(..) | None, g.Todo(..) -> #(e, state)
    None, g.Call(function:, arguments:, ..) ->
      case
        blocking_call(e, state),
        list.any(list.map(arguments, field_item), blocks(_, state))
      {
        // The callee receives: a copy of it goes on in the continuation
        // when it ends.
        Some(callee), False -> {
          let #(name, state) = copy(callee, kont, state)
          #(
            g.Call(
              at,
              g.Variable(at, name),
              list.append(
                arguments,
                list.map(kont.arguments, g.UnlabelledField),
              ),
            ),
            state,
          )
        }
        _, _ ->
          // A continuation's own call, already in place.
          case function {
            g.Variable(name:, ..) ->
              case dict.has_key(state.made, name) || marker_call(e) {
                True -> #(e, state)
                False -> wrap_value(e, kont, state)
              }
            _ -> wrap_value(e, kont, state)
          }
      }
    None, _ -> wrap_value(e, kont, state)
  }
}

fn wrap_value(
  e: g.Expression,
  kont: Kont,
  state: State,
) -> #(g.Expression, State) {
  case blocks(e, state) {
    False -> #(pass(kont, e), state)
    True -> wrap_hoisted(e, kont, state)
  }
}

/// A value with a receive inside it: the receive is bound first, in a block
/// whose last expression goes to the continuation.
fn wrap_hoisted(
  e: g.Expression,
  kont: Kont,
  state: State,
) -> #(g.Expression, State) {
  case hoist_statement(g.Expression(e), state) {
    Some(#(first, g.Expression(second), state)) -> {
      let #(second, state) = wrap_last(second, kont, state)
      #(g.Block(e.location, [first, g.Expression(second)]), state)
    }
    _ -> #(gap_call(e.location), state)
  }
}

/// The statements of a block whose value goes to the continuation. None:
/// the block has a `use` or ends with an assert, and is passed as a value.
fn wrap_statements(
  statements: List(g.Statement),
  kont: Kont,
  state: State,
) -> Option(#(List(g.Statement), State)) {
  let has_use =
    list.any(statements, fn(statement) {
      case statement {
        g.Use(..) -> True
        _ -> False
      }
    })
  let #(before, last) =
    list.split(statements, int.max(list.length(statements) - 1, 0))
  case has_use, last {
    False, [g.Expression(e)] -> {
      let #(e, state) = wrap_last(e, kont, state)
      Some(#(list.append(before, [g.Expression(e)]), state))
    }
    False, [g.Assignment(location:, kind:, pattern:, annotation:, value:)] -> {
      let #(name, state) = fresh("h", state)
      let variable = g.Variable(location, name)
      Some(#(
        list.append(before, [
          g.Assignment(
            location,
            g.Let,
            g.PatternVariable(location, name),
            annotation,
            value,
          ),
          g.Assignment(location, kind, pattern, None, variable),
          g.Expression(pass(kont, variable)),
        ]),
        state,
      ))
    }
    _, _ -> None
  }
}

/// The call of the continuation with a value.
fn pass(kont: Kont, value: g.Expression) -> g.Expression {
  let at = value.location
  let call = fn(arguments) {
    g.Call(
      at,
      g.Variable(at, kont.name),
      list.map(arguments, g.UnlabelledField),
    )
  }
  case kont.uses_value, simple(value) {
    True, _ -> call(list.append(kont.arguments, [value]))
    False, True -> call(kont.arguments)
    False, False ->
      g.Block(at, [g.Expression(value), g.Expression(call(kont.arguments))])
  }
}

// ------------------------------------------------------------ copies

/// The copy of the function `callee` whose every end goes on as `kont`
/// says. Its extra parameters carry what the continuation needs (its live
/// variables). One copy for each (function, continuation): a function that
/// loops calls its own copy.
fn copy(callee: String, kont: Kont, state: State) -> #(String, State) {
  case
    dict.get(state.copies, #(callee, kont.name)),
    dict.get(state.functions, callee)
  {
    Ok(name), _ -> #(name, state)
    Error(Nil), Error(Nil) -> #(callee, state)
    Error(Nil), Ok(function) -> {
      let at = function.location
      let #(state, extra) =
        list.map_fold(kont.arguments, state, fn(state, _) {
          swap(fresh("k", state))
        })
      let #(name, state) =
        new_name(
          callee,
          "c",
          callee <> " going on in " <> shown(kont.name),
          state,
        )
      let state =
        State(
          ..state,
          copies: dict.insert(state.copies, #(callee, kont.name), name),
        )
      let inner_kont =
        Kont(..kont, arguments: list.map(extra, g.Variable(at, _)))
      let outer = state.current
      let state = State(..state, current: name)
      let #(body, state) = case
        wrap_statements(function.body, inner_kont, state)
      {
        Some(wrapped) -> wrapped
        None -> #([gap(at)], state)
      }
      let #(body, state) =
        split_body(
          body,
          list.append(parameter_names(function), extra),
          True,
          state,
        )
      let made =
        g.Function(
          location: at,
          name:,
          publicity: g.Private,
          parameters: list.append(
            function.parameters,
            list.map(extra, fn(name) {
              g.FunctionParameter(None, g.Named(name), None)
            }),
          ),
          return: state.return,
          body:,
        )
      #(name, push(made, State(..state, current: outer)))
    }
  }
}

// ------------------------------------------------------------ names, gaps

fn new_name(
  base: String,
  letter: String,
  what: String,
  state: State,
) -> #(String, State) {
  let count =
    case dict.get(state.counts, #(base, letter)) {
      Ok(count) -> count
      Error(Nil) -> 0
    }
    + 1
  let suffix = letter <> int.to_string(count)
  let name = base <> ":" <> suffix
  #(
    name,
    State(
      ..state,
      counts: dict.insert(state.counts, #(base, letter), count),
      made: dict.insert(
        state.made,
        name,
        Made(base:, suffix: "__" <> suffix, what:, index: dict.size(state.made)),
      ),
    ),
  )
}

fn push(function: g.Function, state: State) -> State {
  let index = case dict.get(state.made, function.name) {
    Ok(made) -> made.index
    Error(Nil) -> 0
  }
  State(..state, out: [#(index, function), ..state.out])
}

/// A made function's name as a reader knows it: `main__k1`.
pub fn shown(name: String) -> String {
  string.join(string.split(name, ":"), "__")
}

/// A variable of this pass: `_<letter><n>`, a name no Gleam variable has
/// (a Gleam name that starts with `_` is a discard, never a value).
fn fresh(letter: String, state: State) -> #(String, State) {
  let next = state.fresh + 1
  #("_" <> letter <> int.to_string(next), State(..state, fresh: next))
}

fn statement_location(statement: g.Statement) -> g.Span {
  case statement {
    g.Use(location:, ..) -> location
    g.Assignment(location:, ..) -> location
    g.Assert(location:, ..) -> location
    g.Expression(e) -> e.location
  }
}

const gap_construct = "receive inside an expression"

const gap_note =
  "this sender cuts a function at a process.receive, or at a call of a function that receives, that is a statement, the value of a let, the subject of a case, or an operand that is evaluated before anything else of its statement that is not a variable or a literal (contract T9.13a): bind its value with let first"

fn gap_call(at: g.Span) -> g.Expression {
  g.Call(at, g.Variable(at, gap_marker), [
    g.UnlabelledField(g.String(at, gap_construct)),
    g.UnlabelledField(g.String(at, gap_note)),
  ])
}

fn gap(at: g.Span) -> g.Statement {
  g.Expression(gap_call(at))
}
