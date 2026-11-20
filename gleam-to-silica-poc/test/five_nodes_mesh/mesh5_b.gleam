//// mesh5_b: one node of the five-node mesh example (every node holds a link to all four others: ten links).
////
//// The nodes are na, nb, nc, nd and ne, all @localhost. A node dials every node whose letter comes before its own and
//// listens for the rest, so each pair has one link. A link carries messages both ways, so which end dialed does not
//// matter to the programs. This node: dials na; listens for nc, nd, ne.
////
//// Every node does the same two things. It serves requests on its registered name b_in: a request names the
//// registered name to answer to and a number, and is answered with this node's b_in and twice the number. And it
//// asks all four other nodes to double a number (node 1..5 asks node 1..5 for the number 10 * asker + asked), and
//// prints each answer when it arrives at its registered name b_inbox. So twenty requests and twenty answers cross
//// the ten links, each link in both directions.
////
//// Distribution is BEES's BEAM mode: EPMD and a cookie (contract T9.17), as in examples/three_nodes.
////
//// The //@silica_node lines declare the node. The last word of a `remote` line is the function that sends to that
//// name. The entry is run/0, not main/0: BEES owns main.
////

//@silica_node name nb@localhost
//@silica_node cookie_file cookie
//@silica_node peer na@localhost localhost dial
//@silica_node peer nc@localhost localhost listen
//@silica_node peer nd@localhost localhost listen
//@silica_node peer ne@localhost localhost listen
//@silica_node redial 250 4000
//@silica_node local b_in request String Int
//@silica_node local b_inbox reply String Int
//@silica_node remote a_in na@localhost request String Int send_a_in
//@silica_node remote c_in nc@localhost request String Int send_c_in
//@silica_node remote d_in nd@localhost request String Int send_d_in
//@silica_node remote e_in ne@localhost request String Int send_e_in
//@silica_node remote a_inbox na@localhost reply String Int send_a_inbox
//@silica_node remote c_inbox nc@localhost reply String Int send_c_inbox
//@silica_node remote d_inbox nd@localhost reply String Int send_d_inbox
//@silica_node remote e_inbox ne@localhost reply String Int send_e_inbox

import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/io
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision

/// What a peer asks: the registered name to answer to, and a number.
pub type Ask {
  Request(String, Int)
}

/// What a service answers: its own registered name, and the doubled number.
pub type Answer {
  Reply(String, Int)
}

/// The BEAM's own send, to a registered name on another node: `{Name, Node} ! Message`.
@external(erlang, "erlang", "send")
fn send_to_name(to: #(Atom, Atom), message: message) -> message

// The eight sends to the other nodes' registered names. to-silica reads a call of each as (:send_named) and does
// not send these functions (the `remote` lines above name them); on the BEAM they are this send.

fn send_a_in(message: Ask) -> Nil {
  send_to_name(#(atom.create("a_in"), atom.create("na@localhost")), message)
  Nil
}

fn send_c_in(message: Ask) -> Nil {
  send_to_name(#(atom.create("c_in"), atom.create("nc@localhost")), message)
  Nil
}

fn send_d_in(message: Ask) -> Nil {
  send_to_name(#(atom.create("d_in"), atom.create("nd@localhost")), message)
  Nil
}

fn send_e_in(message: Ask) -> Nil {
  send_to_name(#(atom.create("e_in"), atom.create("ne@localhost")), message)
  Nil
}

fn send_a_inbox(message: Answer) -> Nil {
  send_to_name(#(atom.create("a_inbox"), atom.create("na@localhost")), message)
  Nil
}

fn send_c_inbox(message: Answer) -> Nil {
  send_to_name(#(atom.create("c_inbox"), atom.create("nc@localhost")), message)
  Nil
}

fn send_d_inbox(message: Answer) -> Nil {
  send_to_name(#(atom.create("d_inbox"), atom.create("nd@localhost")), message)
  Nil
}

fn send_e_inbox(message: Answer) -> Nil {
  send_to_name(#(atom.create("e_inbox"), atom.create("ne@localhost")), message)
  Nil
}

/// The answer goes to the name on the node that asked, and says who answered.
fn answer(reply_to: String, value: Int) -> Nil {
  case reply_to {
    "a_inbox" -> send_a_inbox(Reply("b_in", value))
    "c_inbox" -> send_c_inbox(Reply("b_in", value))
    "d_inbox" -> send_d_inbox(Reply("b_in", value))
    "e_inbox" -> send_e_inbox(Reply("b_in", value))
    _ -> Nil
  }
}

fn handle_ask(served: Int, message: Ask) -> actor.Next(Int, Ask) {
  case message {
    Request(reply_to, n) -> {
      io.println("b: request " <> int.to_string(n) <> " from " <> reply_to)
      answer(reply_to, n * 2)
      actor.continue(served + 1)
    }
  }
}

fn handle_answer(sum: Int, message: Answer) -> actor.Next(Int, Answer) {
  case message {
    Reply(from, value) -> {
      io.println("b: " <> from <> " answered " <> int.to_string(value))
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

/// Start the two actors, ask the four other nodes, and stay up while the answers arrive and the other nodes ask
/// this one.
pub fn run() -> Nil {
  let service: Name(Ask) = process.new_name("b_in")
  let inbox: Name(Answer) = process.new_name("b_inbox")
  let assert Ok(_) = start_supervisor(service, inbox)
  send_a_in(Request("b_inbox", 21))
  send_c_in(Request("b_inbox", 23))
  send_d_in(Request("b_inbox", 24))
  send_e_in(Request("b_inbox", 25))
  let wait: Subject(Int) = process.new_subject()
  let _ = process.receive(wait, 15_000)
  Nil
}
