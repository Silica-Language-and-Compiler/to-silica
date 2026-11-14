//// gaps: what examples/demo.gleam and examples/actors.gleam used to leave
//// out on purpose, kept here for the tests. Every function of this module
//// is sent as a gap, holds one, or is answered by the transpiler with a gap
//// of its own (contract T9.10: a session with gaps still completes):
////   - a construct outside the subset: tuple indexing (second/1), a call
////     into a module the session does not have (count/1), a binding to
////     foreign code (receive_message/0, and ping_pong/1 and pong_loop/0,
////     which call it), inter-node communication (is_distributed/0);
////   - what the sender sends and the transpiler answers with its own gap: a
////     closure (add_n/2), a linked spawn and a link (start_linked/0);
////   - a supervisor the sender cannot read: its child has no name
////     (start_unnamed/0), its child's state is not a literal
////     (start_computed/2), its value is used (start_kept/1); and a name
////     that is not made where the sender reads names (late_name/1).
//// It is valid Gleam (`gleam test` compiles it); it is not meant to be run.

import gleam/erlang/process.{type Name}
import gleam/list
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision

pub fn add(a: Int, b: Int) -> Int {
  a + b
}

pub fn twice(f: fn(Int) -> Int, n: Int) -> Int {
  f(f(n))
}

// The fn uses n, a variable of add_n: a closure. The sender states its type
// and sends it as a (:lambda); the transpiler writes no closure.
pub fn add_n(n: Int, start: Int) -> Int {
  twice(fn(x) { add(x, n) }, start)
}

// Tuple indexing: a gap node.
pub fn second(pair: #(Int, Int)) -> Int {
  pair.1
}

// The codex knows the type of list.length, so `n` has a type. The call goes
// into a module that is not in the session, which the transpiler does not
// write (contract T9.9).
pub fn count(items: List(Int)) -> Int {
  let n = list.length(items)
  n + 1
}

// Inter-node communication is cut from the proof of concept: a gap form.
@external(erlang, "erlang", "is_alive")
pub fn is_distributed() -> Bool

// --- processes through externals to Erlang's own functions

pub type Pid

@external(erlang, "erlang", "self")
fn self() -> Pid

@external(erlang, "erlang", "spawn")
fn spawn(f: fn() -> a) -> Pid

@external(erlang, "erlang", "spawn_link")
fn spawn_link(f: fn() -> a) -> Pid

@external(erlang, "erlang", "send")
fn send(to: Pid, message: m) -> m

@external(erlang, "erlang", "link")
fn link(to: Pid) -> Bool

pub type Message {
  Ping(from: Pid, n: Int)
  Pong(n: Int)
  Stop
}

// A receive written through an external to a helper that is not one of
// Erlang's process functions: the declaration is a gap form, and the
// functions below reach the gap when they call it.
@external(erlang, "demo_ffi", "receive_message")
fn receive_message() -> Message

pub fn ping_pong(n: Int) -> Int {
  let pong = spawn(fn() { pong_loop() })
  send(pong, Ping(self(), n))
  case receive_message() {
    Pong(m) -> {
      send(pong, Stop)
      m
    }
    _ -> 0
  }
}

pub fn pong_loop() -> Nil {
  case receive_message() {
    Ping(from, n) -> {
      send(from, Pong(add(n, 1)))
      pong_loop()
    }
    Pong(_) -> pong_loop()
    Stop -> Nil
  }
}

// A linked spawn and a link have nodes (H21, H24); the transpiler writes no
// link (contract T9.15).
pub fn start_linked() -> Pid {
  let child = spawn_link(pong_loop)
  link(child)
  child
}

// --- supervisors the sender cannot read (README, "A static supervisor")

pub type Tick {
  Tick
}

fn handle_tick(count: Int, _message: Tick) -> actor.Next(Int, Tick) {
  actor.continue(count + 1)
}

// The child's actor has no name: a static child is registered under one.
pub fn start_unnamed() -> Nil {
  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(
      supervision.worker(fn() {
        actor.new(0) |> actor.on_message(handle_tick) |> actor.start
      }),
    )
    |> supervisor.start
  Nil
}

// The child's state is computed: the arguments of a static child are
// literals.
pub fn start_computed(name: Name(Tick), first: Int) -> Nil {
  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(
      supervision.worker(fn() {
        actor.new(first + 1)
        |> actor.named(name)
        |> actor.on_message(handle_tick)
        |> actor.start
      }),
    )
    |> supervisor.start
  Nil
}

// The supervisor's value is used: the supervisor is no process of the
// output, so it has no value.
pub fn start_kept(name: Name(Tick)) -> Bool {
  let started =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(
      supervision.worker(fn() {
        actor.new(0)
        |> actor.named(name)
        |> actor.on_message(handle_tick)
        |> actor.start
      }),
    )
    |> supervisor.start
  case started {
    Ok(_) -> True
    Error(_) -> False
  }
}

// The one name this unit makes for Tick, where the sender reads names.
pub fn tick_name() -> Name(Tick) {
  let name: Name(Tick) = process.new_name("ticker")
  name
}

pub type Tock {
  Tock
}

// A name is read only where it is made as
// `let name: Name(Message) = process.new_name("literal")`: here the prefix
// is not a literal, so the unit has no name for Tock, and the function,
// whose result names the type Name(Tock), has no signature.
pub fn late_name(prefix: String) -> Name(Tock) {
  process.new_name(prefix)
}
