//// hub: the middle node of the three-node example (hub topology). It listens for the two edge nodes, a@localhost and
//// c@localhost, serves requests on the registered name hub_in and answers each one by name on the edge that asked.
////
////   a@localhost --dial--> hub@localhost <--dial-- c@localhost
////
//// A request is Request(reply_to, n): reply_to is the registered name the answer goes to (a pid does not cross a
//// node; BEES sends to registered names, so the request says which name). The answer is Reply(2 * n).
////
//// The //@silica_node lines declare the node (contract T9.17); to-silica turns them into BEES's manifest and
//// bees.config (BEAM mode: EPMD, started with `epmd -daemon` if it is not running, and a cookie). The last word of a
//// `remote` line is the function that sends to that name. Its body is not used by to-silica; it is what lets the
//// module compile as Gleam.
////
//@silica_node name hub@localhost
//@silica_node cookie_file cookie
//@silica_node peer a@localhost 127.0.0.1 listen
//@silica_node peer c@localhost 127.0.0.1 listen
//@silica_node local hub_in request String Int
//@silica_node remote a_inbox a@localhost reply Int send_a_inbox
//@silica_node remote c_inbox c@localhost reply Int send_c_inbox

import gleam/erlang/process.{type Name, type Subject}
import gleam/io
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision

/// What a peer asks: the registered name to answer to, and a number.
pub type HubMessage {
  Request(reply_to: String, n: Int)
}

/// What the hub answers (and what an edge's inbox receives).
pub type Reply {
  Reply(value: Int)
}

fn send_a_inbox(message: Reply) -> Nil {
  let _ = message
  Nil
}

fn send_c_inbox(message: Reply) -> Nil {
  let _ = message
  Nil
}

/// The answer goes to the name on the node that asked.
fn answer(reply_to: String, value: Int) -> Nil {
  case reply_to {
    "a_inbox" -> send_a_inbox(Reply(value))
    "c_inbox" -> send_c_inbox(Reply(value))
    _ -> Nil
  }
}

fn handle(
  served: Int,
  message: HubMessage,
) -> actor.Next(Int, HubMessage) {
  case message {
    Request(reply_to, n) -> {
      io.println("hub: request from " <> reply_to)
      answer(reply_to, n * 2)
      actor.continue(served + 1)
    }
  }
}

fn start_hub(
  name: Name(HubMessage),
) -> actor.StartResult(Subject(HubMessage)) {
  actor.new(0)
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

fn start_supervisor(
  name: Name(HubMessage),
) -> actor.StartResult(supervisor.Supervisor) {
  supervisor.new(supervisor.OneForOne)
  |> supervisor.add(
    supervision.worker(fn() { start_hub(name) })
    |> supervision.restart(supervision.Transient),
  )
  |> supervisor.start
}

/// Start the service and stay up while the edges talk to it.
pub fn main() -> Nil {
  let hub_in: Name(HubMessage) = process.new_name("hub_in")
  let assert Ok(_) = start_supervisor(hub_in)
  let wait: Subject(Int) = process.new_subject()
  let _ = process.receive(wait, 20_000)
  Nil
}
