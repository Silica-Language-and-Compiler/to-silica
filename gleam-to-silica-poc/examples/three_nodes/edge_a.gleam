//// edge_a: an edge node of the three-node example (hub topology). It dials hub@localhost, asks the hub's registered
//// name hub_in to double 21, and prints the answer, which the hub casts back to this node's registered name a_inbox.
////
//@silica_node name a@localhost
//@silica_node cookie_file cookie
//@silica_node peer hub@localhost 127.0.0.1 dial
//@silica_node redial 250 4000
//@silica_node remote hub_in hub@localhost request String Int send_hub_in
//@silica_node local a_inbox reply Int

import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/io
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision

/// What this node's inbox receives from the hub.
pub type Reply {
  Reply(value: Int)
}

/// What the hub's service takes: the registered name to answer to, and a number.
pub type HubMessage {
  Request(reply_to: String, n: Int)
}

fn send_hub_in(message: HubMessage) -> Nil {
  let _ = message
  Nil
}

fn handle(sum: Int, message: Reply) -> actor.Next(Int, Reply) {
  case message {
    Reply(value) -> {
      io.println("a: the hub answered " <> int.to_string(value))
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
pub fn main() -> Nil {
  let inbox: Name(Reply) = process.new_name("a_inbox")
  let assert Ok(_) = start_supervisor(inbox)
  send_hub_in(Request("a_inbox", 21))
  let wait: Subject(Int) = process.new_subject()
  let _ = process.receive(wait, 8000)
  Nil
}
