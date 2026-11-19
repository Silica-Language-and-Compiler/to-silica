//// frame: the frames of the to-silica TCP transport contract, version 1, as
//// Gleam types. Only what this proof of concept sends is here: the contract's
//// schema (../contract/tcp_transport_v1.silica) has more node kinds and type
//// entries. `wire` turns these values into the Erlang terms of the schema.

import gleam/list

/// `options.run.mode` of the hello (contract 6.5).
pub type Mode {
  Check
  Transpile
}

/// M1 to M5. The hello's content is fixed by this codex, apart from the mode.
pub type Frame {
  Hello(mode: Mode)
  UnitBegin(seq: Int, unit_name: String, silica_unit: String, source: String)
  FormFrame(seq: Int, unit_name: String, body: Form)
  UnitEnd(seq: Int, unit_name: String, forms: Int)
  End(seq: Int, units: Int)
}

/// One top-level form (contract 9.3).
pub type Form {
  Function(
    name: String,
    arity: Int,
    exported: Bool,
    file: String,
    locations: List(#(Int, Int)),
    nodes: List(Node),
    clauses: List(Int),
    types: List(TypeNode),
    hints: List(Hint),
    /// T7.6: the nodes that depart from the session's lowering choices.
    overrides: List(Override),
  )
  Type(
    name: String,
    params: List(String),
    exported: Bool,
    file: String,
    at_line: Int,
    types: List(TypeNode),
    root: Int,
  )
  Entry(function: String, arity: Int)
  /// Contract T9.17: the node this module runs on, the nodes it talks to and the registered names that cross.
  NodeDecl(
    name: String,
    creation: Int,
    listen_address: String,
    listen_port: Int,
    epmd_port: Int,
    cookie_file: String,
    net_ticktime_s: Int,
    redial_initial_ms: Int,
    redial_max_ms: Int,
    peers: List(NodePeer),
    remotes: List(NodeRemote),
    locals: List(NodeLocal),
  )
  Gap(name: String, file: String, line: Int, construct: String, note: String)
}

/// `role` is "dial" or "listen". `port` 0 means: look it up in EPMD.
pub type NodePeer {
  NodePeer(name: String, host: String, port: Int, role: String)
}

/// A registered name on `peer`; `fields` are the Silica type texts of the message's fields after its tag.
pub type NodeRemote {
  NodeRemote(name: String, peer: String, tag: String, fields: List(String))
}

pub type NodeLocal {
  NodeLocal(name: String, tag: String, fields: List(String))
}

/// A type hint (contract 8.4). The policy is always `default`.
pub type Hint {
  Hint(node: Int, type_: Int, strength: Strength)
}

/// An override of a session choice for one node (contract T7.6). This
/// sender writes one kind: the A4.4 choice `chosen` on the `spawn` of a
/// static child (T9.14b), with the child's restart policy and its
/// supervisor's strategy as the Gleam source writes them.
pub type Override {
  Override(
    node: Int,
    requirement: String,
    choice: String,
    params: List(#(String, String)),
    note: String,
  )
}

/// How sure a hint is (contract 8.2). `Proven`: literally an annotation of
/// the source, which Gleam's type checker verified. `Inferred`: worked out by
/// this codex's own typing pass (README, "Types").
pub type Strength {
  Proven
  Inferred
}

/// A node of a function's node table (contract 9.4). `at` indexes the form's
/// locations; the other integers are node indices, each lower than the index
/// of the node that holds it (T9.2), and -1 where the contract writes `idx?`.
pub type Node {
  Int(at: Int, value: Int)
  Float(at: Int, text: String)
  Text(at: Int, value: String)
  Symbol(at: Int, name: String)
  Boolean(at: Int, value: Bool)
  Tuple(at: Int, elems: List(Int))
  /// H7: the empty list.
  EmptyList(at: Int)
  /// H10: a list; `tail` -1 is a proper list.
  ListOf(at: Int, elems: List(Int), tail: Int)
  Record(at: Int, name: String, fields: List(#(String, Int)), base: Int)
  Field(at: Int, record: Int, name: String)
  Var(at: Int, name: String)
  Wild(at: Int)
  Match(at: Int, pattern: Int, value: Int)
  Block(at: Int, exprs: List(Int))
  Case(at: Int, subject: Int, clauses: List(Int))
  Clause(at: Int, patterns: List(Int), guard: Int, body: Int)
  Op(at: Int, op: String, args: List(Int))
  Call(at: Int, module: String, name: String, args: List(Int))
  Apply(at: Int, function: Int, args: List(Int))
  FunRef(at: Int, module: String, name: String, arity: Int)
  Lambda(at: Int, clauses: List(Int))
  LoopHint(at: Int, body: Int)
  Self(at: Int)
  Spawn(at: Int, function: Int, args: List(Int), link: Bool)
  Send(at: Int, to: Int, message: Int)
  Receive(at: Int, clauses: List(Int), timeout: Int, after: Int)
  Link(at: Int, to: Int)
  ExitSignal(at: Int, to: Int, reason: Int)
  Fail(at: Int, reason: Int)
  /// H38: a name for a process. Written only as a static child: `process`
  /// is a `Spawn` whose arguments are literals (contract T9.14b).
  Register(at: Int, name: String, process: Int)
  /// H39: a send to a registered name (contract T9.14c).
  SendNamed(at: Int, name: String, message: Int)
  /// L1: a call of a Silica builtin by its Silica name (contract T9.16);
  /// `unit` is empty for a builtin.
  SlCall(at: Int, unit: String, name: String, args: List(Int))
  GapNode(at: Int, construct: String, note: String)
}

/// An entry of a form's type table (contract 8.5). Integers are `i64` and
/// floats `f64`, the only widths Gleam has.
pub type TypeNode {
  TInt
  TFloat
  TBool
  TText
  TBytes
  TDynamic
  TSymbols(names: List(String))
  TTuple(elems: List(Int))
  TTagged(tag: String, elems: List(Int))
  TRecord(fields: List(#(String, Int)))
  TList(elem: Int)
  TUnion(alts: List(Int))
  TFun(params: List(Int), result: Int)
  TActor(message: Int)
  TNamed(name: String, args: List(Int))
  TVar(name: String)
}

/// The indices of the nodes a node refers to.
pub fn children(node: Node) -> List(Int) {
  let present = fn(index: Int) {
    case index {
      -1 -> []
      _ -> [index]
    }
  }
  case node {
    Int(..) | Float(..) | Text(..) | Symbol(..) | Boolean(..) -> []
    Var(..) | Wild(..) | FunRef(..) | Self(..) | GapNode(..) -> []
    EmptyList(..) -> []
    ListOf(elems:, tail:, ..) -> list.append(elems, present(tail))
    Tuple(elems:, ..) -> elems
    Record(fields:, base:, ..) ->
      list.append(present(base), list.map(fields, fn(field) { field.1 }))
    Field(record:, ..) -> [record]
    Match(pattern:, value:, ..) -> [pattern, value]
    Block(exprs:, ..) -> exprs
    Case(subject:, clauses:, ..) -> [subject, ..clauses]
    Clause(patterns:, guard:, body:, ..) ->
      list.flatten([patterns, present(guard), [body]])
    Op(args:, ..) -> args
    Call(args:, ..) -> args
    SlCall(args:, ..) -> args
    Apply(function:, args:, ..) -> [function, ..args]
    Lambda(clauses:, ..) -> clauses
    LoopHint(body:, ..) -> [body]
    Spawn(function:, args:, ..) -> [function, ..args]
    Send(to:, message:, ..) -> [to, message]
    Receive(clauses:, timeout:, after:, ..) ->
      list.flatten([clauses, present(timeout), present(after)])
    Link(to:, ..) -> [to]
    ExitSignal(to:, reason:, ..) -> [to, reason]
    Fail(reason:, ..) -> [reason]
    Register(process:, ..) -> [process]
    SendNamed(message:, ..) -> [message]
  }
}

/// The `seq` of a frame; -1 for the hello, which has none (T5.1).
pub fn seq(frame: Frame) -> Int {
  case frame {
    Hello(..) -> -1
    UnitBegin(seq:, ..) -> seq
    FormFrame(seq:, ..) -> seq
    UnitEnd(seq:, ..) -> seq
    End(seq:, ..) -> seq
  }
}

/// How many gaps a frame carries: a gap form is one, and each gap node of a
/// function is one (T9.10).
pub fn gaps(frame: Frame) -> Int {
  case frame {
    FormFrame(body: Gap(..), ..) -> 1
    FormFrame(body: Function(nodes:, ..), ..) ->
      list.count(nodes, fn(node) {
        case node {
          GapNode(..) -> True
          _ -> False
        }
      })
    _ -> 0
  }
}
