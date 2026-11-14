//// demo: the example program of gleam-to-silica-poc. One small function for
//// each construct of the subset. It is transpiled with no gap; what the
//// sender answers with a gap is in test/fixtures/gaps.gleam.
////
//// Every type the sender states is written here, in Gleam's own way: the
//// annotations of each function, the custom types, and the annotation of a
//// `let` whose type Gleam would otherwise take from later use.
////
//// It is valid Gleam: test/demo.gleam is a copy of this file, so
//// `gleam test` type-checks it.

import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int

// --- basic types, operators, calls

pub fn add(a: Int, b: Int) -> Int {
  a + b
}

pub fn scale(f: Float, n: Float) -> Float {
  f *. n *. 1.5
}

// Gleam's `/`, `%` and `/.` give 0 for a zero divisor; the sender sends that
// as a guard around each division.
pub fn split(total: Int, parts: Int) -> Int {
  total / parts + total % parts
}

// Numeric conversions are explicit calls in Gleam; the sender sends them as
// the contract's conversion operators.
pub fn average(total: Int, count: Int) -> Int {
  float.round(int.to_float(total) /. int.to_float(count))
}

pub fn whole(f: Float) -> Int {
  float.truncate(f /. 2.0)
}

pub fn greet(name: String) -> String {
  "hello, " <> name
}

pub fn flip(flag: Bool) -> Bool {
  !flag
}

fn negate(n: Int) -> Int {
  -n
}

// --- tuples

pub fn swap(pair: #(Int, Bool)) -> #(Bool, Int) {
  let #(a, b) = pair
  #(b, a)
}

// --- a custom type with one variant and labelled fields: the record idiom

pub type Point {
  Point(x: Int, y: Int)
}

pub fn origin() -> Point {
  Point(x: 0, y: 0)
}

pub fn move(p: Point, dx: Int, dy: Int) -> Point {
  let moved = Point(..p, x: p.x + dx)
  Point(x: moved.x, y: moved.y + dy)
}

pub fn x_of(p: Point) -> Int {
  let Point(x: x, ..) = p
  x
}

// --- custom types with several variants: symbols and tagged tuples

pub type Sign {
  Negative
  Zero
  Positive
}

pub type Shape {
  Square(Float)
  Rectangle(Float, Float)
  Circle(Float)
}

// --- case, patterns, guards

pub fn classify(n: Int) -> Sign {
  case n {
    0 -> Zero
    _ if n < 0 -> Negative
    _ -> Positive
  }
}

pub fn area(shape: Shape) -> Float {
  case shape {
    Square(side) -> side *. side
    Rectangle(w, h) if w >. 0.0 && h >. 0.0 -> w *. h
    Rectangle(_, _) -> 0.0
    Circle(r) -> 3.14159 *. r *. r
  }
}

pub fn describe(n: Int) -> String {
  case classify(n) {
    Zero -> "zero"
    Negative | Positive -> "not zero"
  }
}

pub fn max_of(a: Int, b: Int) -> Int {
  case a >= b {
    True -> a
    False -> b
  }
}

pub fn order(a: Int, b: Int) -> Sign {
  case a, b {
    x, y if x < y -> Negative
    x, y if x == y -> Zero
    _, _ -> Positive
  }
}

pub fn positive(n: Int) -> Int {
  case n > 0 {
    True -> n
    False -> panic as "not positive"
  }
}

// --- functions as values, anonymous functions, captures, pipes

pub fn twice(f: fn(Int) -> Int, n: Int) -> Int {
  f(f(n))
}

pub fn adder() -> fn(Int, Int) -> Int {
  add
}

// The capture and the fn below are written where twice declares a function
// type, and they use no variable of the function around them: the sender
// sends each as a function of the module (README, "A fn that captures
// nothing").
pub fn add_four(n: Int) -> Int {
  twice(add(2, _), n)
}

pub fn pipeline(n: Int) -> Int {
  n |> add(1) |> twice(fn(x) { x * 2 }, _) |> negate
}

// --- constants, type aliases and lists

// A constant with a literal value is sent as a function of no parameters.
pub const limit = 10

pub fn under_limit(n: Int) -> Bool {
  n < limit
}

// A type alias is another name for its type: no form is sent for it.
pub type Pair =
  #(Int, Int)

pub fn sum_pair(pair: Pair) -> Int {
  let #(a, b) = pair
  a + b
}

pub fn sum_list(items: List(Int)) -> Int {
  case items {
    [] -> 0
    [first, ..rest] -> first + sum_list(rest)
  }
}

pub fn one_two_three() -> List(Int) {
  [1, 2, 3]
}

// --- processes: spawn, send, receive (gleam/erlang/process)
//
// A process is reached through a subject. The annotation on `answers` is
// there for the sender: Gleam takes the message type of
// `process.new_subject()` from later use.

fn pong(reply: Subject(Int), n: Int) -> Nil {
  process.send(reply, add(n, 1))
}

pub fn ping_pong(n: Int) -> Int {
  let answers: Subject(Int) = process.new_subject()
  process.spawn_unlinked(fn() { pong(answers, n) })
  case process.receive(answers, 1000) {
    Ok(m) -> m
    Error(Nil) -> 0
  }
}
