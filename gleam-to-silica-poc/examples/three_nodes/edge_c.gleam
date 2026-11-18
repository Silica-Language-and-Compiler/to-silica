//// edge_c: an edge node of the three-node example (hub topology). It dials hub@localhost, asks the hub's registered
//// name hub_in to double 34, and prints the answer, which the hub casts back to this node's registered name c_inbox.
////
//@silica_node name c@localhost
//@silica_node cookie_file cookie
//@silica_node peer hub@localhost 127.0.0.1 dial
//@silica_node redial 250 4000
//@silica_node remote hub_in hub@localhost request String Int send_hub_in
//@silica_node local c_inbox reply Int

import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/io
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision

/// What this node's inbox receives from the hub.
pub type Reply {
  Reply(Int)
}

/// What the hub's service takes: the registered name to answer to, and a number.
pub type HubMessage {
  Request(String, Int)
}

/// The BEAM's own send, to a registered name on another node: `{Name, Node} ! Message`.
@external(erlang, "erlang", "send")
fn send_to_name(to: #(Atom, Atom), message: message) -> message

/// The send to the registered name hub_in on hub@localhost. to-silica reads a call of it as (:send_named) and does
/// not send this function (the `remote` line above names it); on the BEAM it is this send.
fn send_hub_in(message: HubMessage) -> Nil {
  send_to_name(#(atom.create("hub_in"), atom.create("hub@localhost")), message)
  Nil
}

fn handle(sum: Int, message: Reply) -> actor.Next(Int, Reply) {
  case message {
    Reply(value) -> {
      io.println("c: the hub answered " <> int.to_string(value))
      actor.continue(sum + value)
    }
  }
}

fn start_inbox(name: Name(Reply)) -> actor.StartResult(Subject(Reply)) {
  actor.new(0)
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

fn start_supervisor(
  name: Name(Reply),
) -> actor.StartResult(supervisor.Supervisor) {
  supervisor.new(supervisor.OneForOne)
  |> supervisor.add(
    supervision.worker(fn() { start_inbox(name) })
    |> supervision.restart(supervision.Transient),
  )
  |> supervisor.start
}

/// Start the inbox, ask the hub, and wait for the answer to arrive.
/// run/0, not main/0: BEES owns the node program's main, which starts the node and then starts run/0.
pub fn run() -> Nil {
  let inbox: Name(Reply) = process.new_name("c_inbox")
  let assert Ok(_) = start_supervisor(inbox)
  send_hub_in(Request("c_inbox", 34))
  let wait: Subject(Int) = process.new_subject()
  let _ = process.receive(wait, 8000)
  Nil
}
