//// lift: a function literal that captures nothing is sent as a function of
//// the module (glance syntax in, glance syntax out; before the split).
////
//// The transpiler writes a `(:lambda)` only as the function of a `(:spawn)`
//// (contract H36, T9.14): a Silica function literal captures only integer
//// literals (limitation observed), so a closure has no lowering there. What
//// a `fn` is in Gleam is this sender's business, and a `fn` that uses no
//// variable of the function around it is a function of the module in all
//// but name:
////
////   fn twice(f: fn(Int) -> Int, n: Int) -> Int { f(f(n)) }
////
////   pub fn add_ten(n: Int) -> Int {          pub fn add_ten(n: Int) -> Int {
////     twice(fn(x) { add(x, 5) }, n)            twice(add_ten__f1, n)
////   }                                        }
////                                            fn add_ten__f1(x: Int) -> Int { add(x, 5) }
////
//// WHICH `fn`: one written directly as an argument (not labelled) of a call
//// of a function of this module whose declaration gives that parameter a
//// function type without type variables, of the fn's arity; also when the
//// call is the right side of a pipe, or a capture (`twice(fn(x) { … }, _)`).
//// The declared function type is where the made function's own signature
//// comes from (an annotation the fn writes itself is kept). A capture
//// whose other arguments are all literals (`twice(add(2, _), n)`) is the fn
//// it stands for, `fn(c) { add(2, c) }`, and is lifted the same way.
////
//// "CAPTURES NOTHING" is decided by names, on the safe side: a name the
//// fn's body uses that is not one of its parameters, and that the function
//// around the fn binds anywhere outside the fn (a parameter, a let, a case
//// clause, another fn's parameter), counts as captured.
////
//// WHAT STAYS A `fn`: a closure; a fn bound to a variable, returned, or
//// given to a function of another module or through a labelled argument; a
//// fn whose body waits in a `process.receive` (the split does not look
//// inside a closure, and a made function would be looked into).
////
//// The made function is named `<function>:f<n>` here and sent as
//// `<function>__f<n>` (README, N6). It behaves as the fn does.

import glance as g
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam_to_silica_poc/split

pub type Lifted {
  Lifted(functions: List(g.Function), made: Dict(String, split.Made))
}

type State {
  State(
    functions: Dict(String, g.Function),
    /// The function whose body is being read, and the names it binds.
    enclosing: g.Function,
    count: Int,
    out: List(g.Function),
    made: Dict(String, split.Made),
  )
}

/// The functions of a module with every function literal that can be lifted
/// replaced by the name of the function made of it, each made function
/// after the function it was written in; and what each is made from.
pub fn functions(all: List(g.Function)) -> Lifted {
  let table = dict.from_list(list.map(all, fn(f) { #(f.name, f) }))
  let #(made, groups) =
    list.map_fold(all, dict.new(), fn(made, function) {
      let state =
        State(functions: table, enclosing: function, count: 0, out: [], made:)
      let #(body, state) = statements(function.body, state)
      #(state.made, [g.Function(..function, body:), ..list.reverse(state.out)])
    })
  Lifted(functions: list.flatten(groups), made:)
}

// ------------------------------------------------------------ the walk

fn statements(
  all: List(g.Statement),
  state: State,
) -> #(List(g.Statement), State) {
  let #(state, all) =
    list.map_fold(all, state, fn(state, statement) {
      let #(statement, state) = case statement {
        g.Use(location:, patterns:, function:) -> {
          let #(function, state) = expression(function, state)
          #(g.Use(location, patterns, function), state)
        }
        g.Assignment(location:, kind:, pattern:, annotation:, value:) -> {
          let #(value, state) = expression(value, state)
          #(g.Assignment(location, kind, pattern, annotation, value), state)
        }
        g.Assert(location:, expression: e, message:) -> {
          let #(e, state) = expression(e, state)
          #(g.Assert(location, e, message), state)
        }
        g.Expression(e) -> {
          let #(e, state) = expression(e, state)
          #(g.Expression(e), state)
        }
      }
      #(state, statement)
    })
  #(all, state)
}

fn expressions(
  all: List(g.Expression),
  state: State,
) -> #(List(g.Expression), State) {
  let #(state, all) =
    list.map_fold(all, state, fn(state, e) {
      let #(e, state) = expression(e, state)
      #(state, e)
    })
  #(all, state)
}

fn fields(
  all: List(g.Field(g.Expression)),
  state: State,
) -> #(List(g.Field(g.Expression)), State) {
  let #(state, all) =
    list.map_fold(all, state, fn(state, field) {
      case field {
        g.LabelledField(label:, label_location:, item:) -> {
          let #(item, state) = expression(item, state)
          #(state, g.LabelledField(label, label_location, item))
        }
        g.UnlabelledField(item:) -> {
          let #(item, state) = expression(item, state)
          #(state, g.UnlabelledField(item))
        }
        g.ShorthandField(..) -> #(state, field)
      }
    })
  #(all, state)
}

fn optional(
  e: Option(g.Expression),
  state: State,
) -> #(Option(g.Expression), State) {
  case e {
    Some(e) -> {
      let #(e, state) = expression(e, state)
      #(Some(e), state)
    }
    None -> #(None, state)
  }
}

/// An expression with the function literals inside it lifted where they
/// can be.
fn expression(e: g.Expression, state: State) -> #(g.Expression, State) {
  case e {
    g.Int(..) | g.Float(..) | g.String(..) | g.Variable(..) -> #(e, state)
    g.Panic(..) | g.Todo(..) | g.Echo(..) | g.BitString(..) -> #(e, state)
    g.NegateInt(location:, value:) -> {
      let #(value, state) = expression(value, state)
      #(g.NegateInt(location, value), state)
    }
    g.NegateBool(location:, value:) -> {
      let #(value, state) = expression(value, state)
      #(g.NegateBool(location, value), state)
    }
    g.Block(location:, statements: body) -> {
      let #(body, state) = statements(body, state)
      #(g.Block(location, body), state)
    }
    g.Tuple(location:, elements:) -> {
      let #(elements, state) = expressions(elements, state)
      #(g.Tuple(location, elements), state)
    }
    g.List(location:, elements:, rest:) -> {
      let #(elements, state) = expressions(elements, state)
      let #(rest, state) = optional(rest, state)
      #(g.List(location, elements, rest), state)
    }
    g.Fn(location:, arguments:, return_annotation:, body:) -> {
      let #(body, state) = statements(body, state)
      #(g.Fn(location, arguments, return_annotation, body), state)
    }
    g.RecordUpdate(location:, module:, constructor:, record:, fields: updates) -> {
      let #(record, state) = expression(record, state)
      let #(state, updates) =
        list.map_fold(updates, state, fn(state, field) {
          let #(item, state) = optional(field.item, state)
          #(state, g.RecordUpdateField(field.label, item))
        })
      #(g.RecordUpdate(location, module, constructor, record, updates), state)
    }
    g.FieldAccess(location:, container:, label:) -> {
      let #(container, state) = expression(container, state)
      #(g.FieldAccess(location, container, label), state)
    }
    g.TupleIndex(location:, tuple:, index:) -> {
      let #(tuple, state) = expression(tuple, state)
      #(g.TupleIndex(location, tuple, index), state)
    }
    g.Case(location:, subjects:, clauses:) -> {
      let #(subjects, state) = expressions(subjects, state)
      let #(state, clauses) =
        list.map_fold(clauses, state, fn(state, clause) {
          let #(guard, state) = optional(clause.guard, state)
          let #(body, state) = expression(clause.body, state)
          #(state, g.Clause(clause.patterns, guard, body))
        })
      #(g.Case(location, subjects, clauses), state)
    }
    g.Call(location:, function:, arguments:) -> {
      let #(function, state) = expression(function, state)
      let #(arguments, state) = fields(arguments, state)
      let #(arguments, state) = lifted(function, arguments, 0, state)
      #(g.Call(location, function, arguments), state)
    }
    g.FnCapture(
      location:,
      label:,
      function:,
      arguments_before:,
      arguments_after:,
    ) -> {
      let #(function, state) = expression(function, state)
      let #(before, state) = fields(arguments_before, state)
      let #(after, state) = fields(arguments_after, state)
      case label {
        Some(_) -> #(
          g.FnCapture(location, label, function, before, after),
          state,
        )
        None -> {
          let #(before, state) = lifted(function, before, 0, state)
          let #(after, state) =
            lifted(function, after, list.length(before) + 1, state)
          #(g.FnCapture(location, label, function, before, after), state)
        }
      }
    }
    // `a |> f(b)` is `f(a, b)`: the arguments of the call stand one place
    // further on.
    g.BinaryOperator(
      location:,
      name: g.Pipe,
      left:,
      right: g.Call(location: at, function:, arguments:),
    ) -> {
      let #(left, state) = expression(left, state)
      let #(function, state) = expression(function, state)
      let #(arguments, state) = fields(arguments, state)
      let #(arguments, state) = lifted(function, arguments, 1, state)
      #(
        g.BinaryOperator(
          location,
          g.Pipe,
          left,
          g.Call(at, function, arguments),
        ),
        state,
      )
    }
    g.BinaryOperator(location:, name:, left:, right:) -> {
      let #(left, state) = expression(left, state)
      let #(right, state) = expression(right, state)
      #(g.BinaryOperator(location, name, left, right), state)
    }
  }
}

// ------------------------------------------------------------ the lift

/// The arguments of a call of `function`, the first of them standing at
/// position `offset`: each function literal that can be lifted is replaced
/// by the name of the function made of it.
fn lifted(
  function: g.Expression,
  arguments: List(g.Field(g.Expression)),
  offset: Int,
  state: State,
) -> #(List(g.Field(g.Expression)), State) {
  let callee = case function {
    g.Variable(name:, ..) ->
      case
        dict.get(state.functions, name),
        list.contains(outer(state.enclosing, None), name)
      {
        Ok(callee), False -> Some(callee)
        _, _ -> None
      }
    _ -> None
  }
  let positional =
    list.all(arguments, fn(field) {
      case field {
        g.UnlabelledField(..) -> True
        _ -> False
      }
    })
  case callee, positional {
    Some(callee), True -> {
      let #(#(state, _), arguments) =
        list.map_fold(arguments, #(state, offset), fn(acc, field) {
          let #(state, index) = acc
          let declared = case list.drop(callee.parameters, index) {
            [g.FunctionParameter(type_: Some(declared), ..), ..] ->
              Some(declared)
            _ -> None
          }
          let item = split.field_item(field)
          let #(item, state) = case as_fn(item), declared {
            Some(literal), Some(g.FunctionType(parameters:, return:, ..)) ->
              one(item, literal, parameters, return, state)
            _, _ -> #(item, state)
          }
          #(#(state, index + 1), g.UnlabelledField(item))
        })
      #(arguments, state)
    }
    _, _ -> #(arguments, state)
  }
}

/// A function literal: its place, parameters, return annotation and body.
type Literal {
  Literal(
    at: g.Span,
    parameters: List(g.FnParameter),
    return: Option(g.Type),
    body: List(g.Statement),
  )
}

/// A `fn`, or a capture whose other arguments are all literals, read as the
/// fn it stands for.
fn as_fn(e: g.Expression) -> Option(Literal) {
  let is_literal = fn(field: g.Field(g.Expression)) {
    case field {
      g.UnlabelledField(g.Int(..))
      | g.UnlabelledField(g.Float(..))
      | g.UnlabelledField(g.String(..)) -> True
      _ -> False
    }
  }
  case e {
    g.Fn(location:, arguments:, return_annotation:, body:) ->
      Some(Literal(location, arguments, return_annotation, body))
    g.FnCapture(
      location:,
      label: None,
      function: g.Variable(..) as function,
      arguments_before:,
      arguments_after:,
    ) ->
      case
        list.all(arguments_before, is_literal)
        && list.all(arguments_after, is_literal)
      {
        True ->
          Some(
            Literal(location, [g.FnParameter(g.Named("_capture"), None)], None, [
              g.Expression(g.Call(
                location,
                function,
                list.flatten([
                  arguments_before,
                  [g.UnlabelledField(g.Variable(location, "_capture"))],
                  arguments_after,
                ]),
              )),
            ]),
          )
        False -> None
      }
    _ -> None
  }
}

/// Lifts one function literal, given the function type its place declares;
/// or leaves the expression as it is.
fn one(
  e: g.Expression,
  literal: Literal,
  declared: List(g.Type),
  return: g.Type,
  state: State,
) -> #(g.Expression, State) {
  let own =
    list.filter_map(literal.parameters, fn(parameter) {
      case parameter.name {
        g.Named(name) -> Ok(name)
        g.Discarded(_) -> Error(Nil)
      }
    })
  let outside = outer(state.enclosing, Some(literal.at))
  let captured =
    list.any(split.variables_of(literal.body), fn(name) {
      !list.contains(own, name) && list.contains(outside, name)
    })
  let fits =
    list.length(declared) == list.length(literal.parameters)
    && list.all([return, ..declared], closed)
  case fits && !captured && !waits(literal.body) {
    False -> #(e, state)
    True -> {
      let count = state.count + 1
      let base = state.enclosing.name
      let name = base <> ":f" <> int.to_string(count)
      let parameters =
        list.map2(literal.parameters, declared, fn(parameter, declared) {
          g.FunctionParameter(
            label: None,
            name: parameter.name,
            type_: Some(option.unwrap(parameter.type_, declared)),
          )
        })
      let function =
        g.Function(
          location: literal.at,
          name:,
          publicity: g.Private,
          parameters:,
          return: Some(option.unwrap(literal.return, return)),
          body: literal.body,
        )
      #(
        g.Variable(literal.at, name),
        State(
          ..state,
          count:,
          out: [function, ..state.out],
          made: dict.insert(
            state.made,
            name,
            split.Made(
              base:,
              suffix: "__f" <> int.to_string(count),
              what: "the anonymous function " <> split.shown(name),
              index: dict.size(state.made),
            ),
          ),
        ),
      )
    }
  }
}

/// A type with no type variable and no hole in it.
fn closed(ty: g.Type) -> Bool {
  case ty {
    g.NamedType(parameters:, ..) -> list.all(parameters, closed)
    g.TupleType(elements:, ..) -> list.all(elements, closed)
    g.FunctionType(parameters:, return:, ..) ->
      list.all([return, ..parameters], closed)
    g.VariableType(..) | g.HoleType(..) -> False
  }
}

/// Does the body wait in a receive of gleam/erlang/process?
fn waits(body: List(g.Statement)) -> Bool {
  let waiting = ["receive", "receive_forever"]
  list.any(everything(g.Block(g.Span(0, 0), body)), fn(e) {
    case e {
      g.FieldAccess(label:, ..) -> list.contains(waiting, label)
      g.Variable(name:, ..) -> list.contains(waiting, name)
      _ -> False
    }
  })
}

fn everything(e: g.Expression) -> List(g.Expression) {
  [e, ..list.flat_map(split.children(e, True), everything)]
}

/// Every name a function binds: its parameters and every variable of a
/// pattern anywhere in its body, closures included, except what the
/// function literal at `skip` binds itself.
fn outer(function: g.Function, skip: Option(g.Span)) -> List(String) {
  let parameters =
    list.filter_map(function.parameters, fn(parameter) {
      case parameter.name {
        g.Named(name) -> Ok(name)
        g.Discarded(_) -> Error(Nil)
      }
    })
  list.append(parameters, bound_in(function.body, skip))
}

fn bound_in(all: List(g.Statement), skip: Option(g.Span)) -> List(String) {
  list.flat_map(all, fn(statement) {
    case statement {
      g.Use(patterns:, function:, ..) ->
        list.append(
          list.flat_map(patterns, fn(p) { split.pattern_names(p.pattern) }),
          bound(function, skip),
        )
      g.Assignment(pattern:, value:, ..) ->
        list.append(split.pattern_names(pattern), bound(value, skip))
      g.Assert(expression:, ..) -> bound(expression, skip)
      g.Expression(e) -> bound(e, skip)
    }
  })
}

fn bound(e: g.Expression, skip: Option(g.Span)) -> List(String) {
  case e {
    g.Fn(location:, arguments:, body:, ..) ->
      case Some(location) == skip {
        True -> []
        False ->
          list.append(
            list.filter_map(arguments, fn(parameter) {
              case parameter.name {
                g.Named(name) -> Ok(name)
                g.Discarded(_) -> Error(Nil)
              }
            }),
            bound_in(body, skip),
          )
      }
    g.Block(statements:, ..) -> bound_in(statements, skip)
    g.Case(subjects:, clauses:, ..) ->
      list.append(
        list.flat_map(subjects, bound(_, skip)),
        list.flat_map(clauses, fn(clause) {
          list.flatten([
            list.flat_map(list.flatten(clause.patterns), split.pattern_names),
            list.flat_map(option.values([clause.guard]), bound(_, skip)),
            bound(clause.body, skip),
          ])
        }),
      )
    _ -> list.flat_map(split.children(e, False), bound(_, skip))
  }
}
