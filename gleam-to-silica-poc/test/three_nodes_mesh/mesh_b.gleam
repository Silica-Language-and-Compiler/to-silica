//// mesh_b: one node of the three-node mesh example (every node holds a link to both others).
////
////   ma@localhost <--dial-- mb@localhost
////        ^                      ^
////        +--dial-- mc@localhost +
////
//// mb dials ma, mc dials ma and mb: three links, one for each pair. A link carries messages both ways, so which end
//// dialed does not matter to the programs. This node: dials ma, listens for mc.
////
//// Every node does the same two things. It serves requests on its registered name b_in: Request(reply_to, n) is
//// answered with Reply(BIn, 2 * n), sent to the registered name reply_to on the node that asked. And it asks
//// both other nodes to double a number, and prints each answer when it arrives at its registered name b_inbox.
//// So six requests and six answers cross the three links, each link in both directions.
////
//// The //@silica_node lines declare the node (contract T9.17), as in examples/three_nodes. The last word of a
//// `remote` line is the function that sends to that name. The entry is run/0, not main/0: BEES owns main.
////

//@silica_node name mb@localhost
//@silica_node cookie_file cookie
//@silica_node peer ma@localhost localhost dial
//@silica_node peer mc@localhost localhost listen
//@silica_node redial 250 4000
//@silica_node local b_in request Atom Int
//@silica_node local b_inbox reply Atom Int
//@silica_node remote a_in ma@localhost request Atom Int send_a_in
//@silica_node remote c_in mc@localhost request Atom Int send_c_in
//@silica_node remote a_inbox ma@localhost reply Atom Int send_a_inbox
//@silica_node remote c_inbox mc@localhost reply Atom Int send_c_inbox

import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/io
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision

/// The registered names of the mesh. A constructor without fields is an atom on the BEAM (`AInbox` is `a_inbox`),
/// so a name crosses a node as the atom the Erlang and Elixir programs of the same example send.
pub type Who {
  AIn
  AInbox
  BIn
  BInbox
  CIn
  CInbox
}

fn who_text(who: Who) -> String {
  case who {
    AIn -> "a_in"
    AInbox -> "a_inbox"
    BIn -> "b_in"
    BInbox -> "b_inbox"
    CIn -> "c_in"
    CInbox -> "c_inbox"
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

/// The four sends to the other nodes' registered names. to-silica reads a call of each as (:send_named) and does
/// not send these functions (the `remote` lines above name them); on the BEAM they are this send.
fn send_a_in(message: Ask) -> Nil {
  send_to_name(#(atom.create("a_in"), atom.create("ma@localhost")), message)
  Nil
}

fn send_c_in(message: Ask) -> Nil {
  send_to_name(#(atom.create("c_in"), atom.create("mc@localhost")), message)
  Nil
}

fn send_a_inbox(message: Answer) -> Nil {
  send_to_name(#(atom.create("a_inbox"), atom.create("ma@localhost")), message)
  Nil
}

fn send_c_inbox(message: Answer) -> Nil {
  send_to_name(#(atom.create("c_inbox"), atom.create("mc@localhost")), message)
  Nil
}

/// The answer goes to the name on the node that asked, and says who answered.
fn answer(reply_to: Who, value: Int) -> Nil {
  case reply_to {
    AInbox -> send_a_inbox(Reply(BIn, value))
    CInbox -> send_c_inbox(Reply(BIn, value))
    _ -> Nil
  }
}

fn handle_ask(served: Int, message: Ask) -> actor.Next(Int, Ask) {
  case message {
    Request(reply_to, n) -> {
      io.println(
        "b: request " <> int.to_string(n) <> " from " <> who_text(reply_to),
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
        "b: " <> who_text(from) <> " answered " <> int.to_string(value),
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

/// Start the two actors, ask both other nodes, and stay up while the answers arrive and the other nodes ask this
/// one.
pub fn run() -> Nil {
  let service: Name(Ask) = process.new_name("b_in")
  let inbox: Name(Answer) = process.new_name("b_inbox")
  let assert Ok(_) = start_supervisor(service, inbox)
  send_a_in(Request(BInbox, 21))
  send_c_in(Request(BInbox, 22))
  let wait: Subject(Int) = process.new_subject()
  let _ = process.receive(wait, 15_000)
  Nil
}
