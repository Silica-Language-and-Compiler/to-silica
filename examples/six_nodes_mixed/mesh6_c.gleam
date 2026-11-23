//// mesh6_c: one node of the six-node mixed mesh (every node holds a link to all five others: fifteen links).
////
//// The six nodes are written in four languages: xa and xd in Erlang, xb and xe in Elixir, xc in Gleam, and xf in
//// Silica by hand. All are @localhost. A node dials every node whose letter comes before its own and listens for the
//// rest, so each pair has one link. This node: dials xa, xb; listens for xd, xe, xf.
////
//// Every node does the same two things, whatever its language. It serves requests on its registered name c_in: a
//// request names the registered name to answer to (an atom) and a number, and is answered with this node's c_in
//// and twice the number. And it asks all five other nodes to double a number (node 1..6 asks node 1..6 for the number
//// 10 * asker + asked), and prints each answer when it arrives at its registered name c_inbox. So thirty requests
//// and thirty answers cross the fifteen links, each link in both directions.
////
//// Distribution is BEES's BEAM mode: EPMD and a cookie (contract T9.17).
////
//// The //@silica_node lines declare the node. The last word of a `remote` line is the function that sends to that
//// name. The entry is run/0, not main/0: BEES owns main.
////

//@silica_node name xc@localhost
//@silica_node cookie_file cookie
//@silica_node peer xa@localhost localhost dial
//@silica_node peer xb@localhost localhost dial
//@silica_node peer xd@localhost localhost listen
//@silica_node peer xe@localhost localhost listen
//@silica_node peer xf@localhost localhost listen
//@silica_node redial 250 4000
//@silica_node local c_in request Atom Int
//@silica_node local c_inbox reply Atom Int
//@silica_node remote a_in xa@localhost request Atom Int send_a_in
//@silica_node remote b_in xb@localhost request Atom Int send_b_in
//@silica_node remote d_in xd@localhost request Atom Int send_d_in
//@silica_node remote e_in xe@localhost request Atom Int send_e_in
//@silica_node remote f_in xf@localhost request Atom Int send_f_in
//@silica_node remote a_inbox xa@localhost reply Atom Int send_a_inbox
//@silica_node remote b_inbox xb@localhost reply Atom Int send_b_inbox
//@silica_node remote d_inbox xd@localhost reply Atom Int send_d_inbox
//@silica_node remote e_inbox xe@localhost reply Atom Int send_e_inbox
//@silica_node remote f_inbox xf@localhost reply Atom Int send_f_inbox

import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/io
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision

/// The registered names of the mesh. A constructor without fields is an atom on the BEAM (`AInbox` is `a_inbox`),
/// so a name crosses a node as the atom the Erlang and Elixir programs of the same mesh send.
pub type Who {
  AIn
  AInbox
  BIn
  BInbox
  CIn
  CInbox
  DIn
  DInbox
  EIn
  EInbox
  FIn
  FInbox
}

fn who_text(who: Who) -> String {
  case who {
    AIn -> "a_in"
    AInbox -> "a_inbox"
    BIn -> "b_in"
    BInbox -> "b_inbox"
    CIn -> "c_in"
    CInbox -> "c_inbox"
    DIn -> "d_in"
    DInbox -> "d_inbox"
    EIn -> "e_in"
    EInbox -> "e_inbox"
    FIn -> "f_in"
    FInbox -> "f_inbox"
  }
}

/// What a peer asks: the registered name to answer to, and a number.
pub type Ask {
  Request(Who, Int)
}

/// What a service answers: its own registered name, and the doubled number.
pub type Answer {
  Reply(Who, Int)
}

/// The BEAM's own send, to a registered name on another node: `{Name, Node} ! Message`.
@external(erlang, "erlang", "send")
fn send_to_name(to: #(Atom, Atom), message: message) -> message

// The ten sends to the other nodes' registered names. to-silica reads a call of each as (:send_named) and does
// not send these functions (the `remote` lines above name them); on the BEAM they are this send.

fn send_a_in(message: Ask) -> Nil {
  send_to_name(#(atom.create("a_in"), atom.create("xa@localhost")), message)
  Nil
}

fn send_b_in(message: Ask) -> Nil {
  send_to_name(#(atom.create("b_in"), atom.create("xb@localhost")), message)
  Nil
}

fn send_d_in(message: Ask) -> Nil {
  send_to_name(#(atom.create("d_in"), atom.create("xd@localhost")), message)
  Nil
}

fn send_e_in(message: Ask) -> Nil {
  send_to_name(#(atom.create("e_in"), atom.create("xe@localhost")), message)
  Nil
}

fn send_f_in(message: Ask) -> Nil {
  send_to_name(#(atom.create("f_in"), atom.create("xf@localhost")), message)
  Nil
}

fn send_a_inbox(message: Answer) -> Nil {
  send_to_name(#(atom.create("a_inbox"), atom.create("xa@localhost")), message)
  Nil
}

fn send_b_inbox(message: Answer) -> Nil {
  send_to_name(#(atom.create("b_inbox"), atom.create("xb@localhost")), message)
  Nil
}

fn send_d_inbox(message: Answer) -> Nil {
  send_to_name(#(atom.create("d_inbox"), atom.create("xd@localhost")), message)
  Nil
}

fn send_e_inbox(message: Answer) -> Nil {
  send_to_name(#(atom.create("e_inbox"), atom.create("xe@localhost")), message)
  Nil
}

fn send_f_inbox(message: Answer) -> Nil {
  send_to_name(#(atom.create("f_inbox"), atom.create("xf@localhost")), message)
  Nil
}

/// The answer goes to the name on the node that asked, and says who answered.
fn answer(reply_to: Who, value: Int) -> Nil {
  case reply_to {
    AInbox -> send_a_inbox(Reply(CIn, value))
    BInbox -> send_b_inbox(Reply(CIn, value))
    DInbox -> send_d_inbox(Reply(CIn, value))
    EInbox -> send_e_inbox(Reply(CIn, value))
    FInbox -> send_f_inbox(Reply(CIn, value))
    _ -> Nil
  }
}

fn handle_ask(served: Int, message: Ask) -> actor.Next(Int, Ask) {
  case message {
    Request(reply_to, n) -> {
      io.println(
        "c: request " <> int.to_string(n) <> " from " <> who_text(reply_to),
      )
      answer(reply_to, n * 2)
      actor.continue(served + 1)
    }
  }
}

fn handle_answer(sum: Int, message: Answer) -> actor.Next(Int, Answer) {
  case message {
    Reply(from, value) -> {
      io.println(
        "c: " <> who_text(from) <> " answered " <> int.to_string(value),
      )
      actor.continue(sum + value)
    }
  }
}

fn start_service(name: Name(Ask)) -> actor.StartResult(Subject(Ask)) {
  actor.new(0)
  |> actor.named(name)
  |> actor.on_message(handle_ask)
  |> actor.start
}

fn start_inbox(name: Name(Answer)) -> actor.StartResult(Subject(Answer)) {
  actor.new(0)
  |> actor.named(name)
  |> actor.on_message(handle_answer)
  |> actor.start
}

fn start_supervisor(
  service: Name(Ask),
  inbox: Name(Answer),
) -> actor.StartResult(supervisor.Supervisor) {
  supervisor.new(supervisor.OneForOne)
  |> supervisor.add(
    supervision.worker(fn() { start_service(service) })
    |> supervision.restart(supervision.Transient),
  )
  |> supervisor.add(
    supervision.worker(fn() { start_inbox(inbox) })
    |> supervision.restart(supervision.Transient),
  )
  |> supervisor.start
}

/// Start the two actors, ask the five other nodes, and stay up while the answers arrive and the other nodes ask
/// this one.
pub fn run() -> Nil {
  let service: Name(Ask) = process.new_name("c_in")
  let inbox: Name(Answer) = process.new_name("c_inbox")
  let assert Ok(_) = start_supervisor(service, inbox)
  send_a_in(Request(CInbox, 31))
  send_b_in(Request(CInbox, 32))
  send_d_in(Request(CInbox, 34))
  send_e_in(Request(CInbox, 35))
  send_f_in(Request(CInbox, 36))
  let wait: Subject(Int) = process.new_subject()
  let _ = process.receive(wait, 15_000)
  Nil
}
