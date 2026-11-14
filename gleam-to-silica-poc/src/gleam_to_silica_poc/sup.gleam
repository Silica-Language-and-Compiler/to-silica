//// sup: gleam_otp's static supervisor, read by the sender BEFORE anything is
//// lifted, split, typed or sent (glance syntax in, glance syntax out). A
//// supervisor is gleam_otp's (OTP's) own construct: what
//// `static_supervisor.new`, `add`, `start`, a child specification and a
//// start function mean is this sender's business (contract 1, "What you
//// own"), and the transpiler knows none of it. What the sender sends instead
//// is the contract's STATIC CHILD (T9.14b): a `(:register)` of a `(:spawn)`
//// with literal arguments, which the transpiler writes into the child list
//// its unit's supervisor has from its start.
////
////   fn start_auditor(name: Name(AuditorMessage)) -> … {
////     actor.new(0)                              (start_auditor and start_supervisor
////     |> actor.named(name)                       are not sent: what they say is in
////     |> actor.on_message(handle_auditor)        the static child)
////     |> actor.start
////   }
////   fn start_supervisor(name: Name(AuditorMessage)) -> … {
////     supervisor.new(supervisor.OneForOne)
////     |> supervisor.add(
////       supervision.worker(fn() { start_auditor(name) })
////       |> supervision.restart(supervision.Transient),
////     )
////     |> supervisor.start
////   }
////   pub fn main() -> Nil {
////     let auditor: Name(AuditorMessage) = process.new_name("auditor")
////     let assert Ok(_) = start_supervisor(auditor)
////         -> _static_child("transient", "one_for_one", 0, handle_auditor)
////     …
////
//// `_static_child` is no function: it is a mark the codex turns into nodes
//// (`codex.static_child`). The child's NAME is not read here: it is the one
//// name the unit makes for the handler's message type
//// (`let auditor: Name(AuditorMessage) = process.new_name("auditor")`), which
//// the codex knows with the types.
////
//// WHAT IS READ, and what makes this pass leave a gap in place of the start
//// (its note says which rule the source missed):
////
////   * the start: the statement `let assert Ok(_) = E` of a function body,
////     where E is the supervisor written out, or a call of a function of the
////     module whose whole body is the supervisor written out. A start whose
////     value is used stays a call, which the codex sends as a gap (the
////     supervisor's own process has no node).
////   * the supervisor: `static_supervisor.new(Strategy)`, then
////     `static_supervisor.add(child)` once for each child, optionally
////     `static_supervisor.restart_tolerance(…)` (read and not carried), then
////     `static_supervisor.start`; with the pipe or as nested calls. The
////     strategy is written as its constructor (OneForOne, OneForAll,
////     RestForOne).
////   * a child: `supervision.worker(fn() { S })`, optionally followed by
////     `supervision.restart(Permanent | Transient | Temporary)`; with no
////     restart written it is `permanent`, gleam_otp's default. S is the
////     actor written out, or a call of a function of the module whose whole
////     body is the actor written out.
////   * the actor: `actor.new(state) |> actor.named(name) |>
////     actor.on_message(handler) |> actor.start`, where `state` is a literal
////     (an Int, a Float, True, False, or a constructor without fields: the
////     arguments of a static child are literals, T9.14b) and `handler` is a
////     function of the module, by its name.
////
//// WHAT IS NOT GLEAM'S BEHAVIOUR: README, "A static supervisor".

import glance as g
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_to_silica_poc/split

/// The name of the call this pass writes for a static child:
/// `_static_child("restart", "strategy", state, handler)`.
pub const child_marker = "_static_child"

const supervisor_module = "gleam/otp/static_supervisor"

const supervision_module = "gleam/otp/supervision"

const actor_module = "gleam/otp/actor"

/// What a gap for a supervisor that could not be read is called.
pub const gap_construct = "gleam/otp/static_supervisor.start/1"

type State {
  State(
    imports: Dict(String, String),
    imported: Dict(String, String),
    functions: Dict(String, g.Function),
  )
}

/// One child, as read.
type Child {
  Child(
    restart: String,
    state: g.Expression,
    handler: g.Expression,
    /// The functions of the module that only describe it.
    through: List(String),
  )
}

/// The functions of a module with every supervisor start that can be read
/// replaced by its static children, and the functions that only describe a
/// supervisor that was read (and that nothing else names) taken out. A start
/// that cannot be read is replaced by a gap with the reason. `imports` is
/// import alias -> module, `imported` unqualified imported value -> module.
pub fn functions(
  all: List(g.Function),
  imports: Dict(String, String),
  imported: Dict(String, String),
) -> List(g.Function) {
  let state =
    State(
      imports:,
      imported:,
      functions: dict.from_list(list.map(all, fn(f) { #(f.name, f) })),
    )
  let #(used, rewritten) =
    list.map_fold(all, [], fn(used, function) {
      let #(used, body) =
        list.map_fold(function.body, used, fn(used, statement) {
          case started(statement, state) {
            None -> #(used, [statement])
            Some(#(at, Ok(#(strategy, children, through)))) -> #(
              list.flatten([
                through,
                list.flat_map(children, fn(child) { child.through }),
                used,
              ]),
              list.map(children, fn(child) {
                g.Expression(
                  g.Call(at, g.Variable(at, child_marker), [
                    g.UnlabelledField(g.String(at, child.restart)),
                    g.UnlabelledField(g.String(at, strategy)),
                    g.UnlabelledField(child.state),
                    g.UnlabelledField(child.handler),
                  ]),
                )
              }),
            )
            Some(#(at, Error(why))) -> #(used, [
              g.Expression(
                g.Call(at, g.Variable(at, split.gap_marker), [
                  g.UnlabelledField(g.String(at, gap_construct)),
                  g.UnlabelledField(g.String(
                    at,
                    "a supervisor is sent only as its static children (contract T9.14b), and this one could not be read: "
                      <> why
                      <> " (README, \"A static supervisor\")",
                  )),
                ]),
              ),
            ])
          }
        })
      #(used, g.Function(..function, body: list.flatten(body)))
    })
  let used = list.unique(used)
  // A function that only describes a supervisor that was read is not sent,
  // unless a function that stays still names it.
  list.filter(rewritten, fn(function) {
    !list.contains(used, function.name)
    || list.any(rewritten, fn(other) {
      !list.contains(used, other.name)
      && list.contains(split.variables_of(other.body), function.name)
    })
  })
}

/// Is this statement a supervisor start whose value is not used? Then its
/// place, and what was read (strategy, children, the function that holds
/// the supervisor) or why it could not be.
fn started(
  statement: g.Statement,
  state: State,
) -> Option(#(g.Span, Result(#(String, List(Child), List(String)), String))) {
  case statement {
    g.Assignment(
      location:,
      kind: g.LetAssert(None),
      pattern: g.PatternVariant(
        module: None,
        constructor: "Ok",
        arguments: [g.UnlabelledField(g.PatternDiscard(..))],
        with_spread: False,
        ..,
      ),
      annotation: None,
      value:,
    ) ->
      case supervisor_of(value, state) {
        Some(#(builder, through)) ->
          Some(#(
            location,
            result.map(supervisor(builder, state), fn(read) {
              #(read.0, read.1, through)
            }),
          ))
        None -> None
      }
    _ -> None
  }
}

/// `static_supervisor.start(builder)`, written here or as the whole body of
/// the function of the module that is called here: the builder expression.
fn supervisor_of(
  e: g.Expression,
  state: State,
) -> Option(#(g.Expression, List(String))) {
  case called(e, state) {
    Some(#(Some(module), "start", [builder])) if module == supervisor_module ->
      Some(#(builder, []))
    Some(#(None, name, _)) ->
      case dict.get(state.functions, name) {
        Ok(g.Function(body: [g.Expression(inner)], ..)) ->
          case called(inner, state) {
            Some(#(Some(module), "start", [builder]))
              if module == supervisor_module
            -> Some(#(builder, [name]))
            _ -> None
          }
        _ -> None
      }
    _ -> None
  }
}

/// A call, with its pipes read as the calls they are: the module of the
/// called function (None: a name of this module), its name, its arguments.
fn called(
  e: g.Expression,
  state: State,
) -> Option(#(Option(String), String, List(g.Expression))) {
  case e {
    g.BinaryOperator(location:, name: g.Pipe, left:, right:) ->
      called(split.pipe(location, left, right), state)
    g.Call(function:, arguments:, ..) -> {
      let arguments = list.map(arguments, split.field_item)
      case function {
        g.FieldAccess(container: g.Variable(name: alias, ..), label:, ..) ->
          case dict.get(state.imports, alias) {
            Ok(module) -> Some(#(Some(module), label, arguments))
            Error(Nil) -> None
          }
        g.Variable(name:, ..) ->
          case dict.get(state.imported, name) {
            Ok(module) -> Some(#(Some(module), name, arguments))
            Error(Nil) -> Some(#(None, name, arguments))
          }
        _ -> None
      }
    }
    _ -> None
  }
}

/// A constructor of another module, or one imported unqualified, by name.
fn constructor(e: g.Expression) -> Option(String) {
  case e {
    g.FieldAccess(label:, ..) -> Some(label)
    g.Variable(name:, ..) -> Some(name)
    _ -> None
  }
}

/// The builder of a supervisor: its strategy and its children, in order.
fn supervisor(
  e: g.Expression,
  state: State,
) -> Result(#(String, List(Child)), String) {
  let not_a_supervisor =
    "the supervisor is not written as static_supervisor.new(strategy), static_supervisor.add(child) for each child, static_supervisor.start"
  case called(e, state) {
    Some(#(Some(module), "new", [strategy])) if module == supervisor_module ->
      case constructor(strategy) {
        Some("OneForOne") -> Ok(#("one_for_one", []))
        Some("OneForAll") -> Ok(#("one_for_all", []))
        Some("RestForOne") -> Ok(#("rest_for_one", []))
        _ ->
          Error(
            "the strategy given to static_supervisor.new is not written as its constructor (OneForOne, OneForAll, RestForOne)",
          )
      }
    Some(#(Some(module), "add", [builder, spec]))
      if module == supervisor_module
    -> {
      use #(strategy, children) <- result.try(supervisor(builder, state))
      use child <- result.map(child(spec, state))
      #(strategy, list.append(children, [child]))
    }
    // How many restarts in how long: read, and not carried (contract
    // T9.14b: BEES A4.4 has no parameter for it).
    Some(#(Some(module), "restart_tolerance", [builder, ..]))
      if module == supervisor_module
    -> supervisor(builder, state)
    Some(#(Some(module), "auto_shutdown", _)) if module == supervisor_module ->
      Error(
        "static_supervisor.auto_shutdown has no place in a static child (contract T9.14b)",
      )
    _ -> Error(not_a_supervisor)
  }
}

/// One child specification.
fn child(e: g.Expression, state: State) -> Result(Child, String) {
  case called(e, state) {
    Some(#(Some(module), "restart", [spec, restart]))
      if module == supervision_module
    -> {
      use read <- result.try(child(spec, state))
      case constructor(restart) {
        Some("Permanent") -> Ok(Child(..read, restart: "permanent"))
        Some("Transient") -> Ok(Child(..read, restart: "transient"))
        Some("Temporary") -> Ok(Child(..read, restart: "temporary"))
        _ ->
          Error(
            "the restart given to supervision.restart is not written as its constructor (Permanent, Transient, Temporary)",
          )
      }
    }
    Some(#(Some(module), "worker", [g.Fn(arguments: [], body:, ..)]))
      if module == supervision_module
    ->
      case body {
        [g.Expression(start)] -> {
          use #(state_, handler, through) <- result.map(actor(start, state))
          // gleam_otp's default for a worker.
          Child(restart: "permanent", state: state_, handler:, through:)
        }
        _ ->
          Error(
            "the function given to supervision.worker is not one expression: the actor's start, or a call of the function of this module that is it",
          )
      }
    Some(#(Some(module), "worker", _)) if module == supervision_module ->
      Error(
        "supervision.worker is not given a function literal of no parameters (fn() { … })",
      )
    Some(#(Some(module), "supervisor", _)) if module == supervision_module ->
      Error("a child that is a supervisor is not read")
    Some(#(Some(module), name, _)) if module == supervision_module ->
      Error(
        "supervision."
        <> name
        <> " has no place in a static child (contract T9.14b)",
      )
    _ ->
      Error(
        "a child is not written as supervision.worker(fn() { … }), with or without supervision.restart(…)",
      )
  }
}

/// The start of a child's actor, written out or as the whole body of the
/// function of the module that is called: its state, its handler, and that
/// function's name.
fn actor(
  e: g.Expression,
  state: State,
) -> Result(#(g.Expression, g.Expression, List(String)), String) {
  let not_an_actor =
    "a child's start is not actor.new(state) |> actor.named(name) |> actor.on_message(handler) |> actor.start, written out or as the whole body of a function of this module"
  case called(e, state) {
    Some(#(Some(module), "start", [builder])) if module == actor_module -> {
      use read <- result.try(actor_builder(builder, state))
      case read {
        #(_, _, False) ->
          Error(
            "a child's actor has no name (actor.named): a static child is registered under a name, and is reached by it (contract T9.14b)",
          )
        #(_, None, _) ->
          Error("a child's actor has no handler (actor.on_message)")
        #(state_, Some(handler), True) -> Ok(#(state_, handler, []))
      }
    }
    Some(#(None, name, _)) ->
      case dict.get(state.functions, name) {
        Ok(g.Function(body: [g.Expression(inner)], ..)) ->
          case called(inner, state) {
            Some(#(Some(module), "start", _)) if module == actor_module ->
              result.map(actor(inner, state), fn(read) {
                #(read.0, read.1, [name])
              })
            _ -> Error(not_an_actor)
          }
        _ -> Error(not_an_actor)
      }
    _ -> Error(not_an_actor)
  }
}

/// `actor.new(state)`, `actor.named(name)`, `actor.on_message(handler)`, in
/// any order after `new`: the state, the handler, and whether it is named.
fn actor_builder(
  e: g.Expression,
  state: State,
) -> Result(#(g.Expression, Option(g.Expression), Bool), String) {
  case called(e, state) {
    Some(#(Some(module), "new", [state_])) if module == actor_module ->
      case literal(state_) {
        True -> Ok(#(state_, None, False))
        False ->
          Error(
            "the state given to actor.new is not a literal (an Int, a Float, True, False or a constructor without fields): the arguments of a static child are literals (contract T9.14b)",
          )
      }
    Some(#(Some(module), "named", [builder, _name])) if module == actor_module ->
      result.map(actor_builder(builder, state), fn(read) {
        #(read.0, read.1, True)
      })
    Some(#(Some(module), "on_message", [builder, handler]))
      if module == actor_module
    ->
      case handler {
        g.Variable(..) ->
          result.map(actor_builder(builder, state), fn(read) {
            #(read.0, Some(handler), read.2)
          })
        _ ->
          Error(
            "the handler given to actor.on_message is not a function of this module, by its name",
          )
      }
    Some(#(Some(module), name, _)) if module == actor_module ->
      Error(
        "actor."
        <> name
        <> " is not lowered for a supervised actor (README, \"gleam_otp actors\")",
      )
    _ ->
      Error(
        "a child's actor is not written as actor.new(state) |> actor.named(name) |> actor.on_message(handler)",
      )
  }
}

/// A literal the contract's static child takes as an argument (T9.14b).
fn literal(e: g.Expression) -> Bool {
  case e {
    g.Int(..) | g.Float(..) -> True
    g.Variable(name:, ..) ->
      case string.first(name) {
        Ok(first) -> string.uppercase(first) == first && first != "_"
        Error(Nil) -> False
      }
    _ -> False
  }
}
