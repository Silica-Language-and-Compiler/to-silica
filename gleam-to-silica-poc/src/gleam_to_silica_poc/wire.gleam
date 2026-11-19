//// wire: frames as the Erlang terms of the contract's schema
//// (../contract/tcp_transport_v1.silica), and as bytes.
////
//// Records are maps with atom keys and exactly the listed keys (T4.5); tagged
//// tuples have the atom tag first (T4.6); identifiers are binaries, never
//// atoms (T4.4); a type entry with no fields is a bare atom (contract 8.5).

import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam_to_silica_poc/frame.{
  type Form, type Frame, type Node, type TypeNode,
}
import gleam_to_silica_poc/term.{atom, ints, record, tagged}

pub const language = "gleam"

/// The unit prefix of this language (T5.2, BEES A1.1).
pub const prefix = "gl_"

pub const codex = "gleam-to-silica-poc"

pub const codex_version = "0.1.0"

/// The largest frame this sender is prepared to send (T4.3).
pub const max_frame = 1_048_576

/// One frame's bytes without the 4-byte length, which gen_tcp's
/// `{packet, 4}` adds (T4.1, T4.2).
pub fn encode(frame: Frame) -> BitArray {
  term.encode(to_term(frame))
}

pub fn to_term(frame: Frame) -> Dynamic {
  case frame {
    frame.Hello(mode:) -> hello(mode)
    frame.UnitBegin(seq:, unit_name:, silica_unit:, source:) ->
      tagged("unit_begin", [
        record([
          #("seq", dynamic.int(seq)),
          #("unit_name", dynamic.string(unit_name)),
          #("silica_unit", dynamic.string(silica_unit)),
          #("source", dynamic.string(source)),
        ]),
      ])
    frame.FormFrame(seq:, unit_name:, body:) ->
      tagged("form", [
        record([
          #("seq", dynamic.int(seq)),
          #("unit_name", dynamic.string(unit_name)),
          #("body", form(body)),
        ]),
      ])
    frame.UnitEnd(seq:, unit_name:, forms:) ->
      tagged("unit_end", [
        record([
          #("seq", dynamic.int(seq)),
          #("unit_name", dynamic.string(unit_name)),
          #("forms", dynamic.int(forms)),
        ]),
      ])
    frame.End(seq:, units:) ->
      tagged("end", [
        record([#("seq", dynamic.int(seq)), #("units", dynamic.int(units))]),
      ])
  }
}

/// M7: the only frame of a release connection (T6.13). It is not part of a
/// session, so it is not a `Frame`.
pub fn release(session: String) -> BitArray {
  term.encode(
    tagged("release", [record([#("session", dynamic.string(session))])]),
  )
}

/// M1. A `bees` session: the process constructs need that profile (T7.10).
/// One choice for each BEES requirement (T7.1), the same eleven as the Erlang
/// proof of concept, and the recommended hint policy (T8.4).
fn hello(mode: frame.Mode) -> Dynamic {
  tagged("hello", [
    record([
      #("contract", dynamic.int(1)),
      #("session", dynamic.string("")),
      #(
        "sender",
        record([
          #("language", dynamic.string(language)),
          #("prefix", dynamic.string(prefix)),
          #("codex", dynamic.string(codex)),
          #("codex_version", dynamic.string(codex_version)),
        ]),
      ),
      #(
        "options",
        record([
          #("profile", atom("bees")),
          #("choices", dynamic.list(choices())),
          #(
            "hints",
            record([
              #("proven", atom("trust")),
              #("declared", atom("check")),
              #("inferred", atom("check")),
            ]),
          ),
          #(
            "run",
            record([
              #(
                "mode",
                atom(case mode {
                  frame.Check -> "check"
                  frame.Transpile -> "transpile"
                }),
              ),
              #("max_frame", dynamic.int(max_frame)),
            ]),
          ),
        ]),
      ),
    ]),
  ])
}

fn choices() -> List(Dynamic) {
  [
    choice("a3_2", "default", [#("release", "release_on_return")]),
    choice("a3_3", "phase_field", []),
    choice("a3_4", "back_edge", []),
    choice("a4_2", "single_pool", [#("pool_size", "1024")]),
    choice("a4_3", "uniform_shape", []),
    choice("a4_4", "chosen", [
      #("restart", "transient"),
      #("strategy", "one_for_one"),
    ]),
    choice("a5_1", "result_values", []),
    choice("a5_4", "accept_sender_death", []),
    choice("a5_5", "supervisor_request", []),
    choice("a6_8", "lookup_tables", []),
    choice("a7_1", "module_table", []),
  ]
}

fn choice(
  requirement: String,
  name: String,
  params: List(#(String, String)),
) -> Dynamic {
  record([
    #("requirement", atom(requirement)),
    #("choice", atom(name)),
    #(
      "params",
      dynamic.list(
        list.map(params, fn(param) {
          dynamic.array([dynamic.string(param.0), dynamic.string(param.1)])
        }),
      ),
    ),
    #("note", dynamic.string("")),
  ])
}

fn form(body: Form) -> Dynamic {
  case body {
    frame.Function(
      name:,
      arity:,
      exported:,
      file:,
      locations:,
      nodes:,
      clauses:,
      types:,
      hints:,
      overrides:,
    ) ->
      tagged("function", [
        record([
          #(
            "head",
            record([
              #("name", dynamic.string(name)),
              #("arity", dynamic.int(arity)),
              #("exported", dynamic.bool(exported)),
              #("file", dynamic.string(file)),
            ]),
          ),
          #(
            "code",
            record([
              #(
                "locations",
                dynamic.list(
                  list.map(locations, fn(location) {
                    dynamic.array([
                      dynamic.int(location.0),
                      dynamic.int(location.1),
                    ])
                  }),
                ),
              ),
              #("nodes", dynamic.list(list.map(nodes, node))),
              #("clauses", ints(clauses)),
            ]),
          ),
          #("types", dynamic.list(list.map(types, type_node))),
          #(
            "notes",
            record([
              #("hints", dynamic.list(list.map(hints, hint))),
              #("overrides", dynamic.list(list.map(overrides, override))),
            ]),
          ),
        ]),
      ])
    frame.Type(name:, params:, exported:, file:, at_line:, types:, root:) ->
      tagged("type", [
        record([
          #(
            "head",
            record([
              #("name", dynamic.string(name)),
              #("params", term.strings(params)),
              #("exported", dynamic.bool(exported)),
              #("file", dynamic.string(file)),
            ]),
          ),
          #("at_line", dynamic.int(at_line)),
          #("types", dynamic.list(list.map(types, type_node))),
          #("root", dynamic.int(root)),
        ]),
      ])
    frame.NodeDecl(
      name:,
      creation:,
      listen_address:,
      listen_port:,
      epmd_port:,
      cookie_file:,
      net_ticktime_s:,
      redial_initial_ms:,
      redial_max_ms:,
      peers:,
      remotes:,
      locals:,
    ) ->
      tagged("node", [
        record([
          #("name", dynamic.string(name)),
          #(
            "timing",
            record([
              #("creation", dynamic.int(creation)),
              #("net_ticktime_s", dynamic.int(net_ticktime_s)),
              #("redial_initial_ms", dynamic.int(redial_initial_ms)),
              #("redial_max_ms", dynamic.int(redial_max_ms)),
            ]),
          ),
          #(
            "net",
            record([
              #("listen_address", dynamic.string(listen_address)),
              #("listen_port", dynamic.int(listen_port)),
              #("epmd_port", dynamic.int(epmd_port)),
              #("cookie_file", dynamic.string(cookie_file)),
            ]),
          ),
          #(
            "tables",
            record([
              #(
                "peers",
                dynamic.list(
                  list.map(peers, fn(p) {
                    record([
                      #("name", dynamic.string(p.name)),
                      #("host", dynamic.string(p.host)),
                      #("port", dynamic.int(p.port)),
                      #("role", term.atom(p.role)),
                    ])
                  }),
                ),
              ),
              #(
                "remotes",
                dynamic.list(
                  list.map(remotes, fn(r) {
                    record([
                      #("name", dynamic.string(r.name)),
                      #("peer", dynamic.string(r.peer)),
                      #("tag", dynamic.string(r.tag)),
                      #("fields", term.strings(r.fields)),
                    ])
                  }),
                ),
              ),
              #(
                "locals",
                dynamic.list(
                  list.map(locals, fn(l) {
                    record([
                      #("name", dynamic.string(l.name)),
                      #("tag", dynamic.string(l.tag)),
                      #("fields", term.strings(l.fields)),
                    ])
                  }),
                ),
              ),
            ]),
          ),
        ]),
      ])
    frame.Entry(function:, arity:) ->
      tagged("entry", [
        record([
          #("function", dynamic.string(function)),
          #("arity", dynamic.int(arity)),
        ]),
      ])
    frame.Gap(name:, file:, line:, construct:, note:) ->
      tagged("gap", [
        record([
          #("name", dynamic.string(name)),
          #(
            "place",
            record([
              #("file", dynamic.string(file)),
              #("line", dynamic.int(line)),
            ]),
          ),
          #("construct", dynamic.string(construct)),
          #("note", dynamic.string(note)),
        ]),
      ])
  }
}

/// T7.6: `{ node, requirement, choice, detail: { params, note } }`.
fn override(override: frame.Override) -> Dynamic {
  record([
    #("node", dynamic.int(override.node)),
    #("requirement", atom(override.requirement)),
    #("choice", atom(override.choice)),
    #(
      "detail",
      record([
        #(
          "params",
          dynamic.list(
            list.map(override.params, fn(param) {
              dynamic.array([dynamic.string(param.0), dynamic.string(param.1)])
            }),
          ),
        ),
        #("note", dynamic.string(override.note)),
      ]),
    ),
  ])
}

fn hint(hint: frame.Hint) -> Dynamic {
  record([
    #("node", dynamic.int(hint.node)),
    #("type", dynamic.int(hint.type_)),
    #(
      "strength",
      atom(case hint.strength {
        frame.Proven -> "proven"
        frame.Inferred -> "inferred"
      }),
    ),
    #("policy", atom("default")),
  ])
}

fn node(node: Node) -> Dynamic {
  let int = dynamic.int
  let text = dynamic.string
  case node {
    frame.Int(at:, value:) -> tagged("int", [int(at), int(value)])
    frame.Float(at:, text: digits) -> tagged("float", [int(at), text(digits)])
    frame.Text(at:, value:) -> tagged("text", [int(at), text(value)])
    frame.Symbol(at:, name:) -> tagged("symbol", [int(at), text(name)])
    frame.Boolean(at:, value:) ->
      tagged("boolean", [int(at), dynamic.bool(value)])
    frame.Tuple(at:, elems:) -> tagged("tuple", [int(at), ints(elems)])
    frame.Record(at:, name:, fields:, base:) ->
      tagged("record", [int(at), text(name), pairs(fields), int(base)])
    frame.Field(at:, record:, name:) ->
      tagged("field", [int(at), int(record), text(name)])
    frame.Var(at:, name:) -> tagged("var", [int(at), text(name)])
    frame.Wild(at:) -> tagged("wild", [int(at)])
    frame.Match(at:, pattern:, value:) ->
      tagged("match", [int(at), int(pattern), int(value)])
    frame.Block(at:, exprs:) -> tagged("block", [int(at), ints(exprs)])
    frame.Case(at:, subject:, clauses:) ->
      tagged("case", [int(at), int(subject), ints(clauses)])
    frame.Clause(at:, patterns:, guard:, body:) ->
      tagged("clause", [int(at), ints(patterns), int(guard), int(body)])
    frame.Op(at:, op:, args:) -> tagged("op", [int(at), text(op), ints(args)])
    frame.Call(at:, module:, name:, args:) ->
      tagged("call", [int(at), text(module), text(name), ints(args)])
    frame.Apply(at:, function:, args:) ->
      tagged("apply", [int(at), int(function), ints(args)])
    frame.FunRef(at:, module:, name:, arity:) ->
      tagged("fun_ref", [int(at), text(module), text(name), int(arity)])
    frame.Lambda(at:, clauses:) -> tagged("lambda", [int(at), ints(clauses)])
    frame.LoopHint(at:, body:) -> tagged("loop_hint", [int(at), int(body)])
    frame.Self(at:) -> tagged("self", [int(at)])
    frame.Spawn(at:, function:, args:, link:) ->
      tagged("spawn", [int(at), int(function), ints(args), dynamic.bool(link)])
    frame.Send(at:, to:, message:) ->
      tagged("send", [int(at), int(to), int(message)])
    frame.Receive(at:, clauses:, timeout:, after:) ->
      tagged("receive", [int(at), ints(clauses), int(timeout), int(after)])
    frame.Link(at:, to:) -> tagged("link", [int(at), int(to)])
    frame.ExitSignal(at:, to:, reason:) ->
      tagged("exit_signal", [int(at), int(to), int(reason)])
    frame.Fail(at:, reason:) -> tagged("fail", [int(at), int(reason)])
    frame.Register(at:, name:, process:) ->
      tagged("register", [int(at), text(name), int(process)])
    frame.SendNamed(at:, name:, message:) ->
      tagged("send_named", [int(at), text(name), int(message)])
    frame.EmptyList(at:) -> tagged("nil", [int(at)])
    frame.ListOf(at:, elems:, tail:) ->
      tagged("list", [int(at), ints(elems), int(tail)])
    frame.SlCall(at:, unit:, name:, args:) ->
      tagged("sl_call", [int(at), text(unit), text(name), ints(args)])
    frame.GapNode(at:, construct:, note:) ->
      tagged("gap_node", [int(at), text(construct), text(note)])
  }
}

fn type_node(entry: TypeNode) -> Dynamic {
  case entry {
    frame.TInt -> tagged("t_int", [atom("i64")])
    frame.TFloat -> tagged("t_float", [atom("f64")])
    frame.TBool -> tagged("t_basic", [atom("boolean")])
    frame.TText -> tagged("t_basic", [atom("text")])
    frame.TBytes -> tagged("t_basic", [atom("bytes")])
    frame.TDynamic -> tagged("t_basic", [atom("dynamic")])
    frame.TSymbols(names:) -> tagged("t_symbols", [term.strings(names)])
    frame.TTuple(elems:) -> tagged("t_tuple", [ints(elems)])
    frame.TTagged(tag:, elems:) ->
      tagged("t_tagged", [dynamic.string(tag), ints(elems)])
    frame.TRecord(fields:) -> tagged("t_record", [pairs(fields)])
    frame.TList(elem:) -> tagged("t_list", [dynamic.int(elem)])
    frame.TUnion(alts:) -> tagged("t_union", [ints(alts)])
    frame.TFun(params:, result:) ->
      tagged("t_fun", [ints(params), dynamic.int(result)])
    frame.TActor(message:) -> tagged("t_actor", [dynamic.int(message)])
    frame.TNamed(name:, args:) ->
      tagged("t_named", [dynamic.string(name), ints(args)])
    frame.TVar(name:) -> tagged("t_var", [dynamic.string(name)])
  }
}

fn pairs(fields: List(#(String, Int))) -> Dynamic {
  dynamic.list(
    list.map(fields, fn(field) {
      dynamic.array([dynamic.string(field.0), dynamic.int(field.1)])
    }),
  )
}
