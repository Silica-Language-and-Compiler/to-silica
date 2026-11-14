//// The tests of gleam-to-silica-poc. Run them with test/run_test.sh [port].
////
////   offline: every frame made from examples/demo.gleam passes the contract's
////            Erlang binding checker, the tables are in post-order (T9.2),
////            seq counts from 0 (T5.1), the examples have no gap and the
////            gaps of test/fixtures/gaps.gleam are the expected ones
////            (T9.10), and the bytes are deterministic;
////   loopback: the sender's protocol (welcome, credit, stored, result)
////            against stand-in servers inside the test. They are not the
////            transpiler;
////   online:  when TO_SILICA_PORT is set, the same frames go to a transpiler
////            in check mode (contract 6.5) and must end with status ok.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleam_to_silica_poc/codex.{Source}
import gleam_to_silica_poc/frame.{type Frame}
import gleam_to_silica_poc/names
import gleam_to_silica_poc/sender
import gleam_to_silica_poc/term.{atom, record, tagged}
import gleam_to_silica_poc/wire
import gleeunit
import simplifile

const example = "examples/demo.gleam"

/// The examples hold only what is sent with no gap; what this sender
/// answers with a gap is in the fixture.
const example_gaps = 0

const gaps_fixture = "test/fixtures/gaps.gleam"

pub fn main() -> Nil {
  gleeunit.main()
}

fn example_frames() -> List(Frame) {
  let assert Ok(text) = simplifile.read(example)
  let assert Ok(frames) = codex.session([Source(example, text)], frame.Check)
  frames
}

fn forms(frames: List(Frame)) -> List(frame.Form) {
  list.filter_map(frames, fn(f) {
    case f {
      frame.FormFrame(body:, ..) -> Ok(body)
      _ -> Error(Nil)
    }
  })
}

fn nodes(frames: List(Frame)) -> List(frame.Node) {
  list.flat_map(forms(frames), fn(form) {
    case form {
      frame.Function(nodes:, ..) -> nodes
      _ -> []
    }
  })
}

fn unit_of(text: String) -> List(Frame) {
  let assert Ok(frames) = codex.unit(Source("src/sample.gleam", text), 0)
  frames
}

// ------------------------------------------------------------ the example

/// test/demo.gleam is the copy of the example that `gleam test` compiles, so
/// the example is Gleam that type-checks. The two must be the same file.
pub fn example_is_the_compiled_copy_test() {
  let assert Ok(shown) = simplifile.read(example)
  let assert Ok(compiled) = simplifile.read("test/demo.gleam")
  assert shown == compiled
}

// ------------------------------------------------------------ offline

@external(erlang, "code", "ensure_loaded")
fn ensure_loaded(module: Dynamic) -> Dynamic

@external(erlang, "check_frame", "check")
fn check_frame(term: Dynamic) -> Dynamic

/// Every frame has the shape of the schema, before and after a trip through
/// the external term format.
pub fn every_frame_passes_check_frame_test() {
  list.each(["tcp_transport_v1", "check_frame"], fn(module) {
    let loaded = ensure_loaded(atom(module))
    case loaded == dynamic.array([atom("module"), atom(module)]) {
      True -> Nil
      False ->
        panic as "the contract's Erlang binding is not on the code path: run test/run_test.sh"
    }
  })
  let frames = example_frames()
  assert list.length(frames) > 30
  list.each(frames, fn(f) {
    let term = wire.to_term(f)
    let decoded = term.decode(wire.encode(f))
    assert decoded == term
    let answer = check_frame(decoded)
    case answer == atom("ok") {
      True -> Nil
      False ->
        panic as {
          "check_frame rejects seq "
          <> int.to_string(frame.seq(f))
          <> ": "
          <> string.inspect(answer)
        }
    }
  })
}

/// T9.2 and T9.3: in every node table a child's index is below its parent's,
/// every node has its own location (`at` is its index), and the function's
/// clauses are clause nodes. The type tables are in post-order as well.
pub fn children_come_before_parents_test() {
  list.each(forms(example_frames()), fn(form) {
    case form {
      frame.Function(nodes:, locations:, clauses:, types:, hints:, arity:, ..) -> {
        assert list.length(locations) == list.length(nodes)
        list.index_map(nodes, fn(node, index) {
          assert node.at == index
          assert list.all(frame.children(node), fn(child) {
            child >= 0 && child < index
          })
        })
        assert list.all(clauses, fn(index) {
          case list.drop(nodes, index) {
            [frame.Clause(..), ..] -> True
            _ -> False
          }
        })
        assert types_in_post_order(types)
        // T8.5: a hint names a node of the form (or -1, the signature) and
        // an entry of its type table; a node has at most one hint. T8.10 (a):
        // every function form has a signature hint, a `t_fun` with one
        // parameter for each parameter of the function.
        assert list.all(hints, fn(hint) {
          hint.node >= -1
          && hint.node < list.length(nodes)
          && hint.type_ >= 0
          && hint.type_ < list.length(types)
        })
        let hinted = list.map(hints, fn(hint) { hint.node })
        assert list.unique(hinted) == hinted
        let assert [frame.Hint(node: -1, type_: signature, ..), ..] = hints
        let assert [frame.TFun(params:, ..), ..] = list.drop(types, signature)
        assert list.length(params) == arity
        // The table has each entry once.
        assert list.unique(types) == types
      }
      frame.Type(types:, root:, ..) -> {
        assert types_in_post_order(types)
        assert root == list.length(types) - 1
      }
      _ -> Nil
    }
  })
}

fn types_in_post_order(types: List(frame.TypeNode)) -> Bool {
  list.index_map(types, fn(entry, index) {
    let children = case entry {
      frame.TTuple(elems:) -> elems
      frame.TTagged(elems:, ..) -> elems
      frame.TRecord(fields:) -> list.map(fields, fn(field) { field.1 })
      frame.TList(elem:) -> [elem]
      frame.TActor(message:) -> [message]
      frame.TUnion(alts:) -> alts
      frame.TFun(params:, result:) -> [result, ..params]
      frame.TNamed(args:, ..) -> args
      _ -> []
    }
    list.all(children, fn(child) { child >= 0 && child < index })
  })
  |> list.all(fn(ok) { ok })
}

/// T5.1: unit_begin, forms, unit_end and end are numbered from 0 with no
/// hole; the hello has no seq. T5.2: the unit asks for a prefixed name.
pub fn seq_counts_from_zero_test() {
  let frames = example_frames()
  let assert [frame.Hello(frame.Check), begin, ..rest] = frames
  assert list.index_map(rest, fn(f, index) { frame.seq(f) - index })
    == list.repeat(1, list.length(rest))
  assert begin == frame.UnitBegin(0, "demo", "gl_demo", "demo.gleam")
  let count = list.length(forms(frames))
  let assert [frame.End(seq: last, units: 1), frame.UnitEnd(forms:, ..), ..] =
    list.reverse(frames)
  assert forms == count
  assert last == count + 2
}

/// The example programs are sent with no gap at all.
pub fn examples_have_no_gap_test() {
  assert int.sum(list.map(example_frames(), frame.gaps)) == example_gaps
  assert int.sum(list.map(actors_frames(), frame.gaps)) == 0
}

/// What this sender answers with a gap (test/fixtures/gaps.gleam): the gap
/// forms and the gap nodes, in the order they are sent. A supervisor that
/// cannot be read is a gap whose note names the rule the source missed.
pub fn out_of_scope_constructs_are_gaps_test() {
  let assert Ok(text) = simplifile.read(gaps_fixture)
  let assert Ok(frames) =
    codex.session([Source(gaps_fixture, text)], frame.Check)
  list.each(frames, fn(f) {
    assert check_frame(term.decode(wire.encode(f))) == atom("ok")
  })
  let gap_forms =
    list.filter_map(forms(frames), fn(form) {
      case form {
        frame.Gap(name:, ..) -> Ok(name)
        _ -> Error(Nil)
      }
    })
  assert gap_forms == ["is_distributed", "receive_message", "late_name"]
  let gap_nodes =
    list.filter_map(nodes(frames), fn(node) {
      case node {
        frame.GapNode(construct:, note:, ..) -> Ok(#(construct, note))
        _ -> Error(Nil)
      }
    })
  let supervisor = "gleam/otp/static_supervisor.start/1"
  assert list.map(gap_nodes, fn(gap) { gap.0 })
    == ["tuple index", supervisor, supervisor, "pipe into .start"]
  let assert [_, #(_, unnamed), #(_, computed), #(_, kept)] = gap_nodes
  assert string.contains(unnamed, "a child's actor has no name (actor.named)")
  assert string.contains(
    computed,
    "the state given to actor.new is not a literal",
  )
  assert string.contains(
    kept,
    "it is read where it is started by a statement `let assert Ok(_) = ...`, whose value is not used",
  )
  list.each([unnamed, computed, kept], fn(note) {
    assert string.contains(note, "contract T9.14b")
    assert string.contains(note, "README, \"A static supervisor\"")
  })
  let assert Ok(frame.Gap(note: late, ..)) =
    list.find(forms(frames), fn(form) {
      case form {
        frame.Gap(name: "late_name", ..) -> True
        _ -> False
      }
    })
  assert string.contains(
    late,
    "this unit does not make exactly one name for this message type",
  )
  assert int.sum(list.map(frames, frame.gaps)) == 7
  // The closure and the linked spawn are sent as nodes: the transpiler
  // answers them with gaps of its own.
  let kinds =
    nodes(frames)
    |> list.map(fn(node) {
      let assert [kind, ..] = string.split(string.inspect(node), "(")
      kind
    })
    |> list.unique
  list.each(["Lambda", "Link", "Spawn", "GapNode"], fn(kind) {
    assert list.contains(kinds, kind)
  })
}

/// The example uses the node kinds the codex writes for what is not a
/// gleam_otp actor (`actors_gaps_test` has `Register`, `SendNamed`,
/// `SlCall` and `LoopHint`; the fixture has `Link` and `GapNode`).
pub fn example_covers_the_subset_test() {
  let kinds =
    nodes(example_frames())
    |> list.map(fn(node) {
      let assert [kind, ..] = string.split(string.inspect(node), "(")
      kind
    })
    |> list.unique
    |> list.sort(string.compare)
  assert kinds
    == [
      "Apply", "Block", "Boolean", "Call", "Case", "Clause", "EmptyList", "Fail",
      "Field", "Float", "FunRef", "Int", "Lambda", "ListOf", "Match", "Op",
      "Receive", "Record", "Self", "Send", "Spawn", "Symbol", "Text", "Tuple",
      "Var", "Wild",
    ]
}

/// The process side of the example: a subject is the process that owns it
/// (`self`), the spawn's function is a closure of one call whose arguments
/// the spawner evaluates (contract T9.14), and `ping_pong`, a public
/// function, keeps its receive: it is a process function itself. A `let`
/// writes its value first, then its pattern.
pub fn ping_pong_test() {
  let assert Ok(frame.Function(nodes:, exported: True, ..)) =
    list.find(forms(example_frames()), fn(form) {
      case form {
        frame.Function(name: "ping_pong", ..) -> True
        _ -> False
      }
    })
  let assert [
    frame.Var(0, "n"),
    frame.Self(1),
    frame.Var(2, "answers"),
    frame.Match(3, 2, 1),
    frame.Var(4, "answers"),
    frame.Var(5, "n"),
    frame.Call(6, "", "pong", [4, 5]),
    frame.Clause(7, [], -1, 6),
    frame.Lambda(8, [7]),
    frame.Spawn(9, 8, [], False),
    ..rest
  ] = nodes
  let assert Ok(frame.Receive(timeout:, ..)) =
    list.find(rest, fn(node) {
      case node {
        frame.Receive(..) -> True
        _ -> False
      }
    })
  assert timeout != -1
  // The code after the receive is the continuation ping_pong__k1.
  assert list.any(rest, fn(node) {
    case node {
      frame.Call(name: "ping_pong__k1", ..) -> True
      _ -> False
    }
  })
}

pub fn same_source_same_bytes_test() {
  let bytes = fn() { list.map(example_frames(), wire.encode) }
  assert bytes() == bytes()
}

/// The parser is the gate: a source that does not parse gives no frames.
pub fn nothing_without_a_parse_test() {
  let good = Source("good.gleam", "pub fn one() -> Int { 1 }")
  let bad = Source("bad.gleam", "pub fn broken( {")
  let assert Error(why) = codex.session([good, bad], frame.Check)
  assert string.starts_with(why, "bad.gleam does not parse")
}

// ------------------------------------------------------------ the codex

/// Inter-node communication is cut: an external that reaches another node is
/// a gap form that says so, and so is a call into gleam/erlang/node.
pub fn inter_node_is_a_gap_test() {
  let frames =
    unit_of(
      "import gleam/erlang/node
@external(erlang, \"rpc\", \"call\")
fn remote(node: a, module: b, function: c, arguments: d) -> e
@external(erlang, \"erlang\", \"spawn\")
fn spawn_on(node: a, f: fn() -> b) -> c
pub fn here() -> Nil { node.self() }
",
    )
  let assert [
    frame.Gap("remote", "sample.gleam", 3, _, remote),
    frame.Gap("spawn_on", "sample.gleam", 5, _, spawn_on),
    frame.Function(
      nodes: [frame.GapNode(0, "gleam/erlang/node.self/0", here), _],
      ..,
    ),
  ] = forms(frames)
  let cut = "inter-node communication is outside the proof of concept"
  assert [remote, spawn_on, here] == [cut, cut, cut]
}

/// Arguments, labels, pipes and literals that the example does not show.
pub fn calls_and_literals_test() {
  let text =
    "pub type Pair { Pair(left: Int, right: Int) }
fn sub(from a: Int, take b: Int) -> Int { a - b }
pub fn f(p: Pair) -> Float {
  let Pair(left:, ..) = p
  sub(from: 0x10, take: 1_000)
  left |> sub(1, _)
  \"a\\n\\u{41}\"
  1.
}
pub fn g() -> Int { sub(take: 1, from: 2) }
"
  assert function_nodes(text, "f")
    == [
      frame.Var(0, "p"),
      frame.Var(1, "p"),
      frame.Var(2, "left"),
      frame.Record(3, "sample_pair", [#("left", 2)], -1),
      frame.Match(4, 3, 1),
      frame.Int(5, 16),
      frame.Int(6, 1000),
      frame.Call(7, "", "sub", [5, 6]),
      frame.Var(8, "left"),
      frame.Var(9, "_pipe"),
      frame.Match(10, 9, 8),
      frame.Int(11, 1),
      frame.Var(12, "_pipe"),
      frame.Call(13, "", "sub", [11, 12]),
      frame.Block(14, [10, 13]),
      frame.Text(15, "a\nA"),
      frame.Float(16, "1.0"),
      frame.Block(17, [4, 7, 14, 15, 16]),
      frame.Clause(18, [0], -1, 17),
    ]
  assert function_nodes(text, "g")
    == [
      frame.GapNode(
        0,
        "sub/2",
        "labelled arguments that cannot be put in declaration order without changing the order they are evaluated in",
      ),
      frame.Clause(1, [], -1, 0),
    ]
}

/// A public `main` with no parameters is the session's entry (T9.6). Its
/// result has no annotation here, so the codex works it out from the body
/// and the signature hint is `inferred` (T8.10 a).
pub fn main_is_the_entry_test() {
  let assert [
    frame.Function(name: "main", hints:, types:, ..),
    frame.Entry("main", 0),
  ] = forms(unit_of("pub fn main() { Nil }"))
  assert types == [frame.TSymbols(["nil"]), frame.TFun([], 0)]
  assert hints
    == [frame.Hint(-1, 1, frame.Inferred), frame.Hint(0, 0, frame.Inferred)]
}

/// Locations are (line, column) from glance's byte offsets, both from 1.
pub fn locations_are_lines_and_columns_test() {
  let assert [frame.Function(locations:, ..)] =
    forms(unit_of("\n\npub fn f() {\n  \"é\"\n  7\n}\n"))
  assert locations == [#(4, 3), #(5, 3), #(3, 1), #(3, 1)]
}

// ------------------------------------------------------------ replies

pub fn replies_decode_test() {
  let text = dynamic.string
  let welcome =
    tagged("welcome", [
      record([
        #("session", text("intake_1:42")),
        #("contract", dynamic.int(1)),
        #("transpiler", text("t")),
        #(
          "flow",
          record([
            #("resume_from", dynamic.int(0)),
            #("credit", dynamic.int(8)),
            #("max_frame", dynamic.int(4096)),
          ]),
        ),
      ]),
    ])
  assert decode.run(welcome, sender.reply_decoder())
    == Ok(sender.Welcome("intake_1:42", "t", 0, 8, 4096))
  let rejected =
    tagged("rejected", [
      record([
        #("seq", dynamic.int(3)),
        #("reason", atom("bad_index")),
        #("where", text(".body")),
      ]),
    ])
  assert decode.run(rejected, sender.reply_decoder())
    == Ok(sender.Rejected(3, "bad_index", ".body"))
  assert decode.run(tagged("credit", [dynamic.int(5)]), sender.reply_decoder())
    == Ok(sender.Credit(5))
  let assert Error(_) =
    decode.run(tagged("surprise", [dynamic.int(5)]), sender.reply_decoder())
}

// ------------------------------------------------------------ loopback

type Socket

@external(erlang, "gen_tcp", "listen")
fn listen(port: Int, options: List(Dynamic)) -> Result(Socket, Dynamic)

@external(erlang, "inet", "port")
fn port_of(socket: Socket) -> Result(Int, Dynamic)

@external(erlang, "gen_tcp", "accept")
fn accept(socket: Socket) -> Result(Socket, Dynamic)

@external(erlang, "gen_tcp", "recv")
fn recv(socket: Socket, length: Int) -> Result(BitArray, Dynamic)

@external(erlang, "gen_tcp", "send")
fn send(socket: Socket, bytes: BitArray) -> Dynamic

@external(erlang, "gen_tcp", "close")
fn close(socket: Socket) -> Dynamic

@external(erlang, "erlang", "spawn")
fn spawn(run: fn() -> a) -> Dynamic

/// The sender against a stand-in for the transpiler: it grants two credits in
/// the welcome and one more for each frame, so the sender has to wait for
/// credit (T6.2), checks that seq counts from 0 (T5.1), and answers the end
/// with a result. This tests the sender's side of the protocol only.
pub fn sender_follows_the_protocol_test() {
  let frames = example_frames()
  let assert Ok(listener) =
    listen(0, [
      atom("binary"),
      dynamic.array([atom("packet"), dynamic.int(4)]),
      dynamic.array([atom("active"), dynamic.bool(False)]),
      dynamic.array([
        atom("ip"),
        dynamic.array(list.map([127, 0, 0, 1], dynamic.int)),
      ]),
    ])
  let assert Ok(port) = port_of(listener)
  spawn(fn() { stand_in(listener) })
  let outcome = sender.run(port, frames)
  close(listener)
  let assert sender.Completed(
    session: "loopback",
    transpiler: "stand-in",
    rejected: [],
    diagnostics: [sender.Diagnostic(seq: -1, severity: "note", ..)],
    result: Some(sender.Finished(status: "ok", units: 1, gaps:, rejected: 0, ..)),
    ..,
  ) = outcome
  assert gaps == example_gaps
}

fn stand_in(listener: Socket) -> Dynamic {
  let text = dynamic.string
  let assert Ok(socket) = accept(listener)
  let assert Ok(#("hello", _)) = next_frame(socket)
  send(
    socket,
    term.encode(
      tagged("welcome", [
        record([
          #("session", text("loopback")),
          #("contract", dynamic.int(1)),
          #("transpiler", text("stand-in")),
          #(
            "flow",
            record([
              #("resume_from", dynamic.int(0)),
              #("credit", dynamic.int(2)),
              #("max_frame", dynamic.int(wire.max_frame)),
            ]),
          ),
        ]),
      ]),
    ),
  )
  let #(in_order, units, gaps) = stand_in_loop(socket, 0, True, 0, 0)
  send(
    socket,
    term.encode(
      tagged("diagnostic", [
        record([
          #("seq", dynamic.int(-1)),
          #("unit_name", text("")),
          #(
            "finding",
            record([
              #("severity", atom("note")),
              #("code", text("T0000")),
              #("message", text("stand-in")),
            ]),
          ),
          #(
            "place",
            record([
              #("file", text("")),
              #("line", dynamic.int(0)),
              #("column", dynamic.int(0)),
            ]),
          ),
        ]),
      ]),
    ),
  )
  send(
    socket,
    term.encode(
      tagged("result", [
        record([
          #(
            "status",
            atom(case in_order {
              True -> "ok"
              False -> "failed"
            }),
          ),
          #(
            "counts",
            record([
              #("units", dynamic.int(units)),
              #("gaps", dynamic.int(gaps)),
              #("rejected", dynamic.int(0)),
            ]),
          ),
          #("session", text("loopback")),
          #("files", dynamic.int(0)),
        ]),
      ]),
    ),
  )
  close(socket)
}

fn stand_in_loop(
  socket: Socket,
  expected: Int,
  in_order: Bool,
  units: Int,
  gaps: Int,
) -> #(Bool, Int, Int) {
  let assert Ok(#(tag, frame)) = next_frame(socket)
  let zero = dynamic.int(0)
  let one = dynamic.int(1)
  let seq = decode.run(frame, decode.at([one, atom("seq")], decode.int))
  let in_order = in_order && seq == Ok(expected)
  let gap =
    decode.run(frame, decode.at([one, atom("body"), zero], decode.dynamic))
  let nodes =
    decode.run(
      frame,
      decode.at(
        [one, atom("body"), one, atom("code"), atom("nodes")],
        decode.list(decode.at([0], decode.dynamic)),
      ),
    )
  let gaps = case gap == Ok(atom("gap")), nodes {
    True, _ -> gaps + 1
    _, Ok(tags) -> gaps + list.count(tags, fn(t) { t == atom("gap_node") })
    _, _ -> gaps
  }
  case tag {
    "end" -> #(in_order, units, gaps)
    _ -> {
      send(socket, term.encode(tagged("credit", [dynamic.int(1)])))
      let units = case tag {
        "unit_begin" -> units + 1
        _ -> units
      }
      stand_in_loop(socket, expected + 1, in_order, units, gaps)
    }
  }
}

fn next_frame(socket: Socket) -> Result(#(String, Dynamic), Nil) {
  case recv(socket, 0) {
    Ok(bytes) -> {
      let frame = term.decode(bytes)
      case decode.run(frame, decode.at([0], decode.dynamic)) {
        Ok(tag) ->
          case term.is_atom(tag) {
            True -> Ok(#(term.atom_name(tag), frame))
            False -> Error(Nil)
          }
        Error(_) -> Error(Nil)
      }
    }
    Error(_) -> Error(Nil)
  }
}

// ------------------------------------------------------------ online

type Charlist

@external(erlang, "erlang", "binary_to_list")
fn to_charlist(text: String) -> Charlist

@external(erlang, "erlang", "list_to_binary")
fn from_charlist(text: Charlist) -> String

@external(erlang, "os", "getenv")
fn getenv(name: Charlist, default: Charlist) -> Charlist

/// Contract 6.5: a check-mode session with a running transpiler. It runs only
/// when TO_SILICA_PORT names the transpiler's port.
pub fn check_mode_accepts_every_frame_test() {
  case from_charlist(getenv(to_charlist("TO_SILICA_PORT"), to_charlist(""))) {
    "" ->
      io.println(
        "\nSKIPPED: the check-mode session with a transpiler did not run (TO_SILICA_PORT is not set)",
      )
    port -> {
      let assert Ok(port) = int.parse(port)
      let outcome = sender.run(port, example_frames())
      io.println("\nthe transpiler answered: " <> string.inspect(outcome))
      let assert sender.Completed(
        rejected: [],
        result: Some(sender.Finished(
          status: "ok",
          units: 1,
          gaps:,
          rejected: 0,
          files: 0,
          ..,
        )),
        ..,
      ) = outcome
      assert gaps == example_gaps
    }
  }
}

// ------------------------------------------------------------ the actors app

const actors = "examples/actors.gleam"

fn actors_frames() -> List(Frame) {
  let assert Ok(text) = simplifile.read(actors)
  let assert Ok(frames) = codex.session([Source(actors, text)], frame.Check)
  frames
}

/// test/actors.gleam is the copy `gleam test` compiles and `gleam run -m
/// actors` runs: the application is Gleam that type-checks.
pub fn actors_is_the_compiled_copy_test() {
  let assert Ok(shown) = simplifile.read(actors)
  let assert Ok(compiled) = simplifile.read("test/actors.gleam")
  assert shown == compiled
}

/// Every frame of the application has the shape of the schema, and its node
/// tables are in post-order (T9.2).
pub fn actors_frames_pass_check_frame_test() {
  let frames = actors_frames()
  list.each(frames, fn(f) {
    let decoded = term.decode(wire.encode(f))
    assert decoded == wire.to_term(f)
    assert check_frame(decoded) == atom("ok")
  })
  list.each(forms(frames), fn(form) {
    case form {
      frame.Function(nodes:, ..) ->
        list.index_map(nodes, fn(node, index) {
          assert node.at == index
          assert list.all(frame.children(node), fn(child) { child < index })
        })
      _ -> []
    }
  })
  assert list.contains(forms(frames), frame.Entry("main", 0))
}

/// The application has no gap: the counter (a plain gleam_otp actor), the
/// auditor (a named actor under a static supervisor, sent as a static
/// child) and the coordinator are all real nodes.
const actors_gaps = 0

pub fn actors_gaps_test() {
  let frames = actors_frames()
  assert gap_constructs(nodes(frames)) == []
  assert list.filter_map(forms(frames), fn(form) {
      case form {
        frame.Gap(name:, ..) -> Ok(name)
        _ -> Error(Nil)
      }
    })
    == []
  assert int.sum(list.map(frames, frame.gaps)) == actors_gaps
  let kinds =
    nodes(frames)
    |> list.map(fn(node) {
      let assert [kind, ..] = string.split(string.inspect(node), "(")
      kind
    })
    |> list.unique
  list.each(
    [
      "Self", "Spawn", "Send", "Receive", "Record", "Field", "FunRef", "SlCall",
      "LoopHint", "Fail", "Register", "SendNamed",
    ],
    fn(kind) {
      assert list.contains(kinds, kind)
    },
  )
}

/// The application starts two kinds of actor, so its unit ends with two
/// loop functions, before the entry. T8.14: the type forms come first. T8.10
/// (a): every function has a hint on its signature.
pub fn actors_forms_test() {
  let all = forms(actors_frames())
  let assert [
    frame.Entry("main", 0),
    frame.Function(name: "gleam_otp_actor_loop__g2", arity: 1, ..),
    frame.Function(name: "gleam_otp_actor_loop__g1", arity: 1, ..),
    ..
  ] = list.reverse(all)
  // The functions split.gleam made of main, ask and notes (README,
  // "Processes: what this sender splits"). ask and notes themselves are
  // private and every call of them was replaced by a copy: they are not
  // sent. Neither are start_supervisor and start_auditor: sup.gleam read
  // them, and what they say is in the static child (README, "A static
  // supervisor").
  let names =
    list.filter_map(all, fn(form) {
      case form {
        frame.Function(name:, ..) -> Ok(name)
        _ -> Error(Nil)
      }
    })
  list.each(
    [
      "main", "main__k1", "main__k1__k1", "ask__c1", "ask__c1__k1", "notes__c1",
      "notes__c1__k1",
    ],
    fn(name) {
      assert list.contains(names, name)
    },
  )
  list.each(["ask", "notes", "start_supervisor", "start_auditor"], fn(name) {
    assert !list.contains(names, name)
  })
  // main waits only in the functions it calls: it is no process function
  // itself and cannot be an ordinary one, so it is not exported; the entry
  // form names it (T9.6). It starts with the name and the static child.
  let assert Ok(frame.Function(
    exported: False,
    nodes: [
      frame.Symbol(0, "auditor"),
      frame.Var(1, "auditor"),
      frame.Match(2, 1, 0),
      frame.Int(3, 0),
      frame.FunRef(4, "", "gleam_otp_actor_loop__g2", 1),
      frame.Spawn(5, 4, [3], False),
      frame.Register(6, "auditor", 5),
      ..
    ],
    overrides: [
      frame.Override(
        node: 5,
        requirement: "a4_4",
        choice: "chosen",
        params: [#("restart", "transient"), #("strategy", "one_for_one")],
        ..,
      ),
    ],
    ..,
  )) =
    list.find(all, fn(form) {
      case form {
        frame.Function(name: "main", ..) -> True
        _ -> False
      }
    })
  let assert [
    frame.Type(name: "actors_tally", ..),
    frame.Type(name: "actors_size", ..),
    frame.Type(name: "actors_report", ..),
    frame.Type(name: "actors_counter_message", ..),
    frame.Type(name: "actors_auditor_message", ..),
    frame.Function(..),
    ..
  ] = all
  list.each(all, fn(form) {
    case form {
      frame.Function(hints:, ..) -> {
        let assert [frame.Hint(node: -1, ..), ..] = hints
        Nil
      }
      _ -> Nil
    }
  })
}

/// The calls of gleam/erlang/process that have a node in the contract: a
/// subject is lowered to the process that owns it (H20 to H23). A subject is
/// `t_actor` of its message type, which also types the message of the
/// receive clause (T8.10 e).
pub fn library_processes_test() {
  let text =
    "import gleam/erlang/process.{type Pid, type Subject}
pub fn run() -> Result(Int, Nil) {
  let inbox: Subject(Int) = process.new_subject()
  process.spawn(fn() { process.send(inbox, 1) })
  process.spawn_unlinked(fn() { process.self() })
  process.receive(inbox, 100)
}
pub fn wait(inbox: Subject(String)) -> String { process.receive_forever(inbox) }
pub fn other(pid: Pid) -> Bool { process.is_alive(pid) }
pub fn labelled(inbox: Subject(Int)) -> Result(Int, Nil) { process.receive(from: inbox, within: 5) }
pub fn untyped() -> Int {
  let inbox = process.new_subject()
  process.receive_forever(inbox)
}
"
  assert function_nodes(text, "run")
    == [
      frame.Self(0),
      frame.Var(1, "inbox"),
      frame.Match(2, 1, 0),
      frame.Var(3, "inbox"),
      frame.Int(4, 1),
      frame.Symbol(5, "subject__int"),
      frame.Tuple(6, [5, 4]),
      frame.Send(7, 3, 6),
      frame.Symbol(8, "nil"),
      frame.Block(9, [7, 8]),
      frame.Clause(10, [], -1, 9),
      frame.Lambda(11, [10]),
      frame.Spawn(12, 11, [], True),
      frame.Self(13),
      frame.Clause(14, [], -1, 13),
      frame.Lambda(15, [14]),
      frame.Spawn(16, 15, [], False),
      // run is public, so it keeps its receive and is a process function
      // itself (README, "Processes: what this sender splits"). T9.12: the
      // message is the tagged tuple `#(subject__int, _message)`, in the
      // receive clause's pattern as in the send.
      frame.Symbol(17, "subject__int"),
      frame.Var(18, "_message"),
      frame.Tuple(19, [17, 18]),
      frame.Symbol(20, "ok"),
      frame.Var(21, "_message"),
      frame.Tuple(22, [20, 21]),
      frame.Clause(23, [19], -1, 22),
      frame.Int(24, 100),
      frame.Symbol(25, "error"),
      frame.Symbol(26, "nil"),
      frame.Tuple(27, [25, 26]),
      frame.Receive(28, [23], 24, 27),
      frame.Block(29, [2, 12, 16, 28]),
      frame.Clause(30, [], -1, 29),
    ]
  let #(types, hints) = function_hints(text, "run")
  let hint = fn(node) { hint_type(types, hints, node) }
  // T8.10 (e): the message of the receive clause, and the receive's value.
  assert hint(-1) == #("fn() -> ok(int) | error(nil)", frame.Proven)
  assert hint(18) == #("int", frame.Inferred)
  assert hint(19) == #("subject__int(int)", frame.Inferred)
  assert hint(28) == #("ok(int) | error(nil)", frame.Inferred)
  let #(types, hints) = function_hints(text, "run")
  let hint = fn(node) { hint_type(types, hints, node) }
  // The subject, from the let's annotation; self() is a Pid. Contract H22:
  // the value of the send node is the message (an Int), and Gleam's Nil is
  // the value of the block that holds the send and then `nil`.
  assert hint(0) == #("actor(int)", frame.Proven)
  assert hint(1) == #("actor(int)", frame.Proven)
  assert hint(6) == #("subject__int(int)", frame.Inferred)
  assert hint(7) == #("subject__int(int)", frame.Inferred)
  assert hint(9) == #("nil", frame.Inferred)
  assert hint(11) == #("fn() -> nil", frame.Inferred)
  assert hint(12) == #("actor(dynamic)", frame.Inferred)
  assert function_nodes(text, "wait")
    == [
      frame.Var(0, "inbox"),
      frame.Symbol(1, "subject__string"),
      frame.Var(2, "_message"),
      frame.Tuple(3, [1, 2]),
      frame.Var(4, "_message"),
      frame.Clause(5, [3], -1, 4),
      frame.Receive(6, [5], -1, -1),
      frame.Clause(7, [0], -1, 6),
    ]
  let assert [_, frame.GapNode(1, "gleam/erlang/process.is_alive/1", _), ..] =
    function_nodes(text, "other")
  let assert [_, frame.GapNode(1, "gleam/erlang/process.receive/2", _), ..] =
    function_nodes(text, "labelled")
  // Without an annotation the subject's message type is not known: the let
  // is a gap that says so, and it ends the block.
  let assert [
    frame.GapNode(0, "process.new_subject/0", note),
    frame.Block(1, [0]),
    _,
  ] = function_nodes(text, "untyped")
  assert string.ends_with(note, "so the binding inbox has no type (T8.10 b)")
}

/// Contract H22: the value of a `(:send)` is the message, the value of
/// Gleam's `process.send` is Nil. Where the call's value is the value of its
/// place (a function's result, a case branch, the last statement of a block)
/// it is sent as the block `{ send, nil }`; where its value is dropped (a
/// statement that is not the last of its block) the send stands alone. The
/// send node is hinted with the message's type either way.
pub fn send_is_a_statement_before_nil_test() {
  let text =
    "import gleam/erlang/process.{type Subject}
pub type Message { Add(Int) Stop }
pub fn both(a: Subject(Message), b: Subject(Message), n: Int) -> Nil {
  process.send(a, Add(n))
  process.send(b, Stop)
}
pub fn one(a: Subject(Message)) -> Nil { process.send(a, Stop) }
pub fn branch(a: Subject(Message), n: Int) -> Nil {
  case n {
    0 -> process.send(a, Stop)
    _ -> Nil
  }
}
pub fn then(a: Subject(Message), n: Int) -> Int {
  process.send(a, Add(n))
  n
}
@external(erlang, \"erlang\", \"send\")
fn bang(to: Subject(Message), message: Message) -> Message
pub fn erlang_send(a: Subject(Message)) -> Message { bang(a, Stop) }
"
  // Two sends: the first is a statement, the second is the function's value.
  assert function_nodes(text, "both")
    == [
      frame.Var(0, "a"),
      frame.Var(1, "b"),
      frame.Var(2, "n"),
      frame.Var(3, "a"),
      frame.Symbol(4, "add"),
      frame.Var(5, "n"),
      frame.Tuple(6, [4, 5]),
      frame.Send(7, 3, 6),
      frame.Var(8, "b"),
      frame.Symbol(9, "stop"),
      frame.Send(10, 8, 9),
      frame.Symbol(11, "nil"),
      frame.Block(12, [10, 11]),
      frame.Block(13, [7, 12]),
      frame.Clause(14, [0, 1, 2], -1, 13),
    ]
  let #(types, hints) = function_hints(text, "both")
  let hint = fn(node) { hint_type(types, hints, node) }
  let message = hint(6).0
  assert hint(7) == #(message, frame.Inferred)
  assert hint(10) == #(message, frame.Inferred)
  assert hint(11) == #("nil", frame.Inferred)
  assert hint(12) == #("nil", frame.Inferred)
  assert hint(13) == #("nil", frame.Inferred)
  // The whole body.
  assert function_nodes(text, "one")
    == [
      frame.Var(0, "a"),
      frame.Var(1, "a"),
      frame.Symbol(2, "stop"),
      frame.Send(3, 1, 2),
      frame.Symbol(4, "nil"),
      frame.Block(5, [3, 4]),
      frame.Clause(6, [0], -1, 5),
    ]
  // A case branch.
  let assert [
    _,
    _,
    _,
    _,
    _,
    frame.Symbol(5, "stop"),
    frame.Send(6, _, 5),
    frame.Symbol(7, "nil"),
    frame.Block(8, [6, 7]),
    frame.Clause(9, [_], -1, 8),
    ..
  ] = function_nodes(text, "branch")
  // A statement whose value is dropped: no block of its own, no `nil`.
  assert function_nodes(text, "then")
    == [
      frame.Var(0, "a"),
      frame.Var(1, "n"),
      frame.Var(2, "a"),
      frame.Symbol(3, "add"),
      frame.Var(4, "n"),
      frame.Tuple(5, [3, 4]),
      frame.Send(6, 2, 5),
      frame.Var(7, "n"),
      frame.Block(8, [6, 7]),
      frame.Clause(9, [0, 1], -1, 8),
    ]
  let #(types, hints) = function_hints(text, "then")
  assert hint_type(types, hints, 6).0 == hint_type(types, hints, 5).0
  // Erlang's own send, declared with the message as its value: the node alone.
  assert function_nodes(text, "erlang_send")
    == [
      frame.Var(0, "a"),
      frame.Var(1, "a"),
      frame.Symbol(2, "stop"),
      frame.Send(3, 1, 2),
      frame.Clause(4, [0], -1, 3),
    ]
}

/// Contract 6.5: the application in a check-mode session with a running
/// transpiler. It runs only when TO_SILICA_PORT names the transpiler's port.
pub fn actors_check_mode_test() {
  case from_charlist(getenv(to_charlist("TO_SILICA_PORT"), to_charlist(""))) {
    "" -> Nil
    port -> {
      let assert Ok(port) = int.parse(port)
      let assert sender.Completed(
        rejected: [],
        result: Some(sender.Finished(
          status: "ok",
          units: 1,
          gaps:,
          rejected: 0,
          files: 0,
          ..,
        )),
        ..,
      ) = sender.run(port, actors_frames())
      assert gaps == actors_gaps
    }
  }
}

// ------------------------------------------------------------ one test for each mapping
//
// The template for a new mapping: a source snippet in, the expected nodes
// (or types) out, and the frames through the contract's checker.

/// The function forms of a snippet, by name, after every frame of it has
/// passed check_frame.
fn function_nodes(text: String, name: String) -> List(frame.Node) {
  let frames = unit_of(text)
  list.each(frames, fn(f) {
    assert check_frame(term.decode(wire.encode(f))) == atom("ok")
  })
  let assert Ok(frame.Function(nodes:, ..)) =
    list.find(forms(frames), fn(form) {
      case form {
        frame.Function(name: found, ..) -> found == name
        _ -> False
      }
    })
  nodes
}

/// The type table of a function of a snippet, up to its signature (node -1,
/// T8.10 a), which must be a `proven` hint: all of it is annotation.
fn function_types(text: String, name: String) -> List(frame.TypeNode) {
  let #(types, hints) = function_hints(text, name)
  let assert [frame.Hint(-1, signature, frame.Proven), ..] = hints
  list.take(types, signature + 1)
}

/// The type table and the hints of a function of a snippet.
fn function_hints(
  text: String,
  name: String,
) -> #(List(frame.TypeNode), List(frame.Hint)) {
  let frames = unit_of(text)
  list.each(frames, fn(f) {
    assert check_frame(term.decode(wire.encode(f))) == atom("ok")
  })
  let assert Ok(frame.Function(types:, hints:, ..)) =
    list.find(forms(frames), fn(form) {
      case form {
        frame.Function(name: found, ..) -> found == name
        _ -> False
      }
    })
  #(types, hints)
}

/// The type a node is hinted with, in words, and the hint's strength;
/// `#("none", Inferred)` for a node without a hint.
fn hint_type(
  types: List(frame.TypeNode),
  hints: List(frame.Hint),
  node: Int,
) -> #(String, frame.Strength) {
  case list.find(hints, fn(hint) { hint.node == node }) {
    Ok(frame.Hint(type_:, strength:, ..)) -> #(
      type_text(types, type_),
      strength,
    )
    Error(Nil) -> #("none", frame.Inferred)
  }
}

/// A type table entry in words: `fn(int, float) -> boolean`.
fn type_text(types: List(frame.TypeNode), index: Int) -> String {
  let text = type_text(types, _)
  let all = fn(indices) { string.join(list.map(indices, text), ", ") }
  case list.drop(types, index) {
    [frame.TInt, ..] -> "int"
    [frame.TFloat, ..] -> "float"
    [frame.TBool, ..] -> "boolean"
    [frame.TText, ..] -> "text"
    [frame.TBytes, ..] -> "bytes"
    [frame.TDynamic, ..] -> "dynamic"
    [frame.TSymbols(names:), ..] -> string.join(names, "|")
    [frame.TTuple(elems:), ..] -> "#(" <> all(elems) <> ")"
    [frame.TTagged(tag:, elems:), ..] -> tag <> "(" <> all(elems) <> ")"
    [frame.TRecord(fields:), ..] ->
      "{"
      <> string.join(
        list.map(fields, fn(field) { field.0 <> ": " <> text(field.1) }),
        ", ",
      )
      <> "}"
    [frame.TList(elem:), ..] -> "list(" <> text(elem) <> ")"
    [frame.TUnion(alts:), ..] -> string.join(list.map(alts, text), " | ")
    [frame.TFun(params:, result:), ..] ->
      "fn(" <> all(params) <> ") -> " <> text(result)
    [frame.TActor(message:), ..] -> "actor(" <> text(message) <> ")"
    [frame.TNamed(name:, args: []), ..] -> name
    [frame.TNamed(name:, args:), ..] -> name <> "(" <> all(args) <> ")"
    [frame.TVar(name:), ..] -> "'" <> name
    [] -> "out of range"
  }
}

fn gap_constructs(nodes: List(frame.Node)) -> List(String) {
  list.filter_map(nodes, fn(node) {
    case node {
      frame.GapNode(construct:, ..) -> Ok(construct)
      _ -> Error(Nil)
    }
  })
}

/// N1, N3, N4, N5 (names.gleam).
pub fn names_test() {
  assert names.silica_unit("gl_", "demo") == "gl_demo"
  assert names.silica_unit("gl_", "my/mod") == "gl_my_mod"
  assert names.type_name("actors", "Tally") == "actors_tally"
  assert names.type_name("my/mod", "HTTPServer") == "my_mod_http_server"
  assert names.snake("StopAbnormal") == "stop_abnormal"
  assert names.snake("Point3D") == "point3_d"
  assert names.symbol("Ok") == "ok"
  assert names.symbol("Nil") == "nil"
  // N4: an ordinary Gleam name is unchanged.
  assert names.ident("plain_name1") == "plain_name1"
  assert names.ident("_pipe") == "_pipe"
  assert names.ident("x_") == "x_"
  assert names.ident("_") == "_"
  // Escapes start with two underscores.
  assert names.ident("valid?") == "valid__q"
  assert names.ident("save!") == "save__b"
  assert names.ident("a-b") == "a__x2d_b"
  assert names.ident("9lives") == "__x39_lives"
  assert names.ident("") == "__e"
  assert names.ident("é") == "__xe9_"
  // An underscore next to another, or before an escaped character, is
  // escaped itself, so `__` in a spelling is always an escape.
  assert names.ident("a__b") == "a__x5f___x5f_b"
  assert names.ident("a_?") == "a__x5f___q"
  assert names.ident("valid__q") == "valid__x5f___x5f_q"
  assert names.ident("valid_q") == "valid_q"
}

/// The inverse of `names.ident`, reading left to right: `__q` is `?`, `__b`
/// is `!`, `__e` is the empty name, `__x<hex>_` is that code point, and
/// everything else is itself.
fn decode_ident(spelling: String) -> String {
  case spelling {
    "" -> ""
    "__q" <> rest -> "?" <> decode_ident(rest)
    "__b" <> rest -> "!" <> decode_ident(rest)
    "__e" <> rest -> decode_ident(rest)
    "__x" <> rest -> {
      let assert Ok(#(hex, rest)) = string.split_once(rest, "_")
      let assert Ok(code) = int.base_parse(hex, 16)
      let assert Ok(codepoint) = string.utf_codepoint(code)
      string.from_utf_codepoints([codepoint]) <> decode_ident(rest)
    }
    _ -> {
      let assert Ok(#(first, rest)) = string.pop_grapheme(spelling)
      first <> decode_ident(rest)
    }
  }
}

/// N4 is injective: the decoder gives every source name back, and no two of
/// these awkward names share a spelling. A spelling is an identifier: only
/// letters, digits and `_`, and no digit in first place.
pub fn ident_is_injective_test() {
  let awkward = [
    "valid?", "valid__q", "valid_q", "valid_?", "a_?", "a__b", "a_b", "a___b",
    "_", "__", "___", "+", "+_", "_+", "+_a", "+__a", "hello world", "1abc", "1",
    "a1", "", "x_", "_x", "x__", "__x", "é", "é_é", "__e", "__q", "__b",
    "__x5f_", "_x5f_", "a__x5f_b", "q", "e", "?", "!", "?!", "?_!", "__g",
    "gleam_otp_actor_loop__g1", "a.b", "a/b", "A_B", "x5f", "a_x2d_b", "a-b",
    "日本", "a?b!c", "_1", "1_", "__1",
  ]
  let spellings = list.map(awkward, names.ident)
  list.each(list.zip(awkward, spellings), fn(pair) {
    assert decode_ident(pair.1) == pair.0
    assert pair.1 != ""
    let codes =
      list.map(string.to_utf_codepoints(pair.1), string.utf_codepoint_to_int)
    assert list.all(codes, fn(code) {
      { code >= 97 && code <= 122 }
      || { code >= 65 && code <= 90 }
      || { code >= 48 && code <= 57 }
      || code == 95
    })
    let assert [first, ..] = codes
    assert first < 48 || first > 57
  })
  assert list.unique(spellings) == spellings
  // A name the codex makes up for a function ends in `__g<n>`, which is no
  // source name's spelling: after `__` a spelling has q, b, e or x.
  assert list.all(spellings, fn(spelling) { !string.contains(spelling, "__g") })
}

/// N4 in the frames: a Gleam name with two underscores in a row is escaped
/// wherever it is written (the function's head, a call, a variable, a
/// field). Gleam has one arity for each function name, so no arity is
/// written into a name.
pub fn names_are_escaped_in_frames_test() {
  let text =
    "pub type Odd { Odd(a__b: Int) }
pub fn f__g(x__y: Int) -> Int { x__y }
pub fn h(o: Odd) -> Int { f__g(o.a__b) }
"
  let assert [
    frame.Type(types: [frame.TInt, frame.TRecord([#("a__x5f___x5f_b", 0)])], ..),
    frame.Function(name: "f__x5f___x5f_g", nodes: f, ..),
    frame.Function(name: "h", nodes: h, ..),
  ] = forms(unit_of(text))
  assert f
    == [
      frame.Var(0, "x__x5f___x5f_y"),
      frame.Var(1, "x__x5f___x5f_y"),
      frame.Clause(2, [0], -1, 1),
    ]
  assert h
    == [
      frame.Var(0, "o"),
      frame.Var(1, "o"),
      frame.Field(2, 1, "a__x5f___x5f_b"),
      frame.Call(3, "", "f__x5f___x5f_g", [2]),
      frame.Clause(4, [0], -1, 3),
    ]
}

/// N3 and N5 in the frames: a type form, a named type, a record node, a
/// constructor's symbol, a tagged variant, and Nil.
pub fn names_in_frames_test() {
  let text =
    "pub type Point { Point(x: Int, y: Int) }
pub type Shape { Empty  RoundThing(Float) }
pub fn f(p: Point, s: Shape) -> Nil {
  let Point(x:, ..) = p
  RoundThing(1.0)
  Empty
  Nil
}
"
  let assert [
    frame.Type(name: "sample_point", ..),
    frame.Type(name: "sample_shape", types: shape, ..),
    ..
  ] = forms(unit_of(text))
  assert shape
    == [
      frame.TSymbols(["empty"]),
      frame.TFloat,
      frame.TTagged("round_thing", [1]),
      frame.TUnion([0, 2]),
    ]
  assert function_types(text, "f")
    == [
      frame.TNamed("sample_point", []),
      frame.TNamed("sample_shape", []),
      frame.TSymbols(["nil"]),
      frame.TFun([0, 1], 2),
    ]
  let assert [
    frame.Var(0, "p"),
    frame.Var(1, "s"),
    frame.Var(2, "p"),
    frame.Var(3, "x"),
    frame.Record(4, "sample_point", [#("x", 3)], -1),
    frame.Match(5, 4, 2),
    frame.Symbol(6, "round_thing"),
    frame.Float(7, "1.0"),
    frame.Tuple(8, [6, 7]),
    frame.Symbol(9, "empty"),
    frame.Symbol(10, "nil"),
    ..
  ] = function_nodes(text, "f")
}

/// `let assert pattern = value` is a match node (H18); with `as` it is a gap,
/// and a statement that is a gap ends its block.
pub fn let_assert_test() {
  let text =
    "pub fn f(r: Result(Int, Nil)) -> Int {
  let assert Ok(x) = r
  let assert Ok(y) = r as \"no y\"
  x
}
"
  let assert [
    frame.Var(0, "r"),
    frame.Var(1, "r"),
    frame.Symbol(2, "ok"),
    frame.Var(3, "x"),
    frame.Tuple(4, [2, 3]),
    frame.Match(5, 4, 1),
    frame.GapNode(6, "let assert ... as message", _),
    frame.Block(7, [5, 6]),
    frame.Clause(8, [0], -1, 7),
  ] = function_nodes(text, "f")
  // T8.10 (b): `x` takes the type inside Ok from the value's type.
  let #(types, hints) = function_hints(text, "f")
  assert hint_type(types, hints, 3) == #("int", frame.Inferred)
  assert hint_type(types, hints, 5) == #("ok(int) | error(nil)", frame.Inferred)
}

/// `pattern as name` is a match node in a pattern position, both sides
/// patterns (H18, contract 9.4).
pub fn alias_pattern_test() {
  let text =
    "pub fn f(t: #(Int, Int)) -> #(Int, #(Int, Int)) {
  case t {
    #(a, _) as whole -> #(a, whole)
  }
}
"
  let assert [
    frame.Var(0, "t"),
    frame.Var(1, "t"),
    frame.Var(2, "whole"),
    frame.Var(3, "a"),
    frame.Wild(4),
    frame.Tuple(5, [3, 4]),
    frame.Match(6, 2, 5),
    frame.Var(7, "a"),
    frame.Var(8, "whole"),
    frame.Tuple(9, [7, 8]),
    frame.Clause(10, [6], -1, 9),
    frame.Case(11, 1, [10]),
    frame.Clause(12, [0], -1, 11),
  ] = function_nodes(text, "f")
}

/// The types of gleam_erlang and gleam_otp, and the prelude's Result and
/// List, in a signature: a subject is the process that owns it (`t_actor`).
/// Each entry is in the table once.
pub fn library_types_test() {
  let text =
    "import gleam/erlang/process.{type Pid, type Subject}
import gleam/otp/actor
pub fn a(s: Subject(Int), p: Pid, q: process.Subject(String)) -> Result(Int, Nil) { todo }
pub fn b(n: actor.Next(Int, String)) -> List(Int) { todo }
pub fn c() -> actor.StartResult(Subject(Int)) { todo }
"
  assert function_types(text, "a")
    == [
      frame.TInt,
      frame.TActor(0),
      frame.TDynamic,
      frame.TActor(2),
      frame.TText,
      frame.TActor(4),
      frame.TTagged("ok", [0]),
      frame.TSymbols(["nil"]),
      frame.TTagged("error", [7]),
      frame.TUnion([6, 8]),
      frame.TFun([1, 3, 5], 9),
    ]
  assert function_types(text, "b")
    == [
      frame.TInt,
      frame.TTagged("continue", [0]),
      frame.TSymbols(["stop"]),
      frame.TText,
      frame.TTagged("stop_abnormal", [3]),
      frame.TUnion([1, 2, 4]),
      frame.TList(0),
      frame.TFun([5], 6),
    ]
  let assert [
    frame.TDynamic,
    frame.TActor(0),
    frame.TInt,
    frame.TActor(2),
    frame.TTagged("started", [1, 3]),
    ..
  ] = function_types(text, "c")
}

/// A type of another module the codex has no entry for cannot be stated, so
/// a function whose signature names one is a gap form that says which type
/// (T8.10 a), and so is a custom type with such a field (T8.14) and every
/// function that names that custom type.
pub fn unknown_types_are_gaps_test() {
  let text =
    "import other/thing
pub type Holder { Holder(thing: thing.Thing) }
pub fn a(t: thing.Thing) -> Int { 1 }
pub fn b(h: Holder) -> Int { 1 }
pub fn c() -> Int { 1 }
"
  let assert [
    frame.Gap("Holder", "sample.gleam", 2, "type Holder", holder),
    frame.Gap("a", "sample.gleam", 3, "function a/1", a),
    frame.Gap("b", "sample.gleam", 4, "function b/1", b),
    frame.Function(name: "c", ..),
  ] = forms(unit_of(text))
  assert holder
    == "the type Holder is not sent, because a field of it has no known type: the type other/thing.Thing is declared in another module, and this codex has no entry for it (T8.14)"
  assert a
    == "the type other/thing.Thing is declared in another module, and this codex has no entry for it, so the function has no signature (T8.10 a)"
  assert string.starts_with(b, "the type Holder is not sent")
  assert string.ends_with(b, "so the function has no signature (T8.10 a)")
}

/// A receive's subject is evaluated first when it is not a plain variable.
pub fn receive_evaluates_its_subject_test() {
  let text =
    "import gleam/erlang/process
pub fn f(box: process.Subject(Int)) -> Int { process.receive_forever(pick(box)) }
fn pick(box: process.Subject(Int)) -> process.Subject(Int) { box }
"
  let assert [
    frame.Var(0, "box"),
    frame.Var(1, "box"),
    frame.Call(2, "", "pick", [1]),
    frame.Symbol(3, "subject__int"),
    frame.Var(4, "_message"),
    frame.Tuple(5, [3, 4]),
    frame.Var(6, "_message"),
    frame.Clause(7, [5], -1, 6),
    frame.Receive(8, [7], -1, -1),
    frame.Block(9, [2, 8]),
    frame.Clause(10, [0], -1, 9),
  ] = function_nodes(text, "f")
}

const plain_actor =
  "import gleam/erlang/process.{type Subject}
import gleam/otp/actor
pub fn handle(state: Int, message: Int) -> actor.Next(Int, Int) {
  case message {
    0 -> actor.stop()
    1 -> actor.stop_abnormal(\"one\")
    _ -> actor.continue(state + message)
  }
}
pub fn start() { actor.new(0) |> actor.on_message(handle) |> actor.start }
pub fn bare() -> actor.StartResult(Subject(String)) { actor.start(actor.new(7)) }
pub fn unknown() -> Int { let _ = actor.start(actor.new(7)) 1 }
"

/// actor.continue, actor.stop and actor.stop_abnormal are gleam_otp's own
/// values: #(continue, state, none), #(stop, normal), #(stop, #(abnormal, r)).
pub fn actor_next_values_test() {
  let assert [
    frame.Var(0, "state"),
    frame.Var(1, "message"),
    frame.Var(2, "message"),
    frame.Int(3, 0),
    frame.Symbol(4, "stop"),
    frame.Clause(5, [3], -1, 4),
    frame.Int(6, 1),
    frame.Symbol(7, "stop_abnormal"),
    frame.Text(8, "one"),
    frame.Tuple(9, [7, 8]),
    frame.Clause(10, [6], -1, 9),
    frame.Wild(11),
    frame.Symbol(12, "continue"),
    frame.Var(13, "state"),
    frame.Var(14, "message"),
    frame.Op(15, "+", [13, 14]),
    frame.Tuple(16, [12, 15]),
    frame.Clause(17, [11], -1, 16),
    frame.Case(18, 2, [5, 10, 17]),
    frame.Clause(19, [0, 1], -1, 18),
  ] = function_nodes(plain_actor, "handle")
}

/// The plain actor's start: an unlinked spawn of the loop function with the
/// state (H21, T9.14, T9.15), and the value Ok(Started(pid, subject)). The
/// handler is not a value: the loop calls it by name. The state's type is
/// `actor.new`'s argument's, the message type the handler's second
/// parameter; the new process is stated as the subject.
pub fn actor_start_test() {
  assert function_nodes(plain_actor, "start")
    == [
      frame.Int(0, 0),
      frame.FunRef(1, "", "gleam_otp_actor_loop__g1", 1),
      frame.Spawn(2, 1, [0], False),
      frame.Var(3, "_actor_3"),
      frame.Match(4, 3, 2),
      frame.Symbol(5, "ok"),
      frame.Symbol(6, "started"),
      frame.Var(7, "_actor_3"),
      frame.Var(8, "_actor_3"),
      frame.Tuple(9, [6, 7, 8]),
      frame.Tuple(10, [5, 9]),
      frame.Block(11, [4, 10]),
      frame.Clause(12, [], -1, 11),
    ]
  let #(types, hints) = function_hints(plain_actor, "start")
  let hint = fn(node) { hint_type(types, hints, node) }
  assert hint(1) == #("fn(int) -> normal", frame.Inferred)
  assert hint(2) == #("actor(int)", frame.Inferred)
  assert hint(3) == #("actor(int)", frame.Inferred)
  assert hint(9) == #("started(actor(dynamic), actor(int))", frame.Inferred)
  // `start` has no return annotation: its signature is worked out. No
  // `dynamic` is in it but the Pid's (a process of unknown messages).
  let assert #(signature, frame.Inferred) = hint(-1)
  assert signature
    == "fn() -> ok(started(actor(dynamic), actor(int))) | error(init_timeout|init_failed|init_exited)"
  // Without on_message the loop keeps its state (gleam_otp's default
  // handler), and the message type comes from the annotation of the
  // start's result.
  let assert [
    frame.Int(0, 7),
    frame.FunRef(1, "", "gleam_otp_actor_loop__g2", 1),
    frame.Spawn(2, 1, [0], False),
    frame.Var(3, "_actor_3"),
    ..
  ] = function_nodes(plain_actor, "bare")
  let #(types, hints) = function_hints(plain_actor, "bare")
  assert hint_type(types, hints, 2) == #("actor(text)", frame.Inferred)
  // A handler that is not a function of the module by its name: a gap.
  let closure =
    "import gleam/erlang/process.{type Subject}
import gleam/otp/actor
pub fn start() -> actor.StartResult(Subject(Int)) { actor.new(0) |> actor.on_message(fn(s: Int, m: Int) { actor.continue(s + m) }) |> actor.start }
"
  let assert [frame.GapNode(0, "gleam/otp/actor.start/1", note), ..] =
    function_nodes(closure, "start")
  assert string.contains(note, "the actor's loop calls its handler by name")
  // With no message type from either, the start is a gap (T8.10 e).
  let assert [frame.GapNode(0, "actor.start/1", note), ..] =
    function_nodes(plain_actor, "unknown")
  assert string.contains(note, "the actor's message type is not known")
}

/// The loop function a unit with plain actors gets: one for each kind of
/// actor (state type, message type), since a function with type variables
/// in its signature is not written (T8.14). Every type in it is `inferred`.
/// A unit without an actor gets none.
pub fn actor_loop_form_test() {
  let loops = fn(text) {
    list.filter(forms(unit_of(text)), fn(form) {
      case form {
        frame.Function(name:, ..) ->
          string.starts_with(name, "gleam_otp_actor_loop__g")
        _ -> False
      }
    })
  }
  assert loops("pub fn f() -> Int { 1 }") == []
  let assert [
    frame.Function(
      name: "gleam_otp_actor_loop__g1",
      nodes:,
      types:,
      hints:,
      arity: 1,
      exported: False,
      ..,
    ),
    frame.Function(name: "gleam_otp_actor_loop__g2", types: second, ..),
  ] = loops(plain_actor)
  assert nodes
    == [
      frame.Var(0, "state"),
      frame.Symbol(1, "subject__int"),
      frame.Var(2, "_message"),
      frame.Tuple(3, [1, 2]),
      frame.Var(4, "state"),
      frame.Var(5, "_message"),
      frame.Call(6, "", "handle", [4, 5]),
      frame.Symbol(7, "continue"),
      frame.Var(8, "_state"),
      frame.Tuple(9, [7, 8]),
      frame.Var(10, "_state"),
      frame.Call(11, "", "gleam_otp_actor_loop__g1", [10]),
      frame.Clause(12, [9], -1, 11),
      frame.Symbol(13, "stop"),
      frame.Symbol(14, "normal"),
      frame.Clause(15, [13], -1, 14),
      frame.Symbol(16, "stop_abnormal"),
      frame.Var(17, "_reason"),
      frame.Tuple(18, [16, 17]),
      frame.Var(19, "_reason"),
      frame.Fail(20, 19),
      frame.Clause(21, [18], -1, 20),
      frame.Case(22, 6, [12, 15, 21]),
      frame.Clause(23, [3], -1, 22),
      frame.Receive(24, [23], -1, -1),
      frame.LoopHint(25, 24),
      frame.Clause(26, [0], -1, 25),
    ]
  assert list.all(hints, fn(hint) { hint.strength == frame.Inferred })
  let hint = fn(node) { hint_type(types, hints, node).0 }
  let next = "continue(int) | stop | stop_abnormal(text)"
  assert hint(-1) == "fn(int) -> normal"
  // T8.10 (e), T9.12: the message of the receive clause; (d): the handler's
  // result.
  assert hint(2) == "int"
  assert hint(3) == "subject__int(int)"
  assert hint(6) == next
  assert hint(8) == "int"
  assert hint(17) == "text"
  assert hint(24) == "normal"
  // No `dynamic` is needed for an actor.
  assert !list.contains(types, frame.TDynamic)
  // No type variable is left in either.
  let has_variable = fn(types) {
    list.any(types, fn(entry) {
      case entry {
        frame.TVar(..) -> True
        _ -> False
      }
    })
  }
  assert !has_variable(types) && !has_variable(second)
  assert list.contains(second, frame.TText)
  // A function of the module cannot have the helper's name: a Gleam name
  // with `__` in it is escaped (N4).
  let assert [
    frame.Function(name: "gleam_otp_actor_loop__x5f___x5f_g1", ..),
    ..
  ] =
    list.reverse(
      list.filter(
        forms(unit_of(
          plain_actor <> "pub fn gleam_otp_actor_loop__g1() -> Int { 1 }\n",
        )),
        fn(form) {
          case form {
            frame.Function(name:, ..) ->
              !string.starts_with(name, "gleam_otp_actor_loop__g")
            _ -> False
          }
        },
      ),
    )
}

/// What is not the plain actor is one gap node, the outermost call that is
/// not lowered. Its arguments are not sent: the program stops at the gap.
pub fn otp_gaps_test() {
  let text =
    "import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
pub fn init(announce: Subject(Subject(Int))) -> Int {
  actor.new_with_initialiser(100, fn(subject: Subject(Int)) {
    process.send(announce, subject)
    Ok(actor.initialised(0))
  })
  |> actor.start
}
pub fn sup(child: fn() -> Int) -> Int {
  supervisor.new(supervisor.OneForOne)
  |> supervisor.add(supervision.worker(fn() { child() }))
  |> supervisor.start
}
"
  let assert [
    frame.Var(0, "announce"),
    frame.GapNode(1, "gleam/otp/actor.start/1", _),
    frame.Clause(2, [0], -1, 1),
  ] = function_nodes(text, "init")
  let assert [
    frame.Var(0, "child"),
    frame.GapNode(1, "gleam/otp/static_supervisor.start/1", _),
    frame.Clause(2, [0], -1, 1),
  ] = function_nodes(text, "sup")
}

/// `actor.Started(data:, ..)`: the one constructor of another module whose
/// labels the codex knows, and whose fields it has types for.
pub fn started_pattern_test() {
  let text =
    "import gleam/erlang/process.{type Subject}
import gleam/otp/actor
pub fn f(r: actor.StartResult(Subject(Int))) -> Subject(Int) {
  let assert Ok(actor.Started(data: subject, ..)) = r
  subject
}
"
  let assert [
    frame.Var(0, "r"),
    frame.Var(1, "r"),
    frame.Symbol(2, "ok"),
    frame.Symbol(3, "started"),
    frame.Wild(4),
    frame.Var(5, "subject"),
    frame.Tuple(6, [3, 4, 5]),
    frame.Tuple(7, [2, 6]),
    frame.Match(8, 7, 1),
    ..
  ] = function_nodes(text, "f")
  let #(types, hints) = function_hints(text, "f")
  assert hint_type(types, hints, 5) == #("actor(int)", frame.Inferred)
}

// ------------------------------------------------------------ release (M7, R9)

/// A stand-in that reads one frame, checks it is the release of `session`,
/// and answers with `reply`, or closes without a word when there is none.
fn release_stand_in(session: String, reply: Result(Bool, Nil)) -> Int {
  let assert Ok(listener) =
    listen(0, [
      atom("binary"),
      dynamic.array([atom("packet"), dynamic.int(4)]),
      dynamic.array([atom("active"), dynamic.bool(False)]),
      dynamic.array([
        atom("ip"),
        dynamic.array(list.map([127, 0, 0, 1], dynamic.int)),
      ]),
    ])
  let assert Ok(port) = port_of(listener)
  spawn(fn() {
    let assert Ok(socket) = accept(listener)
    let assert Ok(#("release", frame)) = next_frame(socket)
    assert frame
      == tagged("release", [record([#("session", dynamic.string(session))])])
    case reply {
      Ok(freed) ->
        send(
          socket,
          term.encode(
            tagged("released", [
              record([
                #("session", dynamic.string(session)),
                #("freed", dynamic.bool(freed)),
              ]),
            ]),
          ),
        )
      Error(Nil) -> dynamic.nil()
    }
    close(socket)
    close(listener)
  })
  port
}

/// The release frame passes the contract's checker, and the sender reports
/// the three things that can happen: freed, not freed, no answer. A session
/// id is opaque text such as `intake_1:42` (T6.5b).
pub fn release_test() {
  assert check_frame(term.decode(wire.release("intake_1:42"))) == atom("ok")
  assert sender.release(
      release_stand_in("intake_1:42", Ok(True)),
      "intake_1:42",
    )
    == sender.ReleaseAnswered("intake_1:42", True)
  assert sender.release(release_stand_in("nope", Ok(False)), "nope")
    == sender.ReleaseAnswered("nope", False)
  assert sender.release(
      release_stand_in("intake_2:7", Error(Nil)),
      "intake_2:7",
    )
    == sender.ReleaseFailed(
      "the transpiler closed the connection without answering the release",
    )
}

/// With a transpiler: releasing a session it does not know answers `freed`
/// false (R9). It runs only when TO_SILICA_RELEASE_PORT is set, apart from
/// the check-mode tests: the transpiler build of 2026-11-13 can end with a
/// memory fault on a release connection (../APP_GAPS.md, C1), and would take
/// the other online tests with it.
pub fn release_unknown_session_test() {
  case
    from_charlist(getenv(to_charlist("TO_SILICA_RELEASE_PORT"), to_charlist("")))
  {
    "" -> Nil
    port -> {
      let assert Ok(port) = int.parse(port)
      assert sender.release(port, "no-such-session")
        == sender.ReleaseAnswered("no-such-session", False)
    }
  }
}

// ------------------------------------------------------------ types (contract 8.6)
//
// The language side decides every type (T8.8). One test for each rule of
// the codex's typing pass: what is hinted, with which type and strength, and
// what becomes a gap when a type the contract requires is missing.

/// T8.10 (b): every variable a `let` binds has its type stated. With an
/// annotation the hint is `proven` (it is the annotation), and the value
/// takes the annotation's type even when the codex knows nothing about it;
/// without one the type is the value's, `inferred`.
pub fn let_bindings_are_typed_test() {
  let text =
    "import other/thing
fn double(n: Int) -> Int { n * 2 }
pub fn f(n: Int) -> Int {
  let a = double(n)
  let b: Int = thing.make()
  let #(c, d) = #(a, 1.5)
  a + b + c
}
"
  assert function_nodes(text, "f")
    == [
      frame.Var(0, "n"),
      frame.Var(1, "n"),
      frame.Call(2, "", "double", [1]),
      frame.Var(3, "a"),
      frame.Match(4, 3, 2),
      frame.Call(5, "other/thing", "make", []),
      frame.Var(6, "b"),
      frame.Match(7, 6, 5),
      frame.Var(8, "a"),
      frame.Float(9, "1.5"),
      frame.Tuple(10, [8, 9]),
      frame.Var(11, "c"),
      frame.Var(12, "d"),
      frame.Tuple(13, [11, 12]),
      frame.Match(14, 13, 10),
      frame.Var(15, "a"),
      frame.Var(16, "b"),
      frame.Op(17, "+", [15, 16]),
      frame.Var(18, "c"),
      frame.Op(19, "+", [17, 18]),
      frame.Block(20, [4, 7, 14, 19]),
      frame.Clause(21, [0], -1, 20),
    ]
  let #(types, hints) = function_hints(text, "f")
  let hint = fn(node) { hint_type(types, hints, node) }
  // The parameter: its annotation.
  assert hint(0) == #("int", frame.Proven)
  // `a`: the result type of double, from its signature.
  assert hint(3) == #("int", frame.Inferred)
  // `b` and its value: the let's annotation.
  assert hint(5) == #("int", frame.Proven)
  assert hint(6) == #("int", frame.Proven)
  // `c` and `d`: the value's type taken apart by position.
  assert hint(10) == #("#(int, float)", frame.Inferred)
  assert hint(11) == #("int", frame.Inferred)
  assert hint(12) == #("float", frame.Inferred)
  // T8.10 (e): a match that is not the last expression of its block.
  assert hint(4) == #("int", frame.Inferred)
  // T8.9: literals, variables used as values and operators are fixed by
  // themselves and carry no hint.
  list.each([1, 8, 9, 15, 17, 19], fn(node) {
    assert hint(node) == #("none", frame.Inferred)
  })
}

/// T8.10 (d): the result of a call that is used has a type: a function of
/// the module by its annotated signature (with its type variables taken
/// from the arguments), a call through a function value by the value's
/// type, a known function of the standard library by the codex's table.
pub fn call_results_are_typed_test() {
  let text =
    "import gleam/int
import gleam/io
fn id(x: a) -> a { x }
fn pair(x: a, y: b) -> #(b, a) { #(y, x) }
pub fn f(g: fn(Int) -> Float, n: Int) -> String {
  io.println(int.to_string(n))
  let p = pair(id(n), g(n))
  \"done\"
}
"
  assert function_nodes(text, "f")
    == [
      frame.Var(0, "g"),
      frame.Var(1, "n"),
      frame.Var(2, "n"),
      // io.println(int.to_string(n)): the print builtins (T9.16), then nil.
      frame.SlCall(3, "", "print_int64", [2]),
      frame.Text(4, ""),
      frame.SlCall(5, "", "println", [4]),
      frame.Symbol(6, "nil"),
      frame.Block(7, [3, 5, 6]),
      frame.Var(8, "n"),
      frame.Call(9, "", "id", [8]),
      frame.Var(10, "g"),
      frame.Var(11, "n"),
      frame.Apply(12, 10, [11]),
      frame.Call(13, "", "pair", [9, 12]),
      frame.Var(14, "p"),
      frame.Match(15, 14, 13),
      frame.Text(16, "done"),
      frame.Block(17, [7, 15, 16]),
      frame.Clause(18, [0, 1], -1, 17),
    ]
  let #(types, hints) = function_hints(text, "f")
  let hint = fn(node) { hint_type(types, hints, node) }
  // T9.16: an (:sl_call) of a print builtin needs no hint; its block is Nil.
  assert hint(3) == #("none", frame.Inferred)
  assert hint(7) == #("nil", frame.Inferred)
  assert hint(9) == #("int", frame.Inferred)
  assert hint(12) == #("float", frame.Inferred)
  assert hint(13) == #("#(float, int)", frame.Inferred)
  assert hint(14) == #("#(float, int)", frame.Inferred)
}

/// T8.10 (c), T8.11: Gleam's `+` and `+.` are one `op` on the wire, so the
/// operands' stated types carry the difference. An operand the codex has no
/// type for is hinted from the operator's spelling: Int under `+` and `>`,
/// Float under `+.` and `>.`, String under `<>`, Bool under `&&`.
pub fn operator_spelling_types_the_operands_test() {
  let text =
    "import other/thing
pub fn floats(x: Float) -> Bool { thing.read() +. x >. thing.limit() }
pub fn ints(x: Int) -> Bool { thing.read() + x > thing.limit() }
pub fn texts() -> String { thing.name() <> \"!\" }
pub fn bools() -> Bool { thing.ready() && !thing.busy() }
pub fn same(x: Float) -> Bool { thing.read() == x }
pub fn neither() -> Bool { thing.read() == thing.limit() }
"
  let nodes = [
    frame.Var(0, "x"),
    frame.Call(1, "other/thing", "read", []),
    frame.Var(2, "x"),
    frame.Op(3, "+", [1, 2]),
    frame.Call(4, "other/thing", "limit", []),
    frame.Op(5, ">", [3, 4]),
    frame.Clause(6, [0], -1, 5),
  ]
  // The same nodes for both; only the stated types differ.
  assert function_nodes(text, "floats") == nodes
  assert function_nodes(text, "ints") == nodes
  let hinted = fn(name, node) {
    let #(types, hints) = function_hints(text, name)
    hint_type(types, hints, node)
  }
  assert hinted("floats", 1) == #("float", frame.Inferred)
  assert hinted("floats", 4) == #("float", frame.Inferred)
  assert hinted("ints", 1) == #("int", frame.Inferred)
  assert hinted("ints", 4) == #("int", frame.Inferred)
  assert hinted("texts", 0) == #("text", frame.Inferred)
  assert hinted("bools", 0) == #("boolean", frame.Inferred)
  assert hinted("bools", 1) == #("boolean", frame.Inferred)
  // `==`: an operand without a type takes the other operand's.
  assert hinted("same", 1) == #("float", frame.Inferred)
  // With no type on either side the comparison is a gap that says so.
  let assert [frame.GapNode(0, "operator ==", note), _] =
    function_nodes(text, "neither")
  assert string.starts_with(
    note,
    "neither operand has a type known to this codex",
  )
  assert string.ends_with(note, "(T8.10 c)")
}

/// T8.15: Gleam's `a / 0` is 0. Silica's integer division by zero ends the
/// actor (limitation observed, Appendix B), so `/` is sent with a guard on
/// the divisor. Both operands are variables here: nothing has to be bound.
pub fn int_division_is_guarded_test() {
  let text = "pub fn f(a: Int, b: Int) -> Int { a / b }"
  assert function_nodes(text, "f")
    == [
      frame.Var(0, "a"),
      frame.Var(1, "b"),
      // b == 0
      frame.Var(2, "b"),
      frame.Int(3, 0),
      frame.Op(4, "==", [2, 3]),
      // True -> 0
      frame.Boolean(5, True),
      frame.Int(6, 0),
      frame.Clause(7, [5], -1, 6),
      // False -> a div b
      frame.Boolean(8, False),
      frame.Var(9, "a"),
      frame.Var(10, "b"),
      frame.Op(11, "div", [9, 10]),
      frame.Clause(12, [8], -1, 11),
      frame.Case(13, 4, [7, 12]),
      frame.Clause(14, [0, 1], -1, 13),
    ]
  let #(types, hints) = function_hints(text, "f")
  assert hint_type(types, hints, 13) == #("int", frame.Inferred)
}

/// T8.15: `a % 0` is 0 in Gleam. The operands are calls here, so each is
/// bound first and evaluated exactly once, the left one first, also when
/// the divisor is zero.
pub fn remainder_is_guarded_test() {
  let text =
    "fn double(n: Int) -> Int { n * 2 }
pub fn f(a: Int, b: Int) -> Int { double(a) % double(b) }
"
  assert function_nodes(text, "f")
    == [
      frame.Var(0, "a"),
      frame.Var(1, "b"),
      frame.Var(2, "a"),
      frame.Call(3, "", "double", [2]),
      frame.Var(4, "_dividend_2"),
      frame.Match(5, 4, 3),
      frame.Var(6, "b"),
      frame.Call(7, "", "double", [6]),
      frame.Var(8, "_divisor_2"),
      frame.Match(9, 8, 7),
      frame.Var(10, "_divisor_2"),
      frame.Int(11, 0),
      frame.Op(12, "==", [10, 11]),
      frame.Boolean(13, True),
      frame.Int(14, 0),
      frame.Clause(15, [13], -1, 14),
      frame.Boolean(16, False),
      frame.Var(17, "_dividend_2"),
      frame.Var(18, "_divisor_2"),
      frame.Op(19, "rem", [17, 18]),
      frame.Clause(20, [16], -1, 19),
      frame.Case(21, 12, [15, 20]),
      frame.Block(22, [5, 9, 21]),
      frame.Clause(23, [0, 1], -1, 22),
    ]
  let #(types, hints) = function_hints(text, "f")
  let hint = fn(node) { hint_type(types, hints, node) }
  // The bindings the codex makes have their type stated like any other.
  assert hint(4) == #("int", frame.Inferred)
  assert hint(8) == #("int", frame.Inferred)
  assert hint(22) == #("int", frame.Inferred)
}

/// T8.15: `a /. 0.0` is 0.0 in Gleam; Silica's float division by zero gives
/// a value that is no number (limitation observed). The guard compares with
/// the float literal and gives the float literal. A divisor that is a
/// literal other than zero needs no guard.
pub fn float_division_is_guarded_test() {
  let text =
    "pub fn f(a: Float, b: Float) -> Float { a /. b }
pub fn half(a: Float, n: Int) -> Float { a /. 2.0 }
pub fn third(n: Int) -> Int { n / 3 + n % 3 }
"
  assert function_nodes(text, "f")
    == [
      frame.Var(0, "a"),
      frame.Var(1, "b"),
      frame.Var(2, "b"),
      frame.Float(3, "0.0"),
      frame.Op(4, "==", [2, 3]),
      frame.Boolean(5, True),
      frame.Float(6, "0.0"),
      frame.Clause(7, [5], -1, 6),
      frame.Boolean(8, False),
      frame.Var(9, "a"),
      frame.Var(10, "b"),
      frame.Op(11, "/", [9, 10]),
      frame.Clause(12, [8], -1, 11),
      frame.Case(13, 4, [7, 12]),
      frame.Clause(14, [0, 1], -1, 13),
    ]
  let #(types, hints) = function_hints(text, "f")
  assert hint_type(types, hints, 13) == #("float", frame.Inferred)
  let assert [
    _,
    _,
    frame.Var(2, "a"),
    frame.Float(3, "2.0"),
    frame.Op(4, "/", [2, 3]),
    _,
  ] = function_nodes(text, "half")
  let assert [
    _,
    frame.Var(1, "n"),
    frame.Int(2, 3),
    frame.Op(3, "div", [1, 2]),
    frame.Var(4, "n"),
    frame.Int(5, 3),
    frame.Op(6, "rem", [4, 5]),
    frame.Op(7, "+", [3, 6]),
    _,
  ] = function_nodes(text, "third")
}

/// T8.12: Gleam converts numbers only through functions of its standard
/// library. The three the contract has an operator for are sent as that
/// operator: int.to_float is `to_float`, float.truncate `trunc`,
/// float.round `round`. float.floor gives a Float in Gleam: it stays a call,
/// with its result type stated.
pub fn conversions_are_operators_test() {
  let text =
    "import gleam/float
import gleam/int
pub fn f(n: Int, x: Float) -> Float {
  int.to_float(n) +. int.to_float(float.truncate(x) + float.round(x)) +. float.floor(x)
}
"
  assert function_nodes(text, "f")
    == [
      frame.Var(0, "n"),
      frame.Var(1, "x"),
      frame.Var(2, "n"),
      frame.Op(3, "to_float", [2]),
      frame.Var(4, "x"),
      frame.Op(5, "trunc", [4]),
      frame.Var(6, "x"),
      frame.Op(7, "round", [6]),
      frame.Op(8, "+", [5, 7]),
      frame.Op(9, "to_float", [8]),
      frame.Op(10, "+", [3, 9]),
      frame.Var(11, "x"),
      frame.Call(12, "gleam/float", "floor", [11]),
      frame.Op(13, "+", [10, 12]),
      frame.Clause(14, [0, 1], -1, 13),
    ]
  let #(types, hints) = function_hints(text, "f")
  assert hint_type(types, hints, 12) == #("float", frame.Inferred)
}

/// When the codex has no type where the contract requires one (T8.10), the
/// construct is a gap whose note says what is missing; nothing is sent
/// untyped. A statement that is a gap ends its block.
pub fn a_missing_type_is_a_gap_test() {
  let text =
    "import gleam/list
import other/thing
fn double(n: Int) -> Int { n * 2 }
pub fn binding(items: List(Int)) -> Int {
  let xs = list.map(items, double)
  1
}
pub fn dropped(n: Int) -> Int {
  thing.log(n)
  n
}
pub fn subject() -> Int {
  case thing.read() { 0 -> 1  _ -> 2 }
}
pub fn closure() -> Int {
  let f = fn(x) { x }
  1
}
pub fn passed_on(n: Int) -> Int { double(thing.make(n)) }
pub fn parameter(n) { n }
pub fn derived(n: Int) { n + 1 }
pub fn result(n: Int) { thing.make(n) }
"
  let sole_gap = fn(name) {
    let assert [frame.GapNode(_, construct, note)] =
      list.filter(function_nodes(text, name), fn(node) {
        case node {
          frame.GapNode(..) -> True
          _ -> False
        }
      })
    #(construct, note)
  }
  // T8.10 (b): the value of a let, from a function of another module.
  assert sole_gap("binding")
    == #(
      "list.map/2",
      "the result type of gleam/list.map/2 is not known to this codex (it has the signatures of this module's functions and of a few functions of the standard library), so the binding xs has no type (T8.10 b)",
    )
  // The gap ends the block: the `1` after it is not sent.
  assert function_nodes(text, "binding")
    |> list.filter(fn(node) {
      case node {
        frame.Int(..) -> True
        _ -> False
      }
    })
    == []
  // T8.10 (d), (e): a call whose value is dropped.
  let assert #("thing.log/1", note) = sole_gap("dropped")
  assert string.ends_with(
    note,
    "so this statement, whose value is dropped, has no type (T8.10 d, e)",
  )
  // T8.10 (e): the subject of a case.
  let assert #("case", note) = sole_gap("subject")
  assert string.ends_with(
    note,
    "so the subject of this case has no type (T8.10 e)",
  )
  // T8.10 (a): a closure whose parameter has no type.
  let assert #("anonymous function", note) = sole_gap("closure")
  assert string.contains(note, "has no type annotation")
  // T8.10 (d): a call whose value is only passed on needs no type, and the
  // call it is passed to has its own.
  assert function_nodes(text, "passed_on")
    == [
      frame.Var(0, "n"),
      frame.Var(1, "n"),
      frame.Call(2, "other/thing", "make", [1]),
      frame.Call(3, "", "double", [2]),
      frame.Clause(4, [0], -1, 3),
    ]
  // T8.10 (a): a function without a signature is a gap form...
  let gap_form = fn(name) {
    let assert Ok(frame.Gap(construct:, note:, ..)) =
      list.find(forms(unit_of(text)), fn(form) {
        case form {
          frame.Gap(name: found, ..) -> found == name
          _ -> False
        }
      })
    #(construct, note)
  }
  assert gap_form("parameter")
    == #(
      "function parameter/1",
      "a parameter of parameter has no type annotation, and this codex does not infer parameter types, so the function has no signature (T8.10 a)",
    )
  let assert #("function result/1", note) = gap_form("result")
  assert string.contains(note, "the result type of other/thing.make/1")
  // ...unless only the result is not annotated and the body gives it: then
  // the signature is `inferred`.
  let #(types, hints) = function_hints(text, "derived")
  assert hint_type(types, hints, -1) == #("fn(int) -> int", frame.Inferred)
}

/// T5.3, T8.14: the type forms of a unit come before every other form, and
/// a type comes after the types it names. A generic type is declared with
/// its parameters as `t_var`, and named with its arguments. A type that
/// names itself is sent as it is.
pub fn type_forms_come_first_test() {
  let text =
    "pub fn first() -> Int { 1 }
pub type Wrap { Wrap(inner: Box(Int), sign: Sign) }
pub fn boxed(b: Box(Float)) -> Float { let Box(value:) = b  value +. b.value }
pub type Box(a) { Box(value: a) }
pub type Sign { Plus  Minus }
pub type Tree(a) { Leaf  Node(Tree(a), a, Tree(a)) }
pub fn tree() -> Tree(Int) { Node(Leaf, 1, Leaf) }
"
  let assert [
    frame.Type(name: "sample_box", params: ["a"], types: box, ..),
    frame.Type(name: "sample_sign", ..),
    frame.Type(name: "sample_wrap", params: [], types: wrap, ..),
    frame.Type(name: "sample_tree", params: ["a"], types: tree, root: 4, ..),
    frame.Function(name: "first", ..),
    frame.Function(name: "boxed", ..),
    frame.Function(name: "tree", ..),
  ] = forms(unit_of(text))
  assert box == [frame.TVar("a"), frame.TRecord([#("value", 0)])]
  assert wrap
    == [
      frame.TInt,
      frame.TNamed("sample_box", [0]),
      frame.TNamed("sample_sign", []),
      frame.TRecord([#("inner", 1), #("sign", 2)]),
    ]
  assert tree
    == [
      frame.TSymbols(["leaf"]),
      frame.TVar("a"),
      frame.TNamed("sample_tree", [1]),
      frame.TTagged("node", [2, 1, 2]),
      frame.TUnion([0, 3]),
    ]
  // A generic type in use: its argument is stated, and a field of it has
  // the argument's type.
  let #(types, hints) = function_hints(text, "boxed")
  let hint = fn(node) { hint_type(types, hints, node) }
  assert hint(-1) == #("fn(sample_box(float)) -> float", frame.Proven)
  assert hint(2) == #("float", frame.Inferred)
  assert hint(7) == #("float", frame.Inferred)
  // A constructor's value is stated as its type, arguments included.
  let #(types, hints) = function_hints(text, "tree")
  assert hint_type(types, hints, 4) == #("sample_tree(int)", frame.Inferred)
  assert hint_type(types, hints, 1) == #("sample_tree(int)", frame.Inferred)
  // In the example, too, no form names a type before its type form.
  let assert [frame.Type(..), frame.Type(..), frame.Type(..), ..rest] =
    forms(example_frames())
  assert list.all(rest, fn(form) {
    case form {
      frame.Type(..) -> False
      _ -> True
    }
  })
}

/// T8.10 (a): a closure has a `t_fun` hint on its node. Its parameter types
/// are their annotations (`proven` when the result is annotated too), or the
/// type of the parameter the closure is passed for; a capture's parameter
/// is the type the function declares at the hole. (The last fn uses `n`, a
/// variable of `f`: a closure. One that captures nothing is made a function,
/// `lift_test`.)
pub fn closures_are_typed_test() {
  let text =
    "fn twice(f: fn(Int) -> Int, n: Int) -> Int { f(f(n)) }
fn add(a: Int, b: Int) -> Int { a + b }
pub fn f(n: Int) -> Int {
  let annotated = fn(x: Int) -> Int { x + 1 }
  let add_two = add(2, _)
  twice(fn(x) { x * n }, n)
}
"
  let assert [
    frame.Var(0, "n"),
    frame.Var(1, "x"),
    _,
    _,
    _,
    _,
    frame.Lambda(6, [5]),
    frame.Var(7, "annotated"),
    frame.Match(8, 7, 6),
    frame.Var(9, "_capture"),
    frame.Int(10, 2),
    frame.Var(11, "_capture"),
    frame.Call(12, "", "add", [10, 11]),
    frame.Clause(13, [9], -1, 12),
    frame.Lambda(14, [13]),
    frame.Var(15, "add_two"),
    frame.Match(16, 15, 14),
    frame.Var(17, "x"),
    frame.Var(18, "x"),
    frame.Var(19, "n"),
    frame.Op(20, "*", [18, 19]),
    frame.Clause(21, [17], -1, 20),
    frame.Lambda(22, [21]),
    ..
  ] = function_nodes(text, "f")
  let #(types, hints) = function_hints(text, "f")
  let hint = fn(node) { hint_type(types, hints, node) }
  assert hint(1) == #("int", frame.Proven)
  assert hint(6) == #("fn(int) -> int", frame.Proven)
  assert hint(9) == #("int", frame.Inferred)
  assert hint(14) == #("fn(int) -> int", frame.Inferred)
  assert hint(17) == #("int", frame.Inferred)
  assert hint(22) == #("fn(int) -> int", frame.Inferred)
}

/// A case with a clause whose pattern cannot be sent is one gap, whole: a
/// case sent without one of its clauses would be another program, and the
/// variables of that clause would have no binding (T8.10 b). A field is
/// read only from a value whose type is sent as a record (T8.9).
pub fn patterns_and_fields_test() {
  let text =
    "pub type Shape { Square(side: Int)  Circle(radius: Float) }
pub fn lists(items: List(Int)) -> Int {
  case items {
    [] -> 0
    <<first, _:bits>> -> first
  }
}
pub fn side(s: Shape) -> Int { s.side }
"
  let assert [_, frame.GapNode(1, "bit array pattern", note), _] =
    function_nodes(text, "lists")
  assert string.ends_with(note, "so the whole case is this gap")
  let assert [_, frame.GapNode(1, ".side", note), _] =
    function_nodes(text, "side")
  assert string.contains(note, "is not of a type this codex sends as a record")
}

// ------------------------------------------------------------ credit and stored (T6.2, T6.3)

@external(erlang, "gen_tcp", "recv")
fn recv_within(
  socket: Socket,
  length: Int,
  timeout: Int,
) -> Result(BitArray, Dynamic)

/// T6.2, T6.3, T6.11a: a session of more frames than the window (64). The
/// stand-in behaves as the transpiler is built: after the first half window
/// it sends `(:stored, n)` and `(:credit, 32)`, which the sender must read
/// while it still has credit; after that it lets the sender use its whole
/// window and checks that **nothing arrives while the sender has no
/// credit**, before it sends the next pair. A sender that wrote everything
/// first would fail that check, and one that read nothing would stall.
pub fn sender_reads_while_sending_test() {
  let assert Ok(text) = simplifile.read(example)
  let assert Ok(frames) =
    codex.session(
      [
        Source("a/demo.gleam", text),
        Source("b/demo.gleam", text),
        Source("c/demo.gleam", text),
      ],
      frame.Transpile,
    )
  // Every frame but the hello uses a credit.
  let sent = list.length(frames) - 1
  assert sent > 100
  let assert Ok(listener) =
    listen(0, [
      atom("binary"),
      dynamic.array([atom("packet"), dynamic.int(4)]),
      dynamic.array([atom("active"), dynamic.bool(False)]),
      dynamic.array([
        atom("ip"),
        dynamic.array(list.map([127, 0, 0, 1], dynamic.int)),
      ]),
    ])
  let assert Ok(port) = port_of(listener)
  spawn(fn() { windowed_stand_in(listener) })
  let outcome = sender.run(port, frames)
  close(listener)
  let assert sender.Completed(
    session: "intake_1:42",
    rejected: [],
    stored:,
    result: Some(sender.Finished(
      status: "ok",
      units: 3,
      rejected: 0,
      session: "intake_1:42",
      ..,
    )),
    ..,
  ) = outcome
  // The last `(:stored, next)` covers every frame.
  assert stored == sent
}

fn windowed_stand_in(listener: Socket) -> Dynamic {
  let text = dynamic.string
  let assert Ok(socket) = accept(listener)
  let assert Ok(#("hello", _)) = next_frame(socket)
  send(
    socket,
    term.encode(
      tagged("welcome", [
        record([
          #("session", text("intake_1:42")),
          #("contract", dynamic.int(1)),
          #("transpiler", text("windowed stand-in")),
          #(
            "flow",
            record([
              #("resume_from", dynamic.int(0)),
              #("credit", dynamic.int(64)),
              #("max_frame", dynamic.int(wire.max_frame)),
            ]),
          ),
        ]),
      ]),
    ),
  )
  let #(received, units, without_credit) = windowed_loop(socket, 0, 64, 0, 0)
  send(socket, term.encode(tagged("stored", [dynamic.int(received)])))
  send(
    socket,
    term.encode(
      tagged("result", [
        record([
          #(
            "status",
            atom(case without_credit {
              0 -> "ok"
              _ -> "failed"
            }),
          ),
          #(
            "counts",
            record([
              #("units", dynamic.int(units)),
              #("gaps", dynamic.int(0)),
              #("rejected", dynamic.int(without_credit)),
            ]),
          ),
          #("session", text("intake_1:42")),
          #("files", dynamic.int(0)),
        ]),
      ]),
    ),
  )
  close(socket)
}

/// Reads frames until the end. `credit` is what the sender holds, as the
/// stand-in counts it; a frame that arrives while it is 0 was sent without
/// credit.
fn windowed_loop(
  socket: Socket,
  received: Int,
  credit: Int,
  units: Int,
  without_credit: Int,
) -> #(Int, Int, Int) {
  let grant = fn() {
    send(socket, term.encode(tagged("stored", [dynamic.int(received)])))
    send(socket, term.encode(tagged("credit", [dynamic.int(32)])))
  }
  case credit, received {
    // The sender has used its whole window: for a while nothing may come.
    0, _ -> {
      let without_credit = case recv_within(socket, 0, 200) {
        Ok(_) -> without_credit + 1
        Error(_) -> without_credit
      }
      grant()
      windowed_loop(socket, received, 32, units, without_credit)
    }
    // Half of the first window is used: the pair the sender reads while it
    // still holds credit.
    32, 32 -> {
      grant()
      windowed_loop(socket, received, 64, units, without_credit)
    }
    _, _ -> {
      let assert Ok(#(tag, _)) = next_frame(socket)
      case tag {
        "end" -> #(received + 1, units, without_credit)
        "unit_begin" ->
          windowed_loop(
            socket,
            received + 1,
            credit - 1,
            units + 1,
            without_credit,
          )
        _ ->
          windowed_loop(socket, received + 1, credit - 1, units, without_credit)
      }
    }
  }
}

// ------------------------------------------------------------ T8.10 (c), T8.11 over the examples

/// The stated type of a node, as T8.9 defines it: its hint; else what the
/// node fixes (a literal, an operator); for a variable used as a value, the
/// hint of its binding (the nearest hinted variable of that name before it).
fn stated_type(
  nodes: List(frame.Node),
  types: List(frame.TypeNode),
  hints: List(frame.Hint),
  index: Int,
) -> String {
  let stated = stated_type(nodes, types, hints, _)
  case hint_type(types, hints, index).0, list.drop(nodes, index) {
    "none", [frame.Int(..), ..] -> "int"
    "none", [frame.Float(..), ..] -> "float"
    "none", [frame.Text(..), ..] -> "text"
    "none", [frame.Boolean(..), ..] -> "boolean"
    "none", [frame.Var(name:, ..), ..] ->
      list.take(nodes, index)
      |> list.reverse
      |> list.find_map(fn(node) {
        case node {
          frame.Var(at:, name: bound) if bound == name ->
            case hint_type(types, hints, at).0 {
              "none" -> Error(Nil)
              found -> Ok(found)
            }
          _ -> Error(Nil)
        }
      })
      |> result.unwrap("none")
    "none", [frame.Op(op:, args:, ..), ..] ->
      case op, args {
        "<>", _ -> "text"
        "to_float", _ -> "float"
        "trunc", _ | "round", _ -> "int"
        "+", [first, ..]
        | "-", [first, ..]
        | "*", [first, ..]
        | "/", [first, ..]
        | "div", [first, ..]
        | "rem", [first, ..]
        | "neg", [first, ..]
        -> stated(first)
        _, _ -> "boolean"
      }
    found, _ -> found
  }
}

/// T8.10 (c), T8.11 for every operator of both examples: each operand has a
/// stated type, the two operands of an arithmetic or comparison operator
/// have the same one, `div` and `rem` take integers, `/` floats, and a
/// conversion takes the kind it converts from (T8.12).
pub fn every_operand_has_one_stated_type_test() {
  let operators =
    list.flat_map(list.append(example_frames(), actors_frames()), fn(f) {
      case f {
        frame.FormFrame(
          body: frame.Function(name:, nodes:, types:, hints:, ..),
          ..,
        ) ->
          list.filter_map(nodes, fn(node) {
            case node {
              frame.Op(op:, args:, ..) ->
                Ok(#(
                  name,
                  op,
                  list.map(args, stated_type(nodes, types, hints, _)),
                ))
              _ -> Error(Nil)
            }
          })
        _ -> []
      }
    })
  assert list.length(operators) > 40
  list.each(operators, fn(operator) {
    let #(_function, op, operands) = operator
    assert !list.contains(operands, "none")
    case op, operands {
      "div", _ | "rem", _ -> {
        assert operands == ["int", "int"]
      }
      "/", _ -> {
        assert operands == ["float", "float"]
      }
      "to_float", _ -> {
        assert operands == ["int"]
      }
      "trunc", _ | "round", _ -> {
        assert operands == ["float"]
      }
      "<>", _ -> {
        assert operands == ["text", "text"]
      }
      "andalso", _ | "orelse", _ -> {
        assert operands == ["boolean", "boolean"]
      }
      _, [left, right] -> {
        assert left == right
      }
      _, _ -> Nil
    }
  })
  // Both kinds of arithmetic are there, told apart only by the operands.
  let kinds =
    list.filter_map(operators, fn(operator) {
      case operator {
        #(_, "*", [kind, _]) -> Ok(kind)
        _ -> Error(Nil)
      }
    })
  assert list.contains(kinds, "int") && list.contains(kinds, "float")
}

// ------------------------------------------------------------ split.gleam: every receive in tail position (contract T9.13a)

fn function_names(text: String) -> List(String) {
  list.filter_map(forms(unit_of(text)), fn(form) {
    case form {
      frame.Function(name:, ..) -> Ok(name)
      _ -> Error(Nil)
    }
  })
}

/// Code after a receive is a continuation function; several receives give
/// one continuation each. A continuation's parameters are the variables the
/// code after the receive uses (`unused` is not one of them) and the
/// receive's value. A receive of a private function that does not use every
/// variable its function has bound is a function of its own (`f__k2`): the
/// transpiler keeps every bound variable in the waiting process (T9.13a).
/// A public function keeps its receive, so that it is a process function
/// itself (`public_functions_that_wait_test`).
pub fn split_code_after_a_receive_test() {
  let text =
    "import gleam/erlang/process.{type Pid, type Subject}
fn f(inbox: Subject(Int), unused: Int, bonus: Int) -> Int {
  let first = process.receive_forever(inbox)
  let second = process.receive_forever(inbox)
  first + second + bonus
}
pub fn go(inbox: Subject(Int)) -> Pid {
  process.spawn_unlinked(fn() { f(inbox, 1, 2) })
}
"
  assert list.sort(function_names(text), string.compare)
    == ["f", "f__k1", "f__k1__k1", "f__k2", "go"]
  assert function_nodes(text, "f")
    == [
      frame.Var(0, "inbox"),
      frame.Var(1, "unused"),
      frame.Var(2, "bonus"),
      frame.Var(3, "inbox"),
      frame.Var(4, "bonus"),
      frame.Call(5, "", "f__k2", [3, 4]),
      frame.Clause(6, [0, 1, 2], -1, 5),
    ]
  // The first receive, alone: its clause ends with a tail call of the
  // continuation, with the message as the receive's value.
  assert function_nodes(text, "f__k2")
    == [
      frame.Var(0, "inbox"),
      frame.Var(1, "bonus"),
      frame.Symbol(2, "subject__int"),
      frame.Var(3, "_message"),
      frame.Tuple(4, [2, 3]),
      frame.Var(5, "inbox"),
      frame.Var(6, "bonus"),
      frame.Var(7, "_message"),
      frame.Call(8, "", "f__k1", [5, 6, 7]),
      frame.Clause(9, [4], -1, 8),
      frame.Receive(10, [9], -1, -1),
      frame.Clause(11, [0, 1], -1, 10),
    ]
  // The code after the first receive: it starts with the second receive,
  // which uses every variable it has, so it stands in it.
  let assert [
    frame.Var(0, "inbox"),
    frame.Var(1, "bonus"),
    frame.Var(2, "first"),
    ..
  ] = function_nodes(text, "f__k1")
  assert function_nodes(text, "f__k1__k1")
    == [
      frame.Var(0, "bonus"),
      frame.Var(1, "first"),
      frame.Var(2, "second"),
      frame.Var(3, "first"),
      frame.Var(4, "second"),
      frame.Op(5, "+", [3, 4]),
      frame.Var(6, "bonus"),
      frame.Op(7, "+", [5, 6]),
      frame.Clause(8, [0, 1, 2], -1, 7),
    ]
  // A made function is not exported, and its signature is typed from the
  // calls of it and the result annotation of the function it is cut from:
  // `inferred`.
  let assert Ok(frame.Function(exported: False, ..)) =
    list.find(forms(unit_of(text)), fn(form) {
      case form {
        frame.Function(name: "f__k1", ..) -> True
        _ -> False
      }
    })
  let #(types, hints) = function_hints(text, "f__k1")
  assert hint_type(types, hints, -1)
    == #("fn(actor(int), int, int) -> int", frame.Inferred)
  let #(types, hints) = function_hints(text, "f__k2")
  assert hint_type(types, hints, -1)
    == #("fn(actor(int), int) -> int", frame.Inferred)
}

const split_text =
  "import gleam/erlang/process.{type Subject}
pub type Message { Add(Int) Get(Subject(Report)) Stop }
pub type Report { Report(total: Int, adds: Int) }
pub fn branch(inbox: Subject(Message), n: Int) -> Int {
  let got = case n {
    0 -> 0
    _ ->
      case process.receive(inbox, 100) {
        Ok(Add(m)) -> m
        _ -> 1
      }
  }
  got + n
}
fn ask(to: Subject(Message)) -> Result(Report, Nil) {
  let reply: Subject(Report) = process.new_subject()
  process.send(to, Get(reply))
  process.receive(reply, 1000)
}
pub fn total(to: Subject(Message)) -> Int {
  case ask(to) {
    Ok(report) -> report.total
    Error(Nil) -> 0
  }
}
pub fn piped(inbox: Subject(Int)) -> Int {
  let n = inbox |> process.receive_forever
  n + 1
}
pub fn inside(inbox: Subject(Int), n: Int) -> Int {
  n + process.receive_forever(inbox)
}
pub fn lazy(inbox: Subject(Bool), b: Bool) -> Bool {
  b && process.receive_forever(inbox)
}
pub fn tell(to: Subject(Message), back: Subject(#(Int, Int))) -> Nil {
  process.send(to, Stop)
  process.send(back, #(1, 2))
}
pub fn later(inbox: Subject(Int)) -> Int {
  let n = process.receive_forever(inbox)
  use m <- twice(n)
  m + 1
}
fn twice(n: Int, then: fn(Int) -> Int) -> Int { then(n) + then(n) }
"

/// A receive inside the branches of a case, with code after the case: the
/// branch that does not receive calls the continuation with its value, the
/// other one receives and goes on in it. A custom type with variants is a
/// message as it is (T9.12): the receive has one clause for each variant,
/// and gives the continuation the value it took.
pub fn split_receive_in_a_branch_test() {
  let assert [
    frame.Var(0, "inbox"),
    frame.Var(1, "n"),
    frame.Var(2, "n"),
    frame.Int(3, 0),
    frame.Var(4, "n"),
    frame.Int(5, 0),
    frame.Call(6, "", "branch__k1", [4, 5]),
    frame.Clause(7, [3], -1, 6),
    frame.Wild(8),
    frame.Symbol(9, "add"),
    frame.Var(10, "_m1"),
    frame.Tuple(11, [9, 10]),
    frame.Var(12, "n"),
    frame.Symbol(13, "ok"),
    frame.Symbol(14, "add"),
    frame.Var(15, "_m1"),
    frame.Tuple(16, [14, 15]),
    frame.Tuple(17, [13, 16]),
    frame.Call(18, "", "branch__k2", [12, 17]),
    frame.Clause(19, [11], -1, 18),
    ..rest
  ] = function_nodes(split_text, "branch")
  // … a clause for Get, one for Stop (a symbol), and the timeout.
  let assert [
    frame.Clause(_, [0, 1], -1, _),
    frame.Case(_, 2, [7, _]),
    frame.Clause(_, [8], -1, _),
    frame.Receive(_, [19, _, _], within, _),
    ..
  ] = list.reverse(rest)
  assert list.contains(rest, frame.Int(within, 100))
  assert list.contains(rest, frame.Symbol(31, "stop"))
  let #(types, hints) = function_hints(split_text, "branch")
  assert hint_type(types, hints, 11) == #("add(int)", frame.Inferred)
  assert hint_type(types, hints, 16) == #("sample_message", frame.Inferred)
  // The code after the inner receive, then the code after the outer case.
  let #(types, hints) = function_hints(split_text, "branch__k2")
  assert hint_type(types, hints, -1)
    == #("fn(int, ok(sample_message) | error(nil)) -> int", frame.Inferred)
  let #(types, hints) = function_hints(split_text, "branch__k1")
  assert hint_type(types, hints, -1) == #("fn(int, int) -> int", frame.Inferred)
}

/// A call of a function that receives, with code after it: a copy of the
/// callee whose every end is a tail call of the continuation, called in
/// tail position. The continuation's value parameter has the type the
/// callee's result annotation says. The callee itself is private and is
/// called by nothing any more: it is not sent. A value that is neither a
/// symbol nor a tagged tuple (a record, a tuple) is sent under the tag made
/// from its type, `subject__<type>`.
pub fn split_call_of_a_receiving_function_test() {
  let names = function_names(split_text)
  assert !list.contains(names, "ask")
  assert function_nodes(split_text, "total")
    == [
      frame.Var(0, "to"),
      frame.Var(1, "to"),
      frame.Call(2, "", "ask__c1", [1]),
      frame.Clause(3, [0], -1, 2),
    ]
  assert function_nodes(split_text, "ask__c1")
    == [
      frame.Var(0, "to"),
      frame.Self(1),
      frame.Var(2, "reply"),
      frame.Match(3, 2, 1),
      frame.Var(4, "to"),
      frame.Symbol(5, "get"),
      frame.Var(6, "reply"),
      frame.Tuple(7, [5, 6]),
      frame.Send(8, 4, 7),
      frame.Var(9, "reply"),
      frame.Call(10, "", "ask__c1__k1", [9]),
      frame.Block(11, [3, 8, 10]),
      frame.Clause(12, [0], -1, 11),
    ]
  assert function_nodes(split_text, "ask__c1__k1")
    == [
      frame.Var(0, "reply"),
      frame.Symbol(1, "subject__report"),
      frame.Var(2, "_message"),
      frame.Tuple(3, [1, 2]),
      frame.Symbol(4, "ok"),
      frame.Var(5, "_message"),
      frame.Tuple(6, [4, 5]),
      frame.Call(7, "", "total__k1", [6]),
      frame.Clause(8, [3], -1, 7),
      frame.Int(9, 1000),
      frame.Symbol(10, "error"),
      frame.Symbol(11, "nil"),
      frame.Tuple(12, [10, 11]),
      frame.Call(13, "", "total__k1", [12]),
      frame.Receive(14, [8], 9, 13),
      frame.Clause(15, [0], -1, 14),
    ]
  let #(types, hints) = function_hints(split_text, "ask__c1__k1")
  assert hint_type(types, hints, 3)
    == #("subject__report(sample_report)", frame.Inferred)
  let #(types, hints) = function_hints(split_text, "total__k1")
  assert hint_type(types, hints, -1)
    == #("fn(ok(sample_report) | error(nil)) -> int", frame.Inferred)
  // The send of a tuple: under its type's tag. The send of a variant: as it
  // is.
  let sent = function_nodes(split_text, "tell")
  assert list.contains(sent, frame.Symbol(9, "subject__tuple2_int_int"))
  assert list.contains(sent, frame.Tuple(10, [9, 8]))
  assert list.contains(sent, frame.Send(4, 2, 3))
}

/// A pipe into a receive is the call it is. A receive that is an operand is
/// bound first (`_h1`), when everything its statement evaluates before it
/// is a variable or a literal; the right side of `&&` is not always
/// evaluated, so a receive there is this sender's gap. A `use` after a
/// receive is in the continuation (where it is still the codex's gap).
pub fn split_pipes_operands_and_use_test() {
  assert function_nodes(split_text, "piped")
    == [
      frame.Var(0, "inbox"),
      frame.Symbol(1, "subject__int"),
      frame.Var(2, "_message"),
      frame.Tuple(3, [1, 2]),
      frame.Var(4, "_message"),
      frame.Call(5, "", "piped__k1", [4]),
      frame.Clause(6, [3], -1, 5),
      frame.Receive(7, [6], -1, -1),
      frame.Clause(8, [0], -1, 7),
    ]
  assert function_nodes(split_text, "inside__k1")
    == [
      frame.Var(0, "n"),
      frame.Var(1, "_h1"),
      frame.Var(2, "n"),
      frame.Var(3, "_h1"),
      frame.Op(4, "+", [2, 3]),
      frame.Clause(5, [0, 1], -1, 4),
    ]
  let assert [_, _, frame.GapNode(2, "receive inside an expression", note), _] =
    function_nodes(split_text, "lazy")
  assert string.ends_with(note, "bind its value with let first")
  let assert [frame.Var(0, "n"), frame.GapNode(1, construct, _), ..] =
    function_nodes(split_text, "later__k1")
  assert construct == "use, with the rest of its block"
}

/// `io.println` and `io.print` are sent as what they do: an L1 call of a
/// Silica print builtin for each operand of `<>` (contract T9.16), then
/// `nil`. An operand that is not a literal or a variable is evaluated and
/// bound first.
pub fn io_println_is_print_builtins_test() {
  let text =
    "import gleam/float
import gleam/int
import gleam/io
pub const limit = 10
pub fn show(label: String, n: Int, f: Float) -> Nil {
  io.println(label <> \": \" <> int.to_string(n + limit) <> \" \" <> float.to_string(f))
}
pub fn say() -> Nil { io.print(\"hi\") }
pub fn name(n: Int) -> Nil { io.println(\"n = \" <> describe(n)) }
fn describe(n: Int) -> String { case n { 0 -> \"zero\" _ -> \"some\" } }
"
  assert function_nodes(text, "show")
    == [
      frame.Var(0, "label"),
      frame.Var(1, "n"),
      frame.Var(2, "f"),
      frame.Var(3, "n"),
      frame.Call(4, "", "limit", []),
      frame.Op(5, "+", [3, 4]),
      frame.Var(6, "_print_6"),
      frame.Match(7, 6, 5),
      frame.Var(8, "label"),
      frame.SlCall(9, "", "print", [8]),
      frame.Text(10, ": "),
      frame.SlCall(11, "", "print", [10]),
      frame.Var(12, "_print_6"),
      frame.SlCall(13, "", "print_int64", [12]),
      frame.Text(14, " "),
      frame.SlCall(15, "", "print", [14]),
      frame.Var(16, "f"),
      frame.SlCall(17, "", "print_float64", [16]),
      frame.Text(18, ""),
      frame.SlCall(19, "", "println", [18]),
      frame.Symbol(20, "nil"),
      frame.Block(21, [7, 9, 11, 13, 15, 17, 19, 20]),
      frame.Clause(22, [0, 1, 2], -1, 21),
    ]
  assert function_nodes(text, "say")
    == [
      frame.Text(0, "hi"),
      frame.SlCall(1, "", "print", [0]),
      frame.Symbol(2, "nil"),
      frame.Block(3, [1, 2]),
      frame.Clause(4, [], -1, 3),
    ]
  // A String that is a call: bound, then printed with println.
  let assert [
    frame.Var(0, "n"),
    frame.Var(1, "n"),
    frame.Call(2, "", "describe", [1]),
    frame.Var(3, bound),
    frame.Match(4, 3, 2),
    frame.Text(5, "n = "),
    frame.SlCall(6, "", "print", [5]),
    frame.Var(7, again),
    frame.SlCall(8, "", "println", [7]),
    ..
  ] = function_nodes(text, "name")
  assert bound == again
  // A constant with a literal value is a function of no parameters.
  assert function_nodes(text, "limit")
    == [frame.Int(0, 10), frame.Clause(1, [], -1, 0)]
}

/// Lists (H7, H10), a type alias (another name for its type: no form), and
/// an external type that erlang:self/0 gives (a process, not `dynamic`).
pub fn lists_aliases_and_process_types_test() {
  let text =
    "pub type Pair = #(Int, Int)
pub fn sum(p: Pair, items: List(Int)) -> List(Int) {
  let #(a, _) = p
  case items {
    [] -> [a, 2]
    [first, ..rest] -> [first, ..rest]
  }
}
@external(erlang, \"erlang\", \"self\")
fn self() -> Pid
pub type Pid
pub fn me() -> Pid { self() }
"
  assert gap_constructs(nodes(unit_of(text))) == []
  assert list.all(forms(unit_of(text)), fn(form) {
    case form {
      frame.Gap(..) -> False
      _ -> True
    }
  })
  let sent = function_nodes(text, "sum")
  assert list.contains(sent, frame.EmptyList(8))
  let assert [
    frame.Clause(_, [0, 1], -1, _),
    frame.Block(..),
    frame.Case(_, _, [_, _]),
    frame.Clause(_, [_], -1, value),
    frame.ListOf(_, [_], tail),
    frame.Var(_, "rest"),
    frame.Var(_, "first"),
    frame.ListOf(_, [_], _),
    ..
  ] = list.reverse(sent)
  assert tail == value - 1
  let #(types, hints) = function_hints(text, "sum")
  assert hint_type(types, hints, -1)
    == #("fn(#(int, int), list(int)) -> list(int)", frame.Proven)
  assert hint_type(types, hints, value) == #("list(int)", frame.Inferred)
  let #(types, hints) = function_hints(text, "me")
  assert hint_type(types, hints, -1)
    == #("fn() -> actor(dynamic)", frame.Proven)
}

/// A public function that waits. With a receive of its own it keeps the
/// receive, whatever variables it has bound: it is then a process function
/// itself, which is what an exported function that waits must be (contract
/// T9.13). One that waits only in a function it calls is no process function
/// and cannot be called as an ordinary function either: it is sent as not
/// exported.
pub fn public_functions_that_wait_test() {
  let text =
    "import gleam/erlang/process.{type Subject}
pub fn own(inbox: Subject(Int), unused: Int) -> Int {
  let n = process.receive_forever(inbox)
  n + 1
}
fn ask(inbox: Subject(Int)) -> Int { process.receive_forever(inbox) }
pub fn through(inbox: Subject(Int)) -> Int {
  let n = ask(inbox)
  n + 1
}
pub fn plain(n: Int) -> Int { n + 1 }
"
  let exported =
    list.filter_map(forms(unit_of(text)), fn(form) {
      case form {
        frame.Function(name:, exported:, ..) -> Ok(#(name, exported))
        _ -> Error(Nil)
      }
    })
  assert list.key_find(exported, "own") == Ok(True)
  assert list.key_find(exported, "through") == Ok(False)
  assert list.key_find(exported, "plain") == Ok(True)
  assert list.key_find(exported, "own__k1") == Ok(False)
  assert function_nodes(text, "own")
    == [
      frame.Var(0, "inbox"),
      frame.Var(1, "unused"),
      frame.Symbol(2, "subject__int"),
      frame.Var(3, "_message"),
      frame.Tuple(4, [2, 3]),
      frame.Var(5, "_message"),
      frame.Call(6, "", "own__k1", [5]),
      frame.Clause(7, [4], -1, 6),
      frame.Receive(8, [7], -1, -1),
      frame.Clause(9, [0, 1], -1, 8),
    ]
}

const supervisor_text =
  "import gleam/erlang/process.{type Name, type Subject}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
pub type Message { Add(Int) Total(Subject(Int)) }
fn handle(total: Int, message: Message) -> actor.Next(Int, Message) {
  case message {
    Add(n) -> actor.continue(total + n)
    Total(reply) -> { process.send(reply, total)  actor.continue(total) }
  }
}
fn start_tally(name: Name(Message)) -> actor.StartResult(Subject(Message)) {
  actor.new(7) |> actor.named(name) |> actor.on_message(handle) |> actor.start
}
fn start_sup(name: Name(Message)) -> actor.StartResult(supervisor.Supervisor) {
  supervisor.new(supervisor.RestForOne)
  |> supervisor.restart_tolerance(intensity: 3, period: 10)
  |> supervisor.add(supervision.worker(fn() { start_tally(name) }))
  |> supervisor.start
}
pub fn start() -> Name(Message) {
  let tally: Name(Message) = process.new_name(\"tally\")
  let assert Ok(_) = start_sup(tally)
  tally
}
pub fn add(tally: Name(Message), n: Int) -> Nil {
  process.send(process.named_subject(tally), Add(n))
}
pub fn bound(tally: Name(Message), n: Int) -> Int {
  let subject = process.named_subject(tally)
  process.send(subject, Add(n))
  n
}
fn forward(to: Subject(Message), n: Int) -> Nil { process.send(to, Add(n)) }
pub fn passed(tally: Name(Message), n: Int) -> Nil {
  forward(process.named_subject(tally), n)
}
"

/// gleam_otp's static supervisor, read from the source (sup.gleam) and sent
/// as the contract's static child (T9.14b): where the supervisor is started,
/// a `register` of an unlinked `spawn` of the actor's loop function with its
/// literal state, under the name the unit makes for the actor's message
/// type, with the child's restart (not written: `permanent`, gleam_otp's
/// default) and the supervisor's strategy as an A4.4 override on the spawn
/// (T7.6). The functions that only describe the supervisor are not sent. A
/// send to `process.named_subject(name)` is a `send_named` (T9.14c).
pub fn static_supervisor_test() {
  let text = supervisor_text
  let names = function_names(text)
  assert !list.contains(names, "start_sup")
  assert !list.contains(names, "start_tally")
  assert list.contains(names, "gleam_otp_actor_loop__g1")
  let assert Ok(frame.Function(nodes:, overrides:, types:, hints:, ..)) =
    list.find(forms(unit_of(text)), fn(form) {
      case form {
        frame.Function(name: "start", ..) -> True
        _ -> False
      }
    })
  assert nodes
    == [
      frame.Symbol(0, "tally"),
      frame.Var(1, "tally"),
      frame.Match(2, 1, 0),
      frame.Int(3, 7),
      frame.FunRef(4, "", "gleam_otp_actor_loop__g1", 1),
      frame.Spawn(5, 4, [3], False),
      frame.Register(6, "tally", 5),
      frame.Var(7, "tally"),
      frame.Block(8, [2, 6, 7]),
      frame.Clause(9, [], -1, 8),
    ]
  assert overrides
    == [
      frame.Override(
        node: 5,
        requirement: "a4_4",
        choice: "chosen",
        params: [#("restart", "permanent"), #("strategy", "rest_for_one")],
        note: "the child specification (supervision.restart) and the strategy of static_supervisor.new",
      ),
    ]
  let hint = fn(node) { hint_type(types, hints, node) }
  // A name travels as the symbol of its literal; the register's value is
  // `true`; the spawn is the actor's process.
  assert hint(-1) == #("fn() -> tally", frame.Proven)
  assert hint(1) == #("tally", frame.Proven)
  assert hint(5) == #("actor(sample_message)", frame.Inferred)
  assert hint(6) == #("boolean", frame.Inferred)
  // A send to the name, written at the send and through a let.
  assert function_nodes(text, "add")
    == [
      frame.Var(0, "tally"),
      frame.Var(1, "n"),
      frame.Symbol(2, "add"),
      frame.Var(3, "n"),
      frame.Tuple(4, [2, 3]),
      frame.SendNamed(5, "tally", 4),
      frame.Symbol(6, "nil"),
      frame.Block(7, [5, 6]),
      frame.Clause(8, [0, 1], -1, 7),
    ]
  let assert [
    frame.Var(0, "tally"),
    frame.Var(1, "n"),
    frame.Var(2, "tally"),
    frame.Var(3, "subject"),
    frame.Match(4, 3, 2),
    frame.Symbol(5, "add"),
    frame.Var(6, "n"),
    frame.Tuple(7, [5, 6]),
    frame.SendNamed(8, "tally", 7),
    ..
  ] = function_nodes(text, "bound")
  // A named subject is no process: where a Subject is passed on, a gap.
  let assert [
    frame.Var(0, "tally"),
    frame.Var(1, "n"),
    frame.GapNode(2, "a named subject as a value", note),
    ..
  ] = function_nodes(text, "passed")
  assert string.contains(note, "contract T9.14c")
}

/// What makes a supervisor unreadable is said in the gap that takes the
/// start's place; and a name is read only where it is made as
/// `let name: Name(Message) = process.new_name("literal")`, once for a
/// message type in a unit.
pub fn unreadable_supervisor_test() {
  let gap_of = fn(text: String, name: String) {
    let assert [#(construct, note), ..] =
      list.filter_map(function_nodes(text, name), fn(node) {
        case node {
          frame.GapNode(construct:, note:, ..) -> Ok(#(construct, note))
          _ -> Error(Nil)
        }
      })
    assert construct == "gleam/otp/static_supervisor.start/1"
    note
  }
  // The restart is written as it is: Temporary.
  let temporary =
    string.replace(
      supervisor_text,
      "supervision.worker(fn() { start_tally(name) })",
      "supervision.worker(fn() { start_tally(name) }) |> supervision.restart(supervision.Temporary)",
    )
  let assert Ok(frame.Function(overrides: [frame.Override(params:, ..)], ..)) =
    list.find(forms(unit_of(temporary)), fn(form) {
      case form {
        frame.Function(name: "start", ..) -> True
        _ -> False
      }
    })
  assert params == [#("restart", "temporary"), #("strategy", "rest_for_one")]
  // A child that is a supervisor.
  let nested =
    string.replace(
      supervisor_text,
      "supervision.worker(fn() { start_tally(name) })",
      "supervision.supervisor(fn() { start_sup(name) })",
    )
  assert string.contains(
    gap_of(nested, "start"),
    "a child that is a supervisor is not read",
  )
  // A handler that is not a function of the module by its name.
  let closure =
    string.replace(
      supervisor_text,
      "actor.on_message(handle)",
      "actor.on_message(fn(s, m) { handle(s, m) })",
    )
  assert string.contains(
    gap_of(closure, "start"),
    "the handler given to actor.on_message is not a function of this module, by its name",
  )
  // Two names for one message type: neither is read, so the type Name of
  // that message is not known, and the functions that name it are gap forms.
  let twice =
    string.replace(
      supervisor_text,
      "  tally\n}",
      "  let other: Name(Message) = process.new_name(\"other\")\n  tally\n}",
    )
  let assert Ok(frame.Gap(note:, ..)) =
    list.find(forms(unit_of(twice)), fn(form) {
      case form {
        frame.Gap(name: "start", ..) -> True
        _ -> False
      }
    })
  assert string.contains(
    note,
    "this unit does not make exactly one name for this message type",
  )
}

/// A function literal that captures nothing is sent as a function of the
/// module and a `fun_ref` (lift.gleam; contract H36): where it is written as
/// an argument of a function of the module whose declaration gives that
/// parameter a function type. A capture whose other arguments are literals
/// is the fn it stands for. A closure stays a `lambda`.
pub fn lift_test() {
  let text =
    "fn twice(f: fn(Int) -> Int, n: Int) -> Int { f(f(n)) }
fn add(a: Int, b: Int) -> Int { a + b }
pub fn plain(n: Int) -> Int { twice(fn(x) { x * 2 }, n) }
pub fn capture(n: Int) -> Int { twice(add(2, _), n) }
pub fn piped(n: Int) -> Int { n |> twice(fn(x) { add(x, 1) }, _) }
pub fn closure(n: Int) -> Int { twice(fn(x) { x * n }, n) }
pub fn bound(n: Int) -> Int {
  let double = fn(x: Int) -> Int { x * 2 }
  twice(double, n)
}
"
  let names = function_names(text)
  assert names
    == [
      "twice", "add", "plain", "plain__f1", "capture", "capture__f1", "piped",
      "piped__f1", "closure", "bound",
    ]
  assert function_nodes(text, "plain")
    == [
      frame.Var(0, "n"),
      frame.FunRef(1, "", "plain__f1", 1),
      frame.Var(2, "n"),
      frame.Call(3, "", "twice", [1, 2]),
      frame.Clause(4, [0], -1, 3),
    ]
  assert function_nodes(text, "plain__f1")
    == [
      frame.Var(0, "x"),
      frame.Var(1, "x"),
      frame.Int(2, 2),
      frame.Op(3, "*", [1, 2]),
      frame.Clause(4, [0], -1, 3),
    ]
  // The made function is not exported; its signature is the function type
  // twice declares for the parameter.
  let assert Ok(frame.Function(exported: False, types:, hints:, ..)) =
    list.find(forms(unit_of(text)), fn(form) {
      case form {
        frame.Function(name: "plain__f1", ..) -> True
        _ -> False
      }
    })
  assert hint_type(types, hints, -1) == #("fn(int) -> int", frame.Inferred)
  assert function_nodes(text, "capture__f1")
    == [
      frame.Var(0, "_capture"),
      frame.Int(1, 2),
      frame.Var(2, "_capture"),
      frame.Call(3, "", "add", [1, 2]),
      frame.Clause(4, [0], -1, 3),
    ]
  let kinds = fn(name) {
    list.map(function_nodes(text, name), fn(node) {
      let assert [kind, ..] = string.split(string.inspect(node), "(")
      kind
    })
  }
  assert !list.contains(kinds("piped"), "Lambda")
  assert list.contains(kinds("piped"), "FunRef")
  assert list.contains(kinds("closure"), "Lambda")
  assert list.contains(kinds("bound"), "Lambda")
}
