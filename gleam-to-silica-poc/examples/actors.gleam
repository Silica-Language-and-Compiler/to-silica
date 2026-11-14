//// actors: a small working application of three actors.
////
////   coordinator (main)   starts the others, makes a few additions, prints what it learns
////   counter              a gleam_otp actor: holds a Tally, answers Add and Get
////   auditor              a gleam_otp actor with a name, under a gleam_otp static
////                        supervisor: counts the additions it is told about
////
//// Run it:   gleam run -m actors      (test/actors.gleam is a copy of this file)
//// It prints:
////   counter: total 9, adds 3, small
////   mean 3.0
////   auditor: 3 notes
////
//// Three annotations are there for the sender: `let auditor: Name(...)` and
//// the two `let reply: Subject(...)`. Gleam takes the message type of
//// `process.new_name` and of `process.new_subject` from later use, which
//// only the Gleam compiler's inference follows (README, "Types").

import gleam/erlang/process.{type Name, type Subject}
import gleam/float
import gleam/int
import gleam/io
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision

// ---------------------------------------------------------------- data

/// The counter's state: a record.
pub type Tally {
  Tally(label: String, total: Int, adds: Int)
}

pub type Size {
  Negative
  Small
  Large
}

/// What the counter answers to `Get`.
pub type Report {
  Report(total: Int, adds: Int, size: Size)
}

/// The counter's messages.
pub type CounterMessage {
  Add(Int)
  Get(Subject(Report))
}

/// The auditor's messages. Its state is the number of notes it has taken.
pub type AuditorMessage {
  Note(Int)
  Notes(Subject(Int))
}

// ---------------------------------------------------------------- pure functions

pub fn new_tally() -> Tally {
  Tally(label: "counter", total: 0, adds: 0)
}

pub fn bump(tally: Tally, amount: Int) -> Tally {
  Tally(..tally, total: tally.total + amount, adds: tally.adds + 1)
}

pub fn describe(n: Int) -> Size {
  case n < 0, n < 10 {
    True, _ -> Negative
    False, True -> Small
    False, False -> Large
  }
}

pub fn size_name(size: Size) -> String {
  case size {
    Negative -> "negative"
    Small -> "small"
    Large -> "large"
  }
}

pub fn mean(total: Int, adds: Int) -> Float {
  case adds {
    0 -> 0.0
    _ -> int.to_float(total) /. int.to_float(adds)
  }
}

// ---------------------------------------------------------------- the counter: a gleam_otp actor

fn handle_counter(
  tally: Tally,
  message: CounterMessage,
) -> actor.Next(Tally, CounterMessage) {
  case message {
    Add(amount) -> actor.continue(bump(tally, amount))
    Get(reply_to) -> {
      process.send(
        reply_to,
        Report(
          total: tally.total,
          adds: tally.adds,
          size: describe(tally.total),
        ),
      )
      actor.continue(tally)
    }
  }
}

fn start_counter() -> actor.StartResult(Subject(CounterMessage)) {
  actor.new(new_tally())
  |> actor.on_message(handle_counter)
  |> actor.start
}

// ---------------------------------------------------------------- the auditor: a named actor

fn handle_auditor(
  count: Int,
  message: AuditorMessage,
) -> actor.Next(Int, AuditorMessage) {
  case message {
    Note(_amount) -> actor.continue(count + 1)
    Notes(reply_to) -> {
      process.send(reply_to, count)
      actor.continue(count)
    }
  }
}

fn start_auditor(
  name: Name(AuditorMessage),
) -> actor.StartResult(Subject(AuditorMessage)) {
  actor.new(0)
  |> actor.named(name)
  |> actor.on_message(handle_auditor)
  |> actor.start
}

// ---------------------------------------------------------------- the supervisor
//
// A supervisor with a static child list: one child, the auditor, started
// again if it ends abnormally. The sender reads this function and
// start_auditor and sends the child as a static child of the unit's
// supervisor (README, "A static supervisor").

fn start_supervisor(
  name: Name(AuditorMessage),
) -> actor.StartResult(supervisor.Supervisor) {
  supervisor.new(supervisor.OneForOne)
  |> supervisor.add(
    supervision.worker(fn() { start_auditor(name) })
    |> supervision.restart(supervision.Transient),
  )
  |> supervisor.start
}

// ---------------------------------------------------------------- the coordinator

/// The auditor is talked to by its registered name.
fn add(
  counter: Subject(CounterMessage),
  auditor: Name(AuditorMessage),
  amount: Int,
) -> Nil {
  process.send(counter, Add(amount))
  process.send(process.named_subject(auditor), Note(amount))
}

fn ask(counter: Subject(CounterMessage)) -> Result(Report, Nil) {
  let reply: Subject(Report) = process.new_subject()
  process.send(counter, Get(reply))
  process.receive(reply, 1000)
}

fn notes(auditor: Name(AuditorMessage)) -> Result(Int, Nil) {
  let reply: Subject(Int) = process.new_subject()
  process.send(process.named_subject(auditor), Notes(reply))
  process.receive(reply, 1000)
}

pub fn main() -> Nil {
  let auditor: Name(AuditorMessage) = process.new_name("auditor")
  let assert Ok(_) = start_supervisor(auditor)
  let assert Ok(actor.Started(data: counter, ..)) = start_counter()
  add(counter, auditor, 5)
  add(counter, auditor, 7)
  add(counter, auditor, -3)
  case ask(counter) {
    Ok(report) -> {
      io.println(
        "counter: total "
        <> int.to_string(report.total)
        <> ", adds "
        <> int.to_string(report.adds)
        <> ", "
        <> size_name(report.size),
      )
      io.println("mean " <> float.to_string(mean(report.total, report.adds)))
    }
    Error(Nil) -> io.println("the counter did not answer")
  }
  case notes(auditor) {
    Ok(count) -> io.println("auditor: " <> int.to_string(count) <> " notes")
    Error(Nil) -> io.println("the auditor did not answer")
  }
}
