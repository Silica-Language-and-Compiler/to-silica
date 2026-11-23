# gleam-to-silica-poc

A proof of concept of the language-owned half of a to-silica transpiler, for Gleam, written in Gleam (Erlang
target). It is the Gleam counterpart of `../erlang-to-silica-poc`.

It takes Gleam source, parses it with the Gleam ecosystem's own parser (the `glance` package), maps the syntax
tree to the frames of the to-silica TCP transport contract, version 1 (`../contract/tcp-transport-v1.md`, shapes in
`../contract/tcp_transport_v1.silica`), and sends them over TCP to a transpiler. The parser is the gate: if any
file does not parse, nothing is sent.

Status (2026-11-14): **both examples are transpiled with no gap** (result `ok`, `counts.gaps` 0), their Silica
compiles, and what it computes and prints was compared with what Gleam does; see "The examples, run". The frames of
both examples pass the contract's offline shape checker (`../contract/bindings/erlang/check_frame.erl`) and a
check-mode session (contract 6.5); see "How to test". The sender follows contract 8.6 (decided 2026-11-13): **the
language side decides every type and every numeric conversion**; see "Types".

## Layout

| File | What it is |
| --- | --- |
| `src/gleam_to_silica_poc/codex.gleam` | the inbound codex: glance syntax tree to frames, and the typing pass that runs with it. Its sections follow the contract's order: forms, node tables and their types, statements, patterns, expressions, calls, processes, `gleam_otp`, operators |
| `src/gleam_to_silica_poc/sup.gleam` | `gleam_otp`'s static supervisor, read from the syntax before anything else: each child becomes the contract's static child ("A static supervisor" below; contract T9.14b) |
| `src/gleam_to_silica_poc/lift.gleam` | a function literal that captures nothing, made a function of the module ("A fn that captures nothing" below; contract H36) |
| `src/gleam_to_silica_poc/split.gleam` | Gleam's process semantics, lowered before anything is typed or sent: every `process.receive`, and every call of a function that receives, is put in tail position, and the code after it in functions of its own ("Processes: what this sender splits" below; contract T9.13a) |
| `src/gleam_to_silica_poc/types.gleam` | the types the codex works out (`Ty`), annotations read as types, the type table of a form, and the functions of other modules whose types the codex knows ("Types" below) |
| `src/gleam_to_silica_poc/names.gleam` | how every name in a frame is spelled (rules N1 to N5, "Names" below; N6, the functions the split made, is `codex.fname`) |
| `src/gleam_to_silica_poc/frame.gleam` | the frames, forms, nodes and type entries this codex sends, as Gleam types |
| `src/gleam_to_silica_poc/wire.gleam` | frames as the Erlang terms of the schema, and as bytes; the hello |
| `src/gleam_to_silica_poc/term.gleam` | atoms, `term_to_binary`, `binary_to_term` |
| `src/gleam_to_silica_poc/sender.gleam` | the TCP sender: hello, welcome, credit, replies, result; and `release` |
| `src/gleam_to_silica_poc.gleam` | the command line |
| `examples/demo.gleam` | the example program: one small function for each construct of the subset, and a process that is spawned, sent to and received from. No gap |
| `examples/actors.gleam` | a working application of three actors: a coordinator (`main`), a counter (a plain `gleam_otp` actor whose state is a record), and an auditor (a named `gleam_otp` actor under a `gleam_otp` static supervisor, restart `Transient`, written in the source). `gleam run -m actors` runs it (`test/actors.gleam` is its compiled copy) and prints `counter: total 9, adds 3, small`, `mean 3.0`, `auditor: 3 notes`; the transpiled program prints the same three lines. No gap |
| `examples/three_nodes/` | a node program for each of three nodes: `hub.gleam`, `edge_a.gleam`, `edge_c.gleam` ("A node program" below; contract T9.17). No gap |
| `examples/three_nodes_mesh/` | the complete mesh: `mesh_a.gleam`, `mesh_b.gleam`, `mesh_c.gleam`, each with a link to both others (`mb` dials `ma`; `mc` dials `ma` and `mb`; peer host `localhost`). Every node serves requests on `<x>_in` and asks both others to double a number. No gap; ran live 2026-11-20 (`../tools/node_kit/live_run_gleam_mesh_*.txt`) |
| `examples/five_nodes_mesh/` | the complete mesh of five nodes: `mesh5_a.gleam` to `mesh5_e.gleam`, nodes `na` to `ne`, ten links (a node dials every node whose letter comes before its own). Every node asks the four others to double a number: twenty requests and twenty answers. No gap; ran live 2026-11-20 (`../tools/node_kit/live_run_gleam_mesh5_*.txt`) |
| `test/` | the tests, `run_test.sh`, and `demo.gleam`, `actors.gleam`, `three_nodes/`, `three_nodes_mesh/` and `five_nodes_mesh/`, copies of the examples |
| `test/fixtures/gaps.gleam` | what the examples used to leave out on purpose, kept for the tests: every function of it is a gap, holds one, or is answered by the transpiler with a gap of its own (a closure, tuple indexing, a call into another module, foreign code, a linked spawn, inter-node communication, supervisors that cannot be read, a name that is not read) |

There is no hand-written Erlang. Everything is Gleam; Erlang is reached only through `@external` declarations of
OTP's own functions: `erlang:binary_to_atom/1`, `term_to_binary/1`, `binary_to_term/1`, `is_atom/1`,
`atom_to_binary/1`, `halt/1`, `gen_tcp:connect/4`, `send/2`, `recv/3`, `close/1`, and `io:format/2` for `--dump`.
Integers, binaries, booleans, lists, tuples and maps are built with `gleam/dynamic`. The tests add `gen_tcp:listen`,
`accept`, `inet:port`, `erlang:spawn`, `os:getenv`, `code:ensure_loaded` and the contract's `check_frame:check/1`.

Packages: `glance` (the parser), `glexer` (its lexer, used directly for `unescape_string`), `simplifile` (reading
files), `argv` (command line arguments), `gleam_stdlib`, and `gleeunit` for the tests. `gleam_erlang` and `gleam_otp`
are development dependencies only: the examples and the fixture use them, the codex and the sender do not.

## Scope

Only the subset below is translated. Everything else is sent as a gap (T9.10), so a session always completes:
`{gap_node, At, Construct, Note}` for an expression or pattern, `{gap, ...}` for a whole top-level form.

| Gleam | Contract |
| --- | --- |
| `1`, `1_000`, `0xff` | `int` (H1); beyond 64 bits is a gap |
| `1.5` | `float`, as decimal text (H2) |
| `"text"` | `text`, escapes resolved (H3) |
| `True`, `False` | `boolean` (H6) |
| `Nil`, a constructor without fields | `symbol` with the constructor's name in snake_case, as on the BEAM: `nil`, `stop` (H5, rule N5) |
| `#(a, b)` | `tuple` (H8) |
| `Point(x: 1, y: 2)`, the record idiom | `record` named after its type, `<module>_point` (H12, rule N3) |
| `Point(..p, x: 1)` | `record` with a base (H12) |
| `p.x` | `field` (H13), when `p` has a type of the module that is sent as a record; otherwise a gap |
| `Circle(1.0)`, any other constructor with fields | `tuple` whose first element is the constructor's `symbol` |
| a variable; `_` | `var` (H16); `wild` (H17) |
| `let pattern = value`, `let assert pattern = value` | `match` (H18: a mismatch fails the actor): the value's nodes first, then the pattern's. `let assert … as message` is a gap: a match has no reason |
| `pattern as name` | `match` in a pattern position: `{match, At, Var(name), Pattern}`, both sides patterns (this sender's reading of contract 9.4 and H18, the same in the Erlang and Elixir senders) |
| a function | one `clause` whose patterns are the parameters (H29) |
| `{ ... }`, a body of several statements | `block` (H19) |
| `case` | `case` and `clause` (H28, H29); several subjects become one tuple, and so do their patterns; `a \| b -> body` becomes one clause for each alternative |
| `f(x)` on a function of the module | `call` with an empty module (H32) |
| `int.to_float(x)`, `float.truncate(x)`, `float.round(x)` | `op` `to_float`, `trunc`, `round` with one operand (T8.12) |
| `int.to_string(x)`, any other function of another module | `call` with the module as imported, `gleam/int` (H32) |
| `f(x)` where `f` is a local variable | `apply` (H33) |
| `fn(x) { ... }` | a function of the module and a `fun_ref` when it captures nothing and stands where a function of the module declares a function type ("A fn that captures nothing"); otherwise `lambda` (H36), which the transpiler writes only as the function of a `spawn` |
| `add` as a value | `fun_ref` (H35) |
| `add(1, _)` | the same as the `fn(c) { add(1, c) }` it stands for: lifted where that is, otherwise a `lambda` of one parameter, `_capture` |
| `a \|> f(b)` | `f(a, b)`; `a \|> f(b, _)` is a block that binds `_pipe` first, as the Gleam compiler writes it, so `a` is still evaluated before `b` |
| `+ - *`, `+. -. *.` | `op` `+ - *` (H31, Appendix B); the operands' stated types say which it is |
| `/`, `%`; `/.` | `div`, `rem`; `/`, each inside a guard that gives 0 (0.0) for a zero divisor, as Gleam does (T8.15; "Types") |
| `==`, `!=` | `==`, `/=` |
| `< <= > >=` and the float forms | `<`, `=<`, `>`, `>=` |
| `&&`, `\|\|`, `!x`, `-x`, `<>` | `andalso`, `orelse`, `not`, `neg`, `<>` |
| `panic`, `panic as reason` | `fail` (H26) |
| `process.self()`, `process.new_subject()` (of `gleam/erlang/process`) | `self` (H20): a subject is lowered to the process that owns it, see below |
| `process.spawn(f)`, `process.spawn_unlinked(f)` | `spawn`, linked and not (H21) |
| `process.send(subject, message)` | `send` (H22). The message is sent as contract T9.12 asks: a value of a custom type with variants as it is (a symbol or a tagged tuple), any other value (a record, a tuple, an `Int`, a `Result`) as `#(subject__<type>, value)` ("Processes: what this sender splits"). The value of the contract's `send` is the message and the value of Gleam's is `Nil`, so where the call's value is used (a function's result, a `case` branch, the last statement of a block) it is sent as the block `{ send, nil }`; as a statement that is not the last of its block it is the `send` alone |
| `process.receive(subject, within)`, `process.receive_forever(subject)` | `receive` (H23) **in tail position of its function** (contract T9.13): the function is split there, and the code after the call is a continuation function the receive's clauses call (`split.gleam`). One clause for each way a message of the subject's type arrives; with `within`, the timeout and an `after` that gives `#(error, nil)`. A subject that is not a plain variable is evaluated first, in a `block` |
| `actor.new(state) \|> actor.on_message(handler) \|> actor.start` (of `gleam/otp/actor`) | an unlinked `spawn` of a loop function this codex writes, and the value `#(ok, #(started, Pid, Pid))` (H21; "gleam_otp actors" below) |
| `actor.continue(s)`, `actor.stop()`, `actor.stop_abnormal(r)` | `#(continue, s)`, the symbol `stop`, `#(stop_abnormal, r)` |
| `let assert Ok(_) = ` a `gleam_otp` static supervisor of named actors (`static_supervisor.new(strategy) \|> add(supervision.worker(fn() { … })) \|> start`, written there or as the body of a function of the module) | for each child `register` (H38) of an unlinked `spawn` of the actor's loop function with its literal state: a **static child** (contract T9.14b), with the restart and the strategy the source writes as an A4.4 override on the `spawn` (T7.6). The functions that only describe the supervisor are not sent ("A static supervisor" below) |
| `let name: Name(Message) = process.new_name("auditor")` | the symbol `auditor`: a name is a literal in the output, read where it is made, one for a message type in a unit |
| `process.send(process.named_subject(name), message)` | `send_named` (H39, contract T9.14c) to that literal name; as `process.send`, it is the block `{ send_named, nil }` where its value is used |
| `io.println(text)`, `io.print(text)` (of `gleam/io`) | a `block` of `sl_call`s of Silica's print builtins (L1, contract T9.16), one for each operand of `<>` in the text, then `nil`: a literal or any other `String` with `print`, `int.to_string(n)` with `print_int64`, `float.to_string(f)` with `print_float64`; `println` for the last piece. An operand that is not a literal or a variable is evaluated and bound first, so everything is evaluated before anything is printed, as in Gleam |
| `[]`, `[a, b]`, `[first, ..rest]`, as values and as patterns | `nil` (H7) and `list` (H10), typed `t_list` |
| `pub const limit = 10` (a literal `Int`, `Float` or `String`) | a function form of no parameters that gives the literal; a use of the constant is a `call` of it (the contract has no form for a constant) |
| `pub type Pair = #(Int, Int)` (a type alias without parameters) | no form: the alias is read as the type it names wherever it is used |

Out, sent as gaps: dicts, bit arrays, `use` (one gap for the `use` and the rest of its block), `assert`,
`let assert … as`, `todo`, `echo`, constants whose value is not a literal, type aliases with parameters, tuple
indexing (`t.0`), string prefix
patterns, calls with labelled arguments that are not already in declaration order, constructors and functions of
other modules used with labels or as values (`actor.Started(pid:, data:)` is the one constructor whose labels are
known), every function of `gleam/erlang/process` other than those in the
table (selectors, monitors, timers, exits, `call`, a name that is not made as the table shows), the rest of
`gleam/otp/*` (initialisers, selectors, `actor.call`, a named actor outside a static supervisor, a supervisor that
cannot be read: its gap says which rule the source missed), and every `@external` function other than the process
primitives below.
There is no `try`/`catch` in Gleam and nothing here depends on the contract's `try` node. And, since contract 8.6,
**everything the codex cannot state a type for where the contract requires one** ("Types").

Two rules about where a gap stands:

- **A statement that is a gap ends its block.** The program never gets past a gap, T8.10 (e) wants a type for every
  expression of a block but the last, and the statements after it could name variables that have no binding. So
  the gap is the last expression of the block that is sent, and the rest of the source block is not sent. The same
  holds after a statement that always fails (`panic`).
- **A `case` with a clause that cannot be sent is one gap, whole** (a bit array pattern, a pattern of a constructor of
  another module with labels, a variable whose type cannot be taken from the subject): a case without one of its
  clauses would be another program.

Custom types are sent as `type` forms named `<module>_<type in snake_case>` (rule N3), **before every other form of
the unit, and a type after the types its fields name** (T5.3, T8.14). A type with one variant whose fields are all
labelled (the record idiom) has a `t_record` as its root. For any other type, each variant with fields is a
`t_tagged` named after its constructor in snake_case (N5) with its fields by position (labels are dropped: a
`t_record` has no name, so two record variants in a union could not be told apart), all variants without fields are
one `t_symbols`, and several entries are joined by a `t_union`. This matches the values: a `record` node, a tuple
with the constructor's symbol first, or a symbol. A generic type keeps its parameters: `params` in the form's head,
`{t_var, Name}` inside the declaration, and `{t_named, Name, Args}` with one argument for each wherever it is used
(T8.14). A type that names itself (`Tree(a)`) is sent as it is; the contract says the transpiler reports it (T4002).
A type without constructors (`pub type Pid`, an external type) produces no form. When the module declares it as
the result of its external to `erlang:self/0` or `erlang:spawn/1` it is a process (`{t_actor, dynamic}`, as
`process.Pid`); otherwise it is stated as `{t_basic, dynamic}`: Gleam itself knows nothing about its values. A custom type with a field of a type the codex
does not know (a type of another module) is a gap form, and so is every function whose signature names it.

## Types

Contract 8.6 (decided 2026-11-13): the language side decides all data types and all numeric conversions; the
transpiler infers no type and converts nothing. glance gives syntax and no types, so **the codex has a typing pass
of its own**. It is not the Gleam compiler's inference: it reads types off the source where they are written or
follow directly, and where it cannot it says so with a gap. Nothing is sent untyped in a place where the contract
requires a type (T8.10), so the transpiler's `T3101` and `T3102` diagnostics should only ever show a bug of this
sender.

**Where a type comes from** (`codex.gleam`, each function that writes an expression also records its type;
`types.gleam` has the type representation):

| Source | Gives |
| --- | --- |
| an annotation: a parameter, a return, `let x: T = …`, a closure's parameters and return | that type |
| a literal | `Int`, `Float`, `String`; `True`, `False`, `Nil` |
| a local variable | the type of its binding |
| an operator's spelling | `+ - * / %` and `< > <= >=`: Int operands; `+. -. *. /.` and `<. >. <=. >=.`: Float operands; `<>`: String; `&&`, `\|\|`, `!`: Bool; unary `-`: Int; `==`, `!=`: both operands have the type of whichever the codex knows |
| a call to a function of the module | the result type of **its annotated signature** (the codex sees the whole module); type variables of the signature are taken from the arguments' types (`fn id(x: a) -> a` called with an Int gives Int) |
| a call through a function value | the result of the value's function type |
| a constructor of the module's custom types | its type, with the type's parameters taken from the arguments or from the place |
| a pattern | each variable takes its part of the matched value's type, position by position: tuples, the module's constructors (by their declared field types), `Ok`/`Error` of a `Result`, `actor.Started` |
| `p.x` | the declared type of field `x` in the record type of `p` |
| a function of another module | only those in `types.library_signature`: `int.to_string`, `absolute_value`, `min`, `max`; `float.to_string`, `floor`, `ceiling`, `absolute_value`, `min`, `max`; `io.println`, `print`, `println_error`, `print_error`; `string.length`, `is_empty`, `append`, `uppercase`, `lowercase`, `reverse`, `trim`, `inspect`; and the lowered calls of `gleam/erlang/process` and `gleam/otp/actor` |
| the place | when the codex has no type for an expression itself, it takes the one its place gives: the let's annotation, the function's declared result, the parameter it is passed for, the operator it is an operand of. In type-checked source the place's type is the value's, so this is a statement, not a guess |

**How a Gleam type is written** (contract 8.5). `Int` is `{t_int, i64}`, `Float` `{t_float, f64}`, `Bool`
`{t_basic, boolean}`, `String` `{t_basic, text}`, `BitArray` `{t_basic, bytes}`, `Nil` `{t_symbols, [<<"nil">>]}`, a
tuple `t_tuple`, a function type `t_fun`, `List(a)` `{t_list, a}`, a custom type of the same module
`{t_named, Name, Args}` (N3), a type variable `{t_var, Name}`, an external type of the module or `Dynamic`
`{t_basic, dynamic}`, and the library types below. Every other type of another module **is not known**: it is never
written as `dynamic`, which would be a claim.

| Gleam type | Type entry | Why |
| --- | --- | --- |
| `Result(a, e)` | `t_union` of `{t_tagged, "ok", [a]}` and `{t_tagged, "error", [e]}` | the value on the BEAM, and what this codex sends for `Ok(x)` |
| `Subject(m)` of `gleam/erlang/process` | `{t_actor, m}` | a subject is lowered to the process that owns it ("Processes"); `m` is what is sent through this reference. The process may also receive what its other subjects are sent |
| `Pid` of `gleam/erlang/process` | `{t_actor, {t_basic, dynamic}}` | a process, nothing known about its messages |
| `Name(m)` of `gleam/erlang/process` | `{t_symbols, [name]}`, where `name` is the literal of the one `let n: Name(m) = process.new_name("name")` of the unit | a registered name is a literal in the output (contract T9.14b, T9.14c), and the value of the name is that symbol. With no such statement, or more than one for `m`, the type is not known, and what names it is a gap that says so |
| `actor.Next(s, m)` | `t_union` of `{t_tagged, "continue", [s]}`, the symbol `stop` and `{t_tagged, "stop_abnormal", [text]}` | the values this sender sends `actor.continue`, `stop` and `stop_abnormal` as (its own: `gleam_otp`'s run-time values hold a selector and a `Dynamic` reason, which need the type `dynamic`) |
| `actor.Started(d)` | `{t_tagged, "started", [{t_actor, dynamic}, d]}` | the `dynamic` is a `Pid`'s unknown message type; nothing reads it |
| `actor.StartResult(d)` | `Result(Started(d), StartError)` written out, `StartError` as the symbols `init_timeout \| init_failed \| init_exited` | the start of a plain actor never gives a `StartError` in this lowering; the fields of its constructors are not sent, and a pattern that takes one apart is a gap |

A form's type table has each entry once; the signature's entries come first.

**What is hinted** (T8.5, T8.10). A hint is the existing record `{node, type, strength, policy}`; the policy is always
`default`.

| Where | Hint |
| --- | --- |
| every function form (T8.10 a) | node -1, a `t_fun` with one type for each parameter |
| every variable in a pattern: parameters, `let`, `case` clauses, closures, and the variables the codex makes (T8.10 b) | its type |
| every closure (T8.10 a) | a `t_fun` on the `lambda` node |
| every `call` and `apply` whose type the codex knows (T8.10 d) | its result type |
| every `match`, `block`, `case`, `record`, `tuple`, `field`, `fun_ref`, constructor `symbol`, `self`, `spawn`, `send`, `link`, `exit_signal`, `receive`, `loop_hint` in expression position (T8.10 e, and more than it asks) | its type |
| an operand, a let value, an argument… whose own type the codex does not know | the type its place gives, on that node |
| literals, variables used as values, operators, clauses, `fail` | none: T8.9 fixes them, and a `fail` has no value |

**Strength.** `proven` only for what is literally an annotation in the source: the signature hint of a fully
annotated function, its parameters, a closure whose parameters and return are all annotated, and the variable,
the value and the `match` of `let x: T = …`. Everything the codex derived is `inferred`: every other hint, and the signature of a
function whose return is not annotated. Note that glance only parses: `proven` is honest only for source that the
Gleam compiler has also type-checked. This codex does not run the type checker.

**Gleam construct -> types, conversions and guards sent**

| Gleam | Sent | Types stated |
| --- | --- | --- |
| `a + b`, `a - b`, `a * b` | `op` `+ - *` | both operands Int (from the spelling, if not known otherwise) |
| `a +. b`, `a -. b`, `a *. b` | the same `op` `+ - *` | both operands Float: the stated types are the only difference on the wire |
| `a < b` …, `a <. b` … | `op` `<`, `=<`, `>`, `>=` | both Int, or both Float |
| `a == b`, `a != b` | `op` `==`, `/=` | both the one type the codex knows; a gap if it knows neither |
| `a <> b`; `a && b`, `a \|\| b`, `!a`; `-a` | `<>`; `andalso`, `orelse`, `not`; `neg` | String; Bool; Int |
| `a / b` (Int) | `{ let _dividend_N = a  let _divisor_N = b  case _divisor_N == 0 { True -> 0  False -> _dividend_N div _divisor_N } }` | Int on the bindings, the case and the block |
| `a % b` | the same with `rem` | Int |
| `a /. b` | the same with `== 0.0`, `0.0` and `/` | Float |
| `a / 2`, `a /. 2.0` (a literal divisor other than zero) | `op` `div`, `rem`, `/`, no guard | |
| `int.to_float(x)` | `op` `to_float`, one operand | operand Int; the result is Float by the operator (T8.9) |
| `float.truncate(x)` | `op` `trunc` | operand Float; result Int |
| `float.round(x)` | `op` `round` (a half away from zero, as Gleam's) | operand Float; result Int |
| `float.floor(x)`, `float.ceiling(x)` | a `call` to `gleam/float`: they give a Float in Gleam, so they are not conversions between number kinds | result Float, by the codex's table |
| `int.to_string(x)`, `float.to_string(x)` | a `call`, as before | result String |

Gleam never mixes Int and Float in one operator, so no conversion is ever added by the codex: the only conversions
are the ones the programmer wrote as calls.

**The division guard** (T8.15; `division` and `once` in `codex.gleam`). Gleam defines `a / 0` as 0, `a % 0` as 0 and
`a /. 0.0` as 0.0. Silica's integer division and remainder by zero end the actor (`badarith`), and its float
division by zero gives a value that is no usable number (limitation observed, contract Appendix B). So every `/`,
`%` and `/.` is sent with the guard above, built from existing nodes. Each operand is evaluated exactly once, left
first, also when the divisor is zero: an operand that is not a local variable or a literal is bound first with a
`match` to a variable of the codex's own (`_dividend_N`, `_divisor_N`). Gleam's Int `/` cuts toward zero and `%`
has the dividend's sign, as `div` and `rem` do.

**Known deviations**

- **Int is sent as `i64`.** On the BEAM a Gleam Int has no size limit; in the output it is Silica's `int64`. A
  program that needs larger integers behaves differently, and there is no guard (what Silica does on overflow was
  not measured, Appendix B). An integer literal beyond 64 bits is a gap.
- `a /. b` with `b` equal to `-0.0`: the guard compares with `== 0.0`, which holds, and gives `0.0`; Gleam on the
  BEAM gives `-0.0`.
- `float.truncate` and `float.round` of a float outside `int64`: no defined result (T8.12), no guard. A BEAM float
  is never infinite or not a number.

**When a type is missing: a gap that says so.** Wherever T8.10 requires a type and the codex has none, the construct
is a gap (a `gap_node`, or the whole function as a gap form) whose note names the missing type, the reason, and the
rule:

| What is missing | Gap | Note ends with |
| --- | --- | --- |
| a parameter annotation; a signature naming a type of another module the codex has no entry for | the function, as a gap form | `so the function has no signature (T8.10 a)` |
| a return annotation, and a body whose type the codex cannot work out | the function, as a gap form | `so the function has no signature (T8.10 a)` |
| the type of a `let`'s value (`let xs = list.map(…)`) | the `let`, which ends its block | `so the binding xs has no type (T8.10 b)` |
| the type of a pattern variable | the `let` or the whole `case` | `so the binding x has no type (T8.10 b)` |
| both operand types of `==` | the comparison | `so the operands have no stated type (T8.10 c)` |
| the type of a call that is a statement | the statement, which ends its block | `has no type (T8.10 d, e)` |
| the type of a `case` subject | the `case` | `so the subject of this case has no type (T8.10 e)` |
| a closure parameter with no annotation, in a place that gives none | the closure | `so the function has no type (T8.10 a)` |
| the message type of a send, a receive or an actor | the call | `(T8.10 e)` |
| the record type of the value before `.x` | the field access | `(T8.9)` |

A call whose value is only passed on as an argument or returned needs no type (T8.10 d) and is sent as it is.

**What this pass does not do**, each a reason for gaps on source the Gleam compiler accepts:

- It does not infer the types of unannotated parameters, and it knows the result type of a function of the module
  only from its return annotation: annotate functions. (A function without a return annotation is itself still
  sent when its body's type is known, with an `inferred` signature; its callers do not see that type.)
- It does not follow a value forward to find a type that later use decides: `process.new_subject()`,
  `Ok(x)` with no error type in sight, `actor.continue(s)` outside a handler with an annotated result. Annotate
  the `let` (`let reply: Subject(Report) = process.new_subject()`), as `examples/actors.gleam` does.
- It knows no function of another module but the few listed above, and no type of another module but the library
  types above.
- A generic function is sent as written, with `t_var` in its signature; T8.14 says the transpiler reports it
  (T4002) and asks the sender to specialise, which this codex does only for the actor loop it writes itself.
- Type aliases and constants are gaps, so a signature that names an alias is a gap form.

## The session

The session is a `bees` session (the process nodes need that profile, T7.10) with the same eleven lowering choices
as the Erlang proof of concept and the hint policy `proven: trust, declared: check, inferred: check`. The unit
prefix is `gl_`: module `demo` asks for the Silica unit `gl_demo`.

How the sender follows the protocol (`sender.gleam`):

- **Credit, and reading while sending** (T6.2, T6.3, T6.11a). Nothing is sent without credit. The transpiler's
  window is 64 frames (as built); each time half of it is used it sends `(:stored, next)` (not in check mode) and
  then `(:credit, 32)`. The sender reads whatever has arrived before every frame it sends, without waiting, and adds
  the credit; with no credit left it waits for a reply, at most 30 seconds (T3.5), and then gives up.
- **Counts** (T5.3b). `forms` in a unit end is the number of form frames sent for the unit, and `units` in the end
  the number of units; a wrong count would be a `T1002` diagnostic, not a rejection.
- **Results** (T6.8, T6.8a). The command line prints the result and every diagnostic. `failed` has `files` 0 (a unit
  of which nothing could be written gives a `T4003`); in transpile mode `counts.gaps` is this sender's gaps plus one
  for each form the transpiler could not write (`T4002`, `T31xx`).
- **Session ids** are opaque text such as `intake_1:42` (T6.5b); the command line prints the id, and `--release`
  takes it as it is.
- **Resume is not implemented** (T6.5, T6.5a): the hello's `session` is always empty, and a session whose connection
  drops is sent again from the start as a new session.

Inter-node communication is cut from the proof of concept. An external to `rpc`, `erpc`, `global`, `pg`,
`net_kernel` and the like, or to `erlang:node`, `nodes`, `is_alive`, `spawn/2,4` and the like, is a gap form whose
note says so; a call into `gleam/erlang/node` is a gap node. The contract's `register` and `send_named` nodes
(H38, H39) are used for one thing: the children of a static supervisor, and the sends to their names ("A static
supervisor"). An external to `erlang:register/2`, `whereis/1` and the like is a gap form.

## Processes, and the receive decision

Gleam has no syntax for processes. A Gleam program reaches them through externals, so this codex recognises a
function of the module declared as an external to one of Erlang's own process functions and maps each call to it
to the contract's node. The declaration itself produces no form.

| Declared in the module as | A call becomes |
| --- | --- |
| `@external(erlang, "erlang", "self") fn self() -> Pid` | `{self, At}` (H20) |
| `@external(erlang, "erlang", "spawn") fn spawn(f: fn() -> a) -> Pid` | `{spawn, At, Fun, [], false}` (H21) |
| `@external(erlang, "erlang", "spawn_link") fn spawn_link(f: fn() -> a) -> Pid` | `{spawn, At, Fun, [], true}` (H21) |
| `@external(erlang, "erlang", "send") fn send(to: Pid, message: m) -> m` | `{send, At, To, Message}` (H22). Declared with the result `Nil` it is the block `{ send, nil }` (as `process.send`); with any other result type than the message's it is a gap |
| `@external(erlang, "erlang", "link") fn link(to: Pid) -> Bool` | `{link, At, To}` (H24) |
| `@external(erlang, "erlang", "exit") fn exit(to: Pid, reason: r) -> Bool` | `{exit_signal, At, To, Reason}` (H25) |
| `@external(erlang, "erlang", "exit")` with one parameter | `{fail, At, Reason}` (H26) |

The Gleam names are free; the external's target and the number of parameters decide.

**A subject is lowered to its owner, and that loses something.** Seven calls of `gleam/erlang/process` are mapped
(the scope table): `new_subject()` is `self`, so a subject travels as the process that made it, `send` sends to
that process, and `receive` is a contract receive. This is a lowering decision of this codex, and it is not exact:
on the BEAM a subject carries a unique reference and a receive on it takes only the messages sent to that subject;
after this lowering a receive takes **every message of the subject's message type** that reaches its process,
whichever subject it was sent through ("Processes: what this sender splits" has the list of what is not kept).
The subject expression of a receive is evaluated, for its effects, unless it is a plain variable.

Why no closer mapping: making a subject a pair of its owner and a tag, and receiving with a pattern on the tag,
needs a tag that no other subject has. The contract has no node that makes a unique value (no reference, and no
foreign call to `erlang:make_ref/0`, T9.9), and a tag made from anything else (a counter, a literal) is not unique
across processes. So the mapping stays subject = owner, and the tag of a message is its type's, until the contract
has a reference node or a tagged mailbox (proposed in `../SENDER_GAPS_STATUS.md`).

**A receive written through an external is a gap, and this is an open question for the contract.** Gleam cannot express a selective receive
without a library: `gleam_erlang` builds it from subjects and selectors, which are themselves externals. This
codex does not fake one. In `test/fixtures/gaps.gleam`, the ping-pong actor's spawn, send and self are real nodes,
and its receive is `receive_message`, an external to a helper that is not one of Erlang's process functions; that
declaration is sent as a gap form, and the functions that call it reach the gap when they run. (The examples
receive with `gleam/erlang/process`, which is lowered: the next section.) The question the
contract has to answer is how a Gleam codex should express `{receive, ...}` (H23): by recognising `gleam_erlang`'s
`Subject` and selector calls and lowering them, or by a convention the codex defines (a marked function whose
`case` is read as the receive's clauses). Neither is implemented here.

## Processes: what this sender splits

The transpiler prints a `(:receive)` only in tail position of its function, with each clause ending in a value or
in a tail call (contract T9.13). What Gleam does around a receive is Gleam's, so this sender lowers it (contract
T9.13a). Gleam has no receive keyword: a process waits in a **call**, `process.receive(subject, within)` or
`process.receive_forever(subject)`, whose value is used like any other, so in Gleam every receive is "a receive
with code after it". `src/gleam_to_silica_poc/split.gleam` rewrites the syntax tree of a module before the codex
types it; what it makes are ordinary functions, sent with the ordinary nodes. `main` of `examples/actors.gleam`:

```gleam
pub fn main() -> Nil {                              // as written
  let auditor: Name(AuditorMessage) = process.new_name("auditor")
  let assert Ok(_) = start_supervisor(auditor)
  let assert Ok(actor.Started(data: counter, ..)) = start_counter()
  add(counter, auditor, 5)
  …
  case ask(counter) { Ok(report) -> { io.println(…) … }  Error(Nil) -> io.println(…) }
  case notes(auditor) { Ok(count) -> io.println(…)  Error(Nil) -> io.println(…) }
}
fn ask(counter: Subject(CounterMessage)) -> Result(Report, Nil) {
  let reply: Subject(Report) = process.new_subject()
  process.send(counter, Get(reply))
  process.receive(reply, 1000)
}
```

```gleam
fn main() -> Nil {                                  // as sent: main, ask__c1, ask__c1__k1, main__k1, notes__c1, …
  let auditor = <the symbol auditor>                // the name: the symbol of its literal
  <static child auditor>                            // "A static supervisor"
  …
  ask__c1(counter, auditor)                         // ask receives: a copy of it that goes on in main__k1
}
fn ask__c1(counter, _k2) {                          // _k2: what main__k1 needs (its live variable auditor)
  let reply: Subject(Report) = process.new_subject()
  process.send(counter, Get(reply))                 // code before the receive: runs in the same process
  ask__c1__k1(_k2, reply)
}
fn ask__c1__k1(_k2, reply) {                        // the receive alone, with only the variables it uses
  receive {
    #(subject__report, _message) -> main__k1(_k2, #(ok, _message))
  } after 1000 -> main__k1(_k2, #(error, nil))
}
fn main__k1(auditor, _h1) {                         // the code after `ask(counter)`; _h1 is its value
  case _h1 { Ok(report) -> { … }  Error(Nil) -> … }
  notes__c1(auditor)                                // and so on: notes__c1, notes__c1__k1, main__k1__k1
}
```

| Gleam | What the sender sends | Where (`split.gleam`) |
| --- | --- | --- |
| code before a receive | nothing changes: it stays before the receive. The transpiler's process runs it when it starts, in the new process | (nothing) |
| `let p = process.receive(s, t)  Rest`, or the call as a statement, also inside the branches of a `case` and inside a block | the receive becomes the last expression; `Rest` is the **continuation** `f__k<n>(live…, value)`, which starts with `let p = value`; each clause of the receive, and its `after`, ends with a tail call of it | `cut` |
| the variables the continuation gets | the variables `Rest` uses that have a value at the cut (what a `case` branch binds does not leave it, in Gleam), and the receive's value when it is bound | `cut` (`live`) |
| several receives in one function | one continuation for each (`f__k1`, `f__k1__k1`, …) | `split_body` |
| `let p = g(…)  Rest` where `g` is a function of the module that receives (itself, or through a function it calls) | a **copy** `g__c<n>` of `g` with the continuation's variables as extra parameters, whose every end is a tail call of the continuation; a `g` that loops calls its own copy. A private `g` that nothing calls any more is not sent | `copy`, `wrap_last`, `reached` |
| a receive, or such a call, that is an operand: the subject of a `case`, an argument, an operand of an operator, the left side of a pipe (`ask(c) \|> f`, `case ask(c) { … }`, `n + process.receive_forever(s)`) | it is **bound first**, `let _h<n> = …`, and then cut as above; only when everything its statement evaluates before it is a variable or a literal, so that no order changes | `hoist` |
| a receive anywhere else (the right side of `&&` or `\|\|`, after an operand that is a call, in a `let assert … as`) | **a gap** (`receive inside an expression`) whose note says to bind the value with `let` first | `gap` |
| a pipe into a receive, `s \|> process.receive(100)` | read as the call it is | `unpipe` |
| the state a waiting process keeps | a receive of a function that is not public, when it does not use every variable its function has bound, or code of its function runs before it, is put in a function of its own with the variables it uses (`f__k<n>`), because the transpiler keeps every variable bound at a receive (T9.13a) | `split_tail` |
| a **public** function with a receive of its own (`pub fn ping_pong` of `examples/demo.gleam`) | it keeps its receive, with every variable it has bound (when they are at most six, which is what the transpiler keeps): it is then a process function itself, which is what an exported function that waits must be (T9.13). It is exported, and can be spawned | `split_tail` |
| a **public** function that waits only in a function it calls (`pub fn main` of `examples/actors.gleam`: its first wait is `ask(counter)`) | it is **sent as not exported**. It is no process function (it has no receive), and its ordinary version could only fail where it reaches the call (T9.13), so there is nothing to export; sent as exported, the transpiler writes that ordinary version and reports it (`T4002` on the unit, a gap). The entry form still names `main` (T9.6), and a `spawn` of the function inside the unit still works | `split.Split.unexported`, `codex.function_written` |
| `panic` in a branch | the process ends there; no continuation is called | `wrap_last` |
| a receive in a closure (`fn() { process.receive(s, 10) }`), or after a `use` | not touched: a closure's body runs when the closure is called. It is sent as a `(:receive)` where it stands | |

A function the split made has no annotations on the parameters the split added. Their types are the types of
the arguments of the calls of it (`settle_made` in the codex: the functions are typed until those types no
longer change), the value of a call of a function of the module has the type of that function's result
annotation, and the result is the result annotation of the source function it is cut from (**a function that
is cut needs its result annotation**). Its signature hint has the strength `inferred`. It is not exported.
Names: N6 under [Names](#names).

**Messages (contract T9.12).** A message is a symbol or a tagged tuple, and a tag has one type in a unit. So:

| The subject's message type | A message is sent as | The receive has |
| --- | --- | --- |
| a custom type of the module with variants (`Add(Int)`, `Get(Subject(Report))`, `Stop`) | the value itself: `#(add, 5)`, `stop` | one clause for each variant; the value it took is written again (`#(add, _m1)`) where the code uses it |
| any other type: the record idiom (`Report`), a tuple (`#(Int, Int)`), `Int`, `String`, `Result(a, b)`, … | `#(subject__<type>, value)`, the tag made from the type's text (`subject__report`, `subject__tuple2_int_int`; `types.message_tag`) | one clause, `#(subject__<type>, _message)` |

**What is not Gleam's behaviour** (each is a deviation of the translated program):

- **A subject does not select its messages.** A receive takes every message of its subject's *type* that reaches
  the process, whichever subject it was sent through. Two subjects of one type in one process are one mailbox.
  (`examples/actors.gleam` makes one reply subject for each question and waits for the answer before it asks
  again, so it is not affected.)
- **A message no clause takes is dropped.** A message of another type that arrives while a process waits in a
  receive is dropped by the transpiler's lowering; Gleam keeps it for a later receive on its own subject. Every
  function this sender cuts gets the transpiler's warning `T4004` for it.
- **A message's tag is its type's.** Processes that share a subject type share its tag, and a process of another
  unit does not understand it (contract T9.12: processes of different units cannot exchange messages).
- **A function that receives must be called by its name.** A function of the module that receives and is passed
  as a value, or called from a closure, is not followed: the call is an ordinary call of a process function,
  which fails when it is reached (contract T9.13).
- **A call of a function that receives costs a copy of that function for each place it is called from** with
  code after the call.
- **A public function that waits only in a function it calls** (`main` here) **is not exported** in the output
  (the table above). Another unit could not have called it anyway: a function that waits runs only as a process
  (contract T9.13), and processes of different units do not exchange messages (T9.12). Started as the entry, or
  spawned in its unit, it runs.
- **A public function that waits, called as an ordinary function** (from another unit, or by the driver of a
  test) fails when it is reached (contract T9.13); in Gleam it returns its value.
- **The value a process function ends with must not be a union** (limitation observed, `../HOWTO_language_creators.md`
  6a): a function such as `fn ask(…) -> Result(Report, Nil)` whose last expression is its receive is written
  when every call of it is replaced by a copy (it is private, and called with code after it, as in the
  example); sent as it is (public, or kept because something still names it), its Silica does not compile
  (`E2005`, measured 2026-11-14 with a scratch copy of the example in which a parameter had the name of such a
  function, which keeps the function: `reached` goes by names).
- **`io.println` output**: a float is written by Silica's `print_float64` (the whole part and at most 15 decimal
  places, cut and not rounded, where `float.to_string` writes the shortest text that reads back: `3.14159`
  comes out as `3.141589999999999`; `3.0` and `0.5` come out the same; a whole part beyond the 64-bit range,
  `1.0e22`, comes out as `9223372036854775807.0`: limitation observed, contract T9.16). `bool.to_string` and
  `string.inspect` are not lowered: such a piece is a call into a module outside the session, which the
  transpiler does not write.

## gleam_otp actors

Contract 9.2 leaves OTP behaviours open: "a sender lowers OTP behaviours into processes and receives itself, or
sends them as gaps". This codex lowers the plain actor and sends the rest as gaps.

**Mapped: the plain actor**, `actor.new(state)`, optionally `|> actor.on_message(handler)`, then `|> actor.start`
(written with the pipe or as nested calls, qualified or imported unqualified):

```
actor.new(state) |> actor.on_message(handler) |> actor.start
    ->  { let _actor_N = spawn: gleam_otp_actor_loop__g1(state)       (H21, with an argument, not linked)
          #(ok, #(started, _actor_N, _actor_N)) }

fn gleam_otp_actor_loop__g1(state) {               one function form for each kind of actor the unit starts
  receive {                                        (H23, in tail position; marked with a loop hint, H37)
    <a message of the actor's type> ->             (one clause for each way it arrives, "Messages" above)
      case handler(state, <the message>) {         (H32: the handler is called by its name)
        #(continue, _state) -> gleam_otp_actor_loop__g1(_state)
        stop -> normal
        #(stop_abnormal, _reason) -> fail(_reason)                              (H26)
      }
  }
}
```

- `actor.continue(s)`, `actor.stop()` and `actor.stop_abnormal(r)` are sent as `#(continue, s)`, the symbol
  `stop` and `#(stop_abnormal, r)`. These are this sender's own values, not `gleam_otp`'s run-time ones (which
  hold a selector and a `Dynamic` reason): nothing of an actor needs the type `dynamic`. Their type is
  `Next(state, message)`, taken from the handler's declared result.
- **The handler is a function of the module, by its name** (`actor.on_message(handle_counter)`): the loop calls
  it by name. A handler that is a closure or a variable would be state of the waiting process, and the
  transpiler writes no closure (contract T9.14): such a start is a gap that says so.
- **A named actor under a static supervisor** runs the same loop function; it is started as a static child
  ("A static supervisor" below).
- The value of `actor.start` is `Ok(Started(pid:, data:))` with the new process twice: the actor's subject is
  its own process under the subject lowering. `actor.Started(data: s, ..)` in a pattern is understood.
  `started.data` is a gap: `Started` is not sent as a record ("What the codex cannot know").
- The state is evaluated by the starting process. **The new process is not linked**: the transpiler writes no
  link (contract T9.15), so the process that started an actor does not end when the actor fails, as it would
  with `gleam_otp`. (The session's `a4_4` choice `transient` then has the transpiler's own supervisor start a
  failed actor again from the state it was started with; `gleam_otp` restarts nothing by itself. This holds for
  an actor started with `actor.start` outside a supervisor, as the example's counter; an actor under a static
  supervisor has the restart its source writes.)
- **Types.** The state's type is the type of `actor.new`'s argument; the message type is the handler's second
  parameter (the handler has an annotated signature), or else the one the place gives
  (`-> actor.StartResult(Subject(Message))`). With either missing the start is a gap (T8.10 e: the message of
  the loop's receive would have no type). The new process is stated as the subject, `{t_actor, message}`; it is
  also put in `Started`'s `pid` place, whose entry says `{t_actor, dynamic}`: one value under two stated types,
  which is this lowering's doing.
- **The loop function is not generic.** T8.14 says a function with a type variable in its signature is not written,
  so the codex writes one loop function for each kind of actor a unit starts (a state type, a message type and a
  handler), with those types in its signature and on every node that needs one, all `inferred`. They are named
  `gleam_otp_actor_loop__g1`, `__g2`, … in the order the unit first starts each kind. No function of the module can
  have such a name: a Gleam name with `__` in it is escaped (N4).

What this lowering does not carry, compared with `gleam_otp` on the BEAM:

- the actor takes every message of its message type that reaches its process (the subject lowering), and a
  message of another type is dropped without a word; `gleam_otp` logs and drops messages that were not sent to
  the subject;
- the actor is not linked to the process that started it (above);
- OTP system messages (`sys:get_state`, suspend, resume) are not answered;
- `actor.start` does not wait for the new process to initialise. For the plain actor the initialiser cannot fail
  and has no effect of its own, so the only difference is timing.

**Not mapped, each one gap node** (T9.10): the outermost call that is not lowered. Its arguments are not sent: the
program stops at the gap, and as expressions of a block before its last they would each need a type (T8.10 e). (A
function that takes or gives a type of these libraries the codex has no entry for, such as `process.Name`, is a gap
form already: it has no signature.)

| Call | Why it is a gap |
| --- | --- |
| `actor.new_with_initialiser`, `initialised`, `returning` | `start` must wait for the initialiser's answer and report `InitTimeout`, `InitFailed` or `InitExited`. That takes unlinking and killing the child on a timeout and a monitor; the contract has no node for either |
| `actor.named` outside a static supervisor that was read; `process.new_name` and `process.named_subject` where the unit does not make exactly one name for the message type | a name is a registry entry, and the contract writes one only for a static child, under a literal name (T9.14b): a running process cannot be given a name, and a name made when the program runs is no literal ("A static supervisor" says what is read) |
| `actor.selecting`, `actor.with_selector`, `actor.call`, `process.call` | selectors, monitors and references have no node |
| a call of `gleam/otp/static_supervisor` or `gleam/otp/supervision` that is not part of a supervisor that was read | see below |

One more thing matters for a plain actor: every proof of concept declares A4.4 as `restart=transient` (the worked
example's choice), so every `spawn` it sends is, by the contract's words, restarted when it fails. Gleam's
`process.spawn_unlinked` and a `gleam_otp` actor outside a supervisor never restart; `restart=temporary` would say
that. It is left as it is until the three senders change together (the choice is the user's).

## A static supervisor

**What this sender maps.** A static supervisor is `gleam_otp`'s (OTP's) own construct; the contract has no node
that means "OTP supervisor", and the transpiler knows nothing of a child specification. What the contract has is
the **static child** (T9.14b): a `(:register)` of a `(:spawn)` with literal arguments, which the transpiler writes
into the child list its unit's supervisor has from its start (Silica's `Supervisor` behaviour; BEES A4.4).
`src/gleam_to_silica_poc/sup.gleam` reads the supervisor from the syntax and the codex sends that, before the
lift and the split and before anything is typed. From `examples/actors.gleam`:

```gleam
fn start_auditor(name: Name(AuditorMessage)) -> actor.StartResult(Subject(AuditorMessage)) {
  actor.new(0)                                        // start_auditor and start_supervisor are not sent:
  |> actor.named(name)                                // what they say is in the static child
  |> actor.on_message(handle_auditor)
  |> actor.start
}

fn start_supervisor(name: Name(AuditorMessage)) -> actor.StartResult(supervisor.Supervisor) {
  supervisor.new(supervisor.OneForOne)
  |> supervisor.add(
    supervision.worker(fn() { start_auditor(name) })
    |> supervision.restart(supervision.Transient),
  )
  |> supervisor.start
}

pub fn main() -> Nil {
  let auditor: Name(AuditorMessage) = process.new_name("auditor")   // sent as: (:match, auditor, (:symbol "auditor"))
  let assert Ok(_) = start_supervisor(auditor)        // sent as:
  …                                                   //   (:register, "auditor",
}                                                     //      (:spawn, (:fun_ref "" "gleam_otp_actor_loop__g2" 1),
                                                      //               [(:int 0)], link false))
fn add(counter: …, auditor: Name(AuditorMessage), amount: Int) -> Nil {     //   with the override on the (:spawn):
  process.send(counter, Add(amount))                  //      a4_4 chosen restart=transient strategy=one_for_one
  process.send(process.named_subject(auditor), Note(amount))        // (:send_named, "auditor", #(note, amount))
}
```

| Gleam | What is sent | Where it comes from |
| --- | --- | --- |
| the place of the supervisor's start | one static child node for each child, in the order they are added | the statement `let assert Ok(_) = E` of a function body, where `E` is the supervisor written out, or a call of a function of the module whose whole body is the supervisor written out |
| the child list | fixed when the program is sent: the supervisor is **read, not run**: `static_supervisor.new(Strategy)`, `static_supervisor.add(child)` for each child, `static_supervisor.start`, with the pipe or as nested calls | the supervisor expression |
| a child | `supervision.worker(fn() { S })`, where `S` is the actor written out, or a call of a function of the module whose whole body is the actor written out | the argument of `add` |
| the child's function and argument | the `(:spawn)`: the loop function of the actor's kind ("gleam_otp actors": the handler is called by name) with the state given to `actor.new`, which is a **literal** (an `Int`, a `Float`, `True`, `False`, a constructor without fields) | `actor.new(state) \|> actor.named(name) \|> actor.on_message(handler) \|> actor.start` |
| the child's name | the literal of the one statement `let n: Name(M) = process.new_name("literal")` of the unit, where `M` is the handler's message type. The argument of `actor.named` is not read: Gleam's types say it is a `Name(M)`, and the unit has one | `process.new_name` |
| `supervision.restart(R)` | the override's `restart`, **as written**; not written: `permanent`, `gleam_otp`'s default for a worker. The example writes `Transient` | the child specification |
| the strategy | the override's `strategy`, as written (`OneForOne`, `OneForAll`, `RestForOne`) | `static_supervisor.new` |
| the link between a supervisor and its child | `link` `false`: the child is under a supervisor, which is what that link is for | |
| `static_supervisor.restart_tolerance(intensity:, period:)` | read, and not sent: the contract has no place for it (T9.14b) | |
| `process.send(process.named_subject(name), message)`; `let s = process.named_subject(name)` and `process.send(s, message)` in one function | `(:send_named, "literal", message)` (T9.14c). The name, and the subject made of it, are values: the symbol of the literal | the type `Name(M)` of `name` |

The session's own `a4_4` choice (for an ordinary `spawn`) is not touched by this: the static child's restart
policy travels in its override.

**A name is known by its type.** `gleam_erlang` makes a name when the program runs (`process.new_name(prefix)`
adds a unique suffix), and the contract's static child and `send_named` take a literal. So this sender reads a
name where it is made, `let n: Name(M) = process.new_name("literal")` as a statement of a function body (the
annotation is needed: Gleam takes `M` from later use), and takes the prefix as the name. It allows **one such
statement for a message type in a unit**, and one message type for a literal, which must be an identifier
(lowercase letters, digits, single underscores). Then every value of the type `Name(M)` in the unit is that name,
whatever function it was passed to, and that is how a send finds its literal. With no such statement for `M`, or
two, the type `Name(M)` is not known to this sender: a function that names it is a gap form, and a call of
`process.new_name` or `process.named_subject` a gap node, each with a note that says this.

**What is read**, as the table says. Anything else, and the supervisor is not read: **the start is a gap whose
note says which rule the source missed** (a child without `actor.named`; a state that is not a literal; a handler
that is not a function of the module by its name; a child that is a supervisor; `supervision.timeout`,
`supervision.significant`, `static_supervisor.auto_shutdown`; a strategy or a restart that is not written as its
constructor; an initialiser), and the functions that describe it are sent as the functions they are (usually gap
forms: their signatures name `static_supervisor.Supervisor`). A start whose value is used
(`let assert Ok(sup) = …`, `case start_supervisor(name) { … }`) stays a call, which is a gap: the supervisor's
own process has no node. `test/fixtures/gaps.gleam` has one of each kind, and the tests read their notes.

**What is not Gleam's behaviour.**

- **The children exist from the program's start**, not from the call of `static_supervisor.start`: the unit's
  supervisor is started by `main` (or `to_silica_start()`), with its child list. A child has not run before the
  start is reached (where the node stands it is sent its start message), but a message sent to its name before
  that starts it. Reaching the start a second time does nothing; in Gleam it starts a second supervisor, whose
  child cannot take the name again (not run).
- **The supervisor is no process.** Its children are children of the unit's own supervisor, beside every process
  the module spawns. It has no value (a start whose value is used is a gap) and cannot be stopped.
- **A name is its statement.** Running `process.new_name("auditor")` twice gives two names in Gleam and the same
  name here. The name in the output is `auditor`; in Gleam it is `auditor` with a suffix.
- **A named subject is no process.** `process.named_subject(name)` can be sent to, where it is written or through
  a `let` of the same function. Passed to a function that takes a `Subject`, returned, or put in a message, it is
  a gap node that says to pass the `Name` instead: no node gives the process that is registered under a name.
  `process.receive` on a named subject is not lowered (the actor's loop does the receiving).
- **`OneForAll` and `RestForOne` are not followed**: the unit has one supervisor, whose strategy is the session's
  (`one_for_one` here); the transpiler reports the difference (`T2001`).
- **The restart tolerance is not carried**: the unit's supervisor allows 100 restarts in 10 seconds, and when
  that is passed the whole program ends, not one supervisor.
- **A restarted child is started lazily**: it runs to its first receive when its next message arrives (contract
  T9.14). For an actor, whose loop starts with its receive, that is the same. (Run 2026-11-14: a scratch copy of
  the auditor with a `Crash -> actor.stop_abnormal("boom")` clause answers 2 notes, then 0 after the crash,
  then 1 after one more note, in Gleam and in Silica.)
- **A send to the name of a child that has ended and is not started again** ends the sender in both: Gleam's
  `process.send` to a name nothing is registered under fails, and Silica's sender ends
  (`a5_4 accept_sender_death`). Not run.
- **The start function is not run.** Only the actor it starts is read: anything else it does is a reason not to
  read the supervisor.

## A fn that captures nothing

The transpiler prints a `(:lambda)` only as the function of a `(:spawn)` (contract T9.14): a Silica function
literal captures only integer literals (limitation observed), so a closure has no lowering there. What a `fn`
is in Gleam is this sender's business, and a `fn` that uses no variable of the function around it is a function
of the module in all but name. `src/gleam_to_silica_poc/lift.gleam` sends it as one, before the split:

```gleam
pub fn twice(f: fn(Int) -> Int, n: Int) -> Int { f(f(n)) }

pub fn add_four(n: Int) -> Int {                          // sent as:
  twice(add(2, _), n)                                     //   add_four(n) = twice(add_four__f1, n)
}                                                         //   fn add_four__f1(_capture: Int) -> Int { add(2, _capture) }

pub fn pipeline(n: Int) -> Int {                          //   pipeline(n) = … twice(pipeline__f1, _) …
  n |> add(1) |> twice(fn(x) { x * 2 }, _) |> negate      //   fn pipeline__f1(x: Int) -> Int { x * 2 }
}
```

- **Which `fn`**: one written directly as an argument (not labelled) of a call of a function of this module
  whose declaration gives that parameter a function type of the fn's arity, without type variables; also when
  the call is the right side of a pipe or a capture. That declared type is where the made function's signature
  comes from (an annotation the `fn` writes itself is kept); its hint is `inferred`, as for everything this
  sender makes.
- **A capture whose other arguments are all literals** (`add(2, _)`) is the `fn` it stands for and is lifted the
  same way.
- **"Captures nothing"** is decided by names, on the safe side: a name the fn's body uses that is not one of
  its parameters, and that the function around the `fn` binds anywhere outside it (a parameter, a `let`, a
  `case` clause, another fn's parameter), counts as captured.
- **What stays a `(:lambda)`**: a closure (`fn(x) { x * n }`), which the transpiler answers with its own gap
  (`T4002`); a `fn` bound to a variable or returned; an argument of a function of another module or a labelled
  argument; a `fn` whose body waits in a `process.receive`; the `fn` of a `process.spawn_unlinked`, which is the
  contract's own shape.
- The made function is named `<function>__f<n>` (N6) and is not exported. It behaves as the `fn` does: there is
  nothing here that is not Gleam's behaviour.

## The examples, run

2026-11-14, transpiler build of the same day (default build), compiler `silica-999916-macos-applesilicon`,
Gleam 1.19.2. Each example was sent in transpile mode, its unit exported and compiled with a driver that calls
its exported functions, and the same calls were run in Gleam; floats were compared as numbers.

| | `examples/demo.gleam` | `examples/actors.gleam` |
| --- | --- | --- |
| result | `ok`, 1 unit, 0 gaps, 0 rejected | `ok`, 1 unit, 0 gaps, 0 rejected |
| gaps before (2026-11-13) | 8 (3 sent by this sender, 5 answered by the transpiler) | 4 (3 and 1) |
| warnings | `T2001` (1, the session's choices the printer does not follow: `a3_4`, `a3_2`), `T4004` (1: `ping_pong/1`) | `T2001` (1), `T4004` (2: `ask__c1__k1/2`, `notes__c1__k1/1`) |
| calls compared | 47 | 17 (14 calls of the pure functions, and the 3 lines `main` prints when the unit runs as the program) |
| the same in Gleam and in Silica | 46 | 17 |
| different | 0 | 0 |
| fail in both | 1 (`positive(-1)`: `panic` in Gleam; in Silica the actor that calls it ends, with `language_error` (integer division by zero), not with the panic's text: contract H26) | 0 |

Differences that are not counted as mismatches: `area(Circle(1.0))` is `3.14159` in Gleam and
`3.141589999999999` in Silica (`print_float64`, above); `ping_pong(41)` gives 42 in both when it runs as a
process (the driver spawns it), and called as an ordinary function it fails in Silica, by the contract's design
(T9.13), where Gleam returns 42. Not run: the other strategies and restarts of a static supervisor
(`Temporary`, `Permanent`, `OneForAll`), two static children in one unit, a send to a name before the start is
reached.

## What the codex cannot know

glance gives the syntax of one module and nothing else. These are the consequences; each is a limit of the proof
of concept, not of the contract.

- Types: see "Types", "What this pass does not do". The typing pass is the codex's own; a sender built on the Gleam
  compiler's typed tree would have every type and none of these gaps.
- `p.x` is a `field` node only when the codex knows that `p` has a type sent as a record (one constructor, every
  field labelled). On a value of a type with several variants, which travels as a tuple, or of a type of another
  module (`started.data`), it is a gap.
- `a |> f(b)` is always `f(a, b)`. Gleam reads it as `f(b)(a)` when `f` does not take `a` first.
- Constructors and functions of other modules are known by position only.
- The unit name is the file's name without `.gleam`. A module in a subdirectory (`foo/bar`) is not named in full.
- Locations count lines and columns from 1, and columns count bytes. glance gives no position for a parameter or a
  clause: parameters carry their function's position and a clause its first pattern's.
- The transpiler's replies are decoded with `binary_to_term/1`, without the `safe` option: the atoms of the
  replies do not exist in a Gleam program until they are read. The transpiler is a local, trusted peer (T3.1,
  T3.2).

## A node program: three nodes that send messages to each other

**Built, tested and run 2026-11-18** (Gleam 1.19.2, installed with Homebrew; before that day this code had never
been compiled: it was written 2026-11-16 on a machine with no Gleam).

- **Compiles.** `gleam build` compiled the node support as written (`frame.gleam`, `wire.gleam`, `codex.gleam`:
  `node_directives`, `named_call`), with no error and no warning. One thing was missing and was added: a function
  a `remote` line names is no longer sent as a form (the text here and in the code already said "its body is not
  sent"; `forms` in `codex.gleam`).
- **Tests.** `test/run_test.sh 7411`: 68 passed, no failures (the 63 from before and 5 for node programs: the
  copies in `test/three_nodes/` are the examples, every frame of the three passes the contract's
  `check_frame:check/1`, no gap, no entry form and no form for the send functions, the hub's and an edge's
  `(:node)` form field by field, their `(:send_named)` nodes, `redial off` as 0 and 0, no form without a `name`).
- **Names cross a node as atoms (2026-11-20).** The node examples (`three_nodes/`, `three_nodes_mesh/`,
  `five_nodes_mesh/`) used to send the name to answer to as a `String`, so their wire shape was
  `(atom, string, int64)` and a Gleam node could not exchange messages with an Erlang or Elixir node of the same
  example (`payload refused bad_tag`). They now declare the field as `Atom` and carry it as a constructor without
  fields of a type `Who` (`AInbox` is the atom `a_inbox` on the BEAM and in Silica), which gives
  `(atom, atom, int64)`. All eleven transpile with no gap and ran live again; a Gleam node runs in one mesh with
  Erlang, Elixir and hand-written Silica nodes (`../examples/six_nodes_mixed/`).
- **Five-node mesh tests (2026-11-20).** 72 passed with two more for `examples/five_nodes_mesh/`: the copies, and
  every frame, the four peers of each node, how many it dials, and its eight `(:send_named)` names.
- **Mesh tests (2026-11-20).** 70 passed with two more for `examples/three_nodes_mesh/`: the copies in
  `test/three_nodes_mesh/` are the examples, and every frame passes `check_frame:check/1` with no gap, the peers
  and redial of each node, and its four `(:send_named)` nodes.
- **The examples are Gleam that type-checks**: `gleam test` compiles the copies in `test/three_nodes/`. They were
  changed to get there and to transpile: the entry is `run`, not `main`; the send functions hold the BEAM's send;
  and the message types have no field labels (`Request(Who, Int)`, `Reply(Int)`): with labels a type of one
  constructor is the record idiom, sent as a `(:record)`, and the transpiler prints only a symbol or a tagged
  tuple as a message (`T4002`, one gap in each unit before the change).
- **Sink.** Each of `hub.gleam`, `edge_a.gleam`, `edge_c.gleam`: check mode `ok (units 1, gaps 0, rejected 0,
  files 0)`; transpile mode `ok (units 1, gaps 0, rejected 0, files 4)` (`gl_<unit>.silica`, `.wire`,
  `.bees.config`, `.atoms`), with the warnings `T4004` (`run/0` goes on in another function) and `T2001`.
- **Live run.** The three units were built with `../tools/node_kit/build_node.sh` (project-bees, compiler
  `silica-compiler` = 999906, Apple Silicon, EPMD on 4369) and run together, hub first, the edges 3 s later: cookie
  digest accepted and handshake complete on both links, `hub: request from a_inbox`, `hub: request from c_inbox`,
  `a: the hub answered 42`, `c: the hub answered 68`. Every node also printed `[silica] root actor exited (no
  supervisor)` several times; where that comes from was not looked into.
- **Not run:** the three modules on the BEAM itself, as Gleam. There they would not talk to each other as they
  are: `process.new_name("hub_in")` registers a name with a unique suffix, not `hub_in`, and nothing starts
  distribution.

**What this sender maps** (contract T9.17). One Gleam module is one node. Gleam has no attribute that carries data,
so the node is declared in comment lines the sender reads from the source text:

```gleam
//@silica_node name hub@localhost
//@silica_node cookie_file cookie
//@silica_node peer a@localhost 127.0.0.1 listen
//@silica_node local hub_in request Atom Int
//@silica_node remote a_inbox a@localhost reply Int send_a_inbox
```

`name` (required), `peer <node> <host> dial|listen`, `local <name> <tag> <kind>...`,
`remote <name> <node> <tag> <kind>... <function>`, and the optional `creation`, `listen_address`, `listen_port`,
`epmd_port`, `cookie_file`, `net_ticktime_s`, and `redial off` or `redial <initial_ms> <max_ms>` (on a node with a dial peer; BEES has no default). A kind is `Int`, `Float`, `String`, `Bool` or `Atom`. The tag is the
snake-case name of the message's constructor (`Request(..)` is `request`). The last word of a `remote` is a function of
the module: **a call of it is sent as `(:send_named)`** (H39) and the function itself is not sent (no form), so its
body is free to be the BEAM's own send, as in the examples (an `@external` to `erlang:send/2` with the destination
`#(atom.create("a_inbox"), atom.create("a@localhost"))`). **The entry is `pub fn run()`, not `main`**: BEES owns the
node program's `main` (`../tools/node_kit/README.md`), so no entry form is sent; `run` waits in a `process.receive`
of its own, which makes it a process function the transpiler exports and the node's root starts. A pid does not cross a node: a request names the
registered name to answer to (a `String` field), and the answering function picks the send by it (`answer/2` of
`examples/three_nodes/hub.gleam`).

## How to run

Gleam 1.19 and Erlang/OTP are needed.

```sh
gleam run -- [--port N] [--mode check|transpile] [--dump] file.gleam ...
gleam run -- [--port N] --release SESSION
```

The host is always 127.0.0.1 (T3.1), the default port 7411, the default mode `check`. `--dump` prints the frames
as Erlang terms and sends nothing. `SESSION` is a session id as a transpile session prints it, such as
`intake_1:42` (T6.5b). The exit status is 0 when the session's result is `ok` (or after a dump), 2
for a usage error, and 1 otherwise, including a file that does not parse.

```sh
gleam run -- --dump examples/demo.gleam
gleam run -- examples/demo.gleam
gleam run -- --mode transpile --port 7411 examples/demo.gleam
```

`examples/demo.gleam` and `examples/actors.gleam` each end a check-mode session with status `ok` and 0 gaps, and
a transpile session with `ok` and 0 gaps (T6.8; "The examples, run"). `test/fixtures/gaps.gleam` ends a check-mode
session `ok` with 7 gaps and a transpile session `partial` with 11 (its 7 and 4 the transpiler answers: a closure,
a call into another module, a linked spawn, and the callers of the foreign receive), so the exit status is 1. A
finished transpile session holds one of the transpiler's storage regions until it is released ("Release a
session").

## How to test

```sh
test/run_test.sh            # offline and loopback tests
test/run_test.sh 7411       # the same, and a check-mode session with the transpiler on that port
```

The script compiles the contract's two Erlang binding modules with `debug_info` into `build/contract_bindings`,
puts them on the code path with `ERL_FLAGS`, and runs `gleam test`. Setting `TO_SILICA_PORT` does the same as
giving a port. Plain `gleam test` works too, except that the checker test fails with a message that says to use
the script.

- Offline: every frame of the example passes `check_frame:check/1`, before and after a trip through the external
  term format; node and type tables are in post-order (T9.2), every node has its own location (T9.3), every hint
  names a node and a type entry of its form, and every function form has a signature hint with one type for each
  parameter (T8.5, T8.10 a); `seq` counts from 0 (T5.1); **neither example has a gap**, and the gaps of
  `test/fixtures/gaps.gleam` are the 3 gap forms and 4 gap nodes expected (T9.10), the notes of its unreadable
  supervisors naming the rule each missed; the example uses the node kinds the codex writes (`register`,
  `send_named`, `sl_call` and `loop_hint` are in `examples/actors.gleam`, `link` and `gap_node` in the fixture);
  the same source gives the same bytes; a file that does not parse gives no frames. For `examples/actors.gleam`:
  its frames pass the checker, it has no gap, its type forms come first, the functions the split made of `main`,
  `ask` and `notes` are there (and `ask`, `notes`, `start_supervisor` and `start_auditor` themselves are not),
  `main` is not exported and starts with the name and the static child with its A4.4 override, and its unit ends
  with the two actor loop functions.
- Over both examples: every operand of every operator has a stated type as T8.9 defines it, the two operands of
  an arithmetic or comparison operator have the same one, `div` and `rem` have integers, `/` floats, and each
  conversion the kind it converts from (T8.10 c, T8.11, T8.12).
- One test for each mapping: a source snippet in, the expected nodes, type entries or hints out, every frame
  through the checker. Names (and the decoder that inverts N4 on some fifty awkward names), `let assert`, alias
  patterns, library types, unknown types, the receive subject, the actor's values, start and loop functions, the
  OTP gaps, `actor.Started` in a pattern, release; and for contract 8.6: typed `let` bindings, call results,
  operand types from the operator's spelling, the three division guards, the three conversions, closures, a gap
  for each kind of missing type, type forms first. For the split (contract T9.13a): code after a receive and
  several receives (continuations, their live variables, their signatures typed from the calls of them), a
  receive in a branch of a `case`, a call of a function that receives (the copy, the continuation, the callee
  that is no longer sent), a pipe into a receive, a receive that is an operand (bound first), one that cannot be
  bound (the gap), a `use` after a receive; a public function that waits (it keeps its receive, or is sent as
  not exported); the two ways a message is sent (T9.12); `io.println` and `io.print`
  as print builtins (T9.16); a constant as a function, a type alias, lists, and an external type that is a
  process. For the static supervisor (T9.14b, T9.14c): the static child with its override, the functions that are
  no longer sent, a name as a symbol, a send to a name written at the send and through a `let`, a named subject
  passed as a value (the gap), a restart as written, and three supervisors that cannot be read, each with its
  note. For the lift (H36): a `fn`, a capture and a piped call lifted, the made function's nodes and signature,
  and a closure and a bound `fn` that stay `lambda`s.
- Loopback: the sender runs a whole session against stand-in servers inside the test. The first grants credit two
  frames at first and one at a time after, so the sender must wait for credit (T6.2). The second is a session of
  more than 100 frames against a window of 64, as the transpiler is built: it sends `(:stored, n)` and
  `(:credit, 32)` after the first half window, which the sender must read while it still holds credit, then lets
  the sender use its whole window and checks that nothing arrives while the sender has no credit before it sends
  the next pair (T6.3). These test the sender's side of the protocol. The stand-ins are not the transpiler and
  validate nothing but `seq` and credit.
- Online: with a port, the frames of both examples go to the transpiler in check mode and the result must be
  status `ok` with 0 rejected, 1 unit and 0 gaps for each. Without a port the test prints
  that it was skipped. `TO_SILICA_RELEASE_PORT=7411 test/run_test.sh` also releases an unknown session and expects
  `freed` false; it is apart from the others because the transpiler build of 2026-11-13 can end with a memory
  fault on a release connection (`../APP_GAPS.md`, C1).

The examples must be valid Gleam. `test/demo.gleam` and `test/actors.gleam` are byte-for-byte copies of the files
in `examples/` (tests check that), so `gleam test` compiles and type-checks them with the rest of the test tree.
After changing an example: `cp examples/demo.gleam examples/actors.gleam test/`. The node programs are copied the
same way, into `test/three_nodes/` (`cp examples/three_nodes/*.gleam test/three_nodes/`; a test checks the copies). `test/fixtures/gaps.gleam` is
compiled with the test tree too (its foreign receive is only declared; the fixture is not run).

## Open questions for the contract

- How a Gleam codex should express a receive on a subject (above). A static supervisor is answered by contract
  T9.14b; what stays open there is a name made when the program runs (this sender reads the literal prefix where
  the name is made, one name for a message type), and a named subject as a value (no node gives the process
  registered under a name).
- The spelling of names. The contract constrains only `silica_unit`; the rules this sender follows are in
  "Names". In particular a constructor is sent in the BEAM's spelling (`stop`, `{point, X, Y}`), so that Gleam
  and Erlang units of one session agree on values.
- There is no node for a tagged value: a variant with fields is a `tuple` with a `symbol` first, while its type
  is a `t_tagged`. A `record` node carries a name and a `t_record` does not, and nothing says how a `record`
  node's name relates to a `type` form's name (here both are the type's N3 name).
- Whether a `match` node in a pattern position is an alias pattern (this sender's reading).
- T8.9 does not say what the stated type of a `gap_node` is, nor whether one may stand where a typed value is
  required (an operand, a let's value). This sender hints a gap node with the type its place gives when there is
  one, and otherwise ends the block at it.
- T8.9 lists `(:tuple)` as "the tuple of its elements' stated types"; a Gleam variant with fields is sent as a
  tuple with the constructor's symbol first, hinted with its `t_named` type. Whether the transpiler accepts that
  hint on a tuple node (the hint row comes first in T8.9, so this sender reads it as allowed) decides whether
  variants can be written.
- Whether an expression of several nodes (`block`, `case`) may stand in a clause's guard: a division in a guard
  is sent with its division guard there.
- A hint on a variable in a pattern and the type the pattern's place gives are both stated by this sender; T8.10
  (b) needs only one of them.
- Gleam's `==` is structural equality between values of one type. It is sent as `==`; `=:=` may be closer.
- There is no node for a foreign call (T9.9), and Gleam reaches the platform only through externals, its
  standard library included. A call such as `int.to_float(x)` is sent as a call to module `gleam/int`, which is
  not a unit of the session; the contract does not say how such a call resolves.
- `unit_name` and the module of a `call` are Gleam module paths with a slash (`gleam/int`). T5.2 constrains only
  `silica_unit`.
- Whether variable names made by a codex (`_pipe`, `_capture`) are acceptable as `var` names.
- Whether locations count bytes or characters in a column.
- `process.Pid` is claimed as `{t_actor, {t_basic, dynamic}}`; a type of the module itself without constructors
  (`pub type Pid`, used with externals) is `{t_basic, dynamic}`, because nothing in the syntax says it is a process.
  T8.1 says the untyped representation does not exist as built, so functions that name such a type are not
  written yet; the statement is still the true one.

## Names

One scheme, the same in the Erlang, Elixir and Gleam senders. It is in `src/gleam_to_silica_poc/names.gleam`.

| Rule | What | Spelling | Example |
| --- | --- | --- | --- |
| N1 | `silica_unit` | the prefix `gl_`, then the module path with each `/`-separated segment in snake_case, joined by `_` | `my/mod` is `gl_my_mod` |
| N2 | `unit_name`; the `module` of a `call` and a `fun_ref` | the module as the user writes it (T5.2), unchanged | `gleam/int` |
| N3 | a `type` form's name, `t_named`, a `record` node's name | `<N1 without the prefix>_<the type's name in snake_case>`: the session has one namespace for types, so a type carries its module | `Tally` of `actors` is `actors_tally` |
| N4 | function, variable and field names (a function's head, `call`, `fun_ref`, `var`, the fields of a `record`, a `field` and a `t_record`) | the source spelling through `ident`, which is **injective** | `bump`, `total`; `a__b` is `a__x5f___x5f_b` |
| N5 | `symbol`, `t_symbols`, a `t_tagged` tag | the atom's text on the BEAM: a constructor in snake_case, as Gleam's Erlang backend writes it. Not changed further: making a symbol a Silica atom is the transpiler's work (H5, BEES A6.3) | `Ok` is `ok`, `Nil` is `nil`, `StopAbnormal` is `stop_abnormal`; `True` and `False` stay `boolean` nodes |
| N6 | a function `split.gleam` or `lift.gleam` made | the sent name of the function it was made from, then its suffix: `__k<n>` for a continuation (or a receive put in a function of its own), `__c<n>` for a copy of a function that receives, `__f<n>` for a function literal that captures nothing. `ident` never writes `__k`, `__c` or `__f`, so these names are no source function's. (Inside the sender such a function is named with `:`, `main:k1`, which no Gleam function is.) | `main__k1`, `ask__c1`, `ask__c1__k1`, `add_four__f1` |

**`ident` (N4)** reads the source name's characters left to right:

| Character | Written |
| --- | --- |
| a letter or a digit (`A-Z`, `a-z`, `0-9`) | itself |
| `?` | `__q` |
| `!` | `__b` |
| `_` | `_` when the character before it is not `_` and the character after it (if there is one) is neither `_` nor a character that is escaped; otherwise `__x5f_` |
| any other character | `__x<lowercase hex code point>_` |

An empty name is `__e`, and a digit in first place is escaped (`1abc` is `__x31_abc`). An escape always starts with
`__`, and a kept `_` never stands next to another, so a decoder reading left to right gives the source name back:
`valid?` is `valid__q`, `valid__q` is `valid__x5f___x5f_q`, `valid_q` stays `valid_q`. The tests have the decoder
and run it on some fifty awkward names. **An ordinary Gleam name is unchanged**; only a name with two underscores in
a row changes (Gleam names have no `?`, `!` or other characters).

**Arity.** Gleam has one arity for each function name, so no arity is ever written into a name. (The Erlang and
Elixir senders write a name defined at several arities as `<ident(name)>__<arity>`.)

**Names the codex makes up.** Functions: `gleam_otp_actor_loop__g<n>`. After `__` the function `ident` writes only
`q`, `b`, `x` or `e`, so a name with `__g` in it is no source name's spelling, and no function of the module can
collide with it. Variables: `_pipe`, `_capture`, `_message`, `_state`, `_reason`, `_actor_<n>`, `_dividend_<n>`,
`_divisor_<n>`; a Gleam variable that can be read never starts with `_`, and `ident` leaves these as they are.

snake_case (N1, N3, N5) puts `_` between a lowercase letter or digit and an uppercase letter, and between an
uppercase letter and an uppercase letter followed by a lowercase one, then lowercases: `HTTPServer` is
`http_server`. Unit and type names (N1, N3) keep their earlier spelling of other characters (`?` is `_q`, `!` is
`_b`, others `_x<hex>_`); it is not injective and does not need to be for Gleam, whose module and type names have
only letters, digits and `_`.

**What remains for names**, none of it handled by this sender:

- **Silica's reserved words and builtins, and `main`.** A Gleam function named like one is sent under its own
  name, and the transpiler writes it with `__` appended (contract T9.11: `main__`, `move__`), in its definition
  and in every call. A record field named like a reserved word is still not written (`T4002`). The name of a
  static child (the literal of `process.new_name`) is written as a child id: this sender does not check it
  against the ids the transpiler makes itself (T9.11).
- N1 and N3 are not injective: modules `a/b` and `a_b` ask for the same unit name `gl_a_b`, and the types
  `HTTPServer` and `HttpServer` of one module are both `<module>_http_server`.
- The unit name is the file's name: glance does not know the package's root, so `src/my/mod.gleam` is sent as
  `mod`.
- Symbols (N5) are sent in the BEAM's spelling and are not escaped at all.

## Extending this sender

### Add a construct mapping

1. Find the section of `codex.gleam` for the construct's family; the sections are in the contract's order
   (forms 9.3, node tables and their types, statements, patterns, expressions: literals and data H1 to H15, names
   and control H16 to H37, calls, processes H20 to H26, `gleam_otp`, operators Appendix B, literals).
2. Add a case to the function that reads that piece of glance's syntax tree: `expression` for an expression,
   `pattern` for a pattern, `sequence` for a statement, `types.resolve` or its `library` for a type,
   `library_process` or `otp_actor` for a library call, `kind` for an `@external`.
3. Write children first, then the node, with `emit(builder, location, frame.Kind(_, …))`: `emit` gives the node
   its index and its location, so T9.2 (children before parents) and T9.3 hold by construction.
4. **State its type** (next subsection): wrap the `emit` in `typed(…, the_type)`.
5. A node kind this sender has not sent before needs three lines: the variant in `frame.gleam` (`Node` or
   `TypeNode`), its children in `frame.children`, its term in `wire.gleam`. The shape is the schema's
   (`../contract/tcp_transport_v1.silica`); do not invent one.
6. Add a test at the end of `test/gleam_to_silica_poc_test.gleam`, like its neighbours: a source snippet in,
   the expected nodes out (`function_nodes`, which also runs every frame through the contract's checker), and the
   hints that matter (`function_hints` and `hint_type`, which gives a node's stated type in words).

### Change what is split (`src/gleam_to_silica_poc/split.gleam`)

`split.functions` takes the functions of a module (glance's syntax) and answers them with every receive, and
every call of a function that receives, in tail position, and `made`: what each function it made is made from.
It knows no types. `codex.split_module` calls it before anything is typed; `codex.settle_made` then types the
functions it made.

- **Which functions wait** (`blocking`, `blocks`): a function with a `process.receive` or
  `process.receive_forever` (`receive_call`: add another waiting library call there), or one that calls such a
  function by name, outside a closure. Only these are touched.
- **Where a body is cut** (`split_body`, `shape`, `cuttable`): at the first statement that waits and is
  `let p = B` or `B`, with `B` a receive, a call of a function that waits, a `case` or a block.
- **A receive that is an operand** (`hoist`, `inner`): which positions of an expression are evaluated first, so
  that the receive can be bound to `_h<n>` before its statement. To allow another position (a list element, a
  record field), add it there; a position `hoist` does not know ends in `gap`.
- **What a value does at the end of a body** (`wrap_last`, `pass`): `Kont(name, arguments, uses_value)` is the
  continuation call. A receive becomes `_split_receive(subject, within, then)`, where `then` is that call with
  the variable `_received` for the receive's value; `codex.receive_` writes the `(:receive)` and
  `codex.received_value` the value. A new kind of ending is a new case in `wrap_last` and in `copy`.
- **What a waiting process keeps** (`split_tail`): the rule that puts a receive in a function of its own, and
  the one that keeps it in a public function. `Split.unexported` lists the public functions that wait only in a
  function they call; the codex sends them as not exported.
- **What is not sent** (`reached`): private functions that wait and that nothing calls after the split.
- In the codex: `message_shape` and `message_clauses` say how a message of a type is sent and received
  (contract T9.12); `fname` spells a made function's name (N6); `io_print` and `print_pieces` lower `io.println`
  (add a printable piece there, and its Silica builtin to contract T9.16 and the transpiler first);
  `actor_start` and `actor_loop_form` are the `gleam_otp` actor.
- Add a test at the end of `test/gleam_to_silica_poc_test.gleam` (the `split_…_test` functions: a snippet, the
  names of the functions sent for it, and their nodes and signature hints).

### State a type for a construct

The typing pass is not a separate walk: it runs while the nodes are written.

- Every function that writes an expression takes `expected`, the type the expression's place gives it (`any` when
  the place says nothing), and returns the node's index and the builder. The builder holds the type of every node
  written so far (`ty_of(builder, index)`) and the form's hints.
- `typed(emit(builder, at, frame.Call(…)), ty)` records the node's type and, if the type can be stated and the
  node is of a kind T8.9 does not fix, adds an `inferred` hint for it. `typed_as(…, ty, Proven)` is for a type that
  is literally an annotation. `hint(builder, index, ty, strength)` adds a hint to any node (the variables of a
  pattern are hinted this way).
- Compute `ty` from the children: `ty_of(builder, child)`. For a call, `result_type(params, result, argument_types,
  name)` fills the declaration's type variables from the arguments. Pass each child the type its place gives it
  (`expr(child, scope, wanted, builder)`): a child the codex has no type for adopts it (`adopt`).
- When the type cannot be worked out, give `typed` a `TyUnknown("why, in words")`. Do not decide there whether
  that is a gap: the places that **require** a type decide it (`sequence` for statements, `let_`, `case_`, `lambda`,
  `send`, `field_access`, `binary` for `==`, `function_form`), each by keeping the builder from before the construct
  (`let start = builder`) and writing `gap(start, at, construct, types.reason(ty) <> ", so … (T8.10 x)")` in its
  place, which throws the untyped nodes away.
- A new type of another module: a variant in `types.Ty`, a case in `types.library` (annotation to `Ty`) and one in
  `types.intern` (`Ty` to the entries that describe **the value this codex sends** for it). A function of another
  module whose types are known: a line in `types.library_signature`.
- A pattern takes the type of what it is matched with: `pattern(p, ty, strength, builder)`. A new pattern kind
  hands each sub-pattern its part of `ty`, and calls `binding` for a variable (which hints it and adds it to
  `builder.bound`) or `trouble` for something that cannot be sent (the `let` or `case` then becomes the gap).

### Where guards are inserted

`division` in `codex.gleam` (reached from `binary` for `/`, `%` and `/.`) writes the division-by-zero guard, and
`once` binds an operand that must be evaluated exactly once. A new construct whose Gleam semantics differ from the
Silica operator's at an edge (T8.15) gets its guard the same way: desugar to existing nodes (`match`, `block`,
`case`, `op`), name any variable `_<what>_<builder.next>` so it cannot clash, state the type of every node written,
and add a row to the table in "Types" and a test.

### Change what is read of a supervisor (`sup.gleam`) or which `fn` is lifted (`lift.gleam`)

Both are passes over glance's syntax that run before the split (`codex.split_module`: `sup`, then `lift`, then
`split`), so what they make is typed and sent like source.

- **A supervisor.** `sup.started` says which statement is a start (`let assert Ok(_) = E`); `supervisor`,
  `child`, `actor` and `actor_builder` read the pipeline, each answering `Error("why")` for what it does not
  read: that text becomes the gap's note, so write it for the programmer and name the rule. What is read becomes
  the mark `_static_child("restart", "strategy", state, handler)`, which `codex.static_child` turns into the
  `register`, the `spawn` and its A4.4 override. To carry more (another kind of child, a state with fields),
  read it in `sup.gleam` and write the node in `static_child`; the contract's static child takes literal
  arguments only (T9.14b), so anything else needs a contract rule first.
- **A name.** `codex.name_statements` finds the `let n: Name(M) = process.new_name("literal")` statements,
  `environment` keeps the ones that are unique (`resolver.names`), `types.library` reads `Name(M)` as
  `TyName(M, literal)`, and `library_process` writes `new_name`, `named_subject` and the `send_named`.
- **A lifted `fn`.** `lift.lifted` decides for the arguments of one call (the callee must be a function of the
  module with a declared function type at that place), `lift.as_fn` what counts as a function literal, and
  `lift.one` whether it captures (`outer`, `bound`) and what function it becomes.
- Add a test at the end of `test/gleam_to_silica_poc_test.gleam` (`static_supervisor_test`,
  `unreadable_supervisor_test`, `lift_test` are the patterns), and for a new kind of gap a function in
  `test/fixtures/gaps.gleam`.

### Emit a gap

`gap(builder, location, construct, note)` writes a `gap_node` (H40); `frame.Gap(…)` is a whole form. Say in
`construct` what the programmer wrote (`gleam/otp/actor.named/2`) and in `note` why it is not translated. A gap
is the honest answer whenever a mapping would not be exact (T9.10): the program still translates and runs until
it reaches the gap. A gap for a missing type says which type, why, and which rule of T8.10 asks for it. In a
pattern use `trouble` instead of `gap`.

### Names

Every name goes through `names.gleam` (rules N1 to N5 above): `names.ident` for a function, variable or field
name, `names.symbol` for a constructor, `names.type_name` for a type. Change a rule there, and in the other two
senders. A function the codex makes up is named `<something>` + `names.generated` (`__g`) + a number.

### Run the tests

```sh
test/run_test.sh            # offline and loopback
test/run_test.sh 7411       # also check-mode sessions with the transpiler on that port
```

### Run check mode and transpile mode

```sh
gleam run -- --dump examples/actors.gleam                        # the frames, nothing sent
gleam run -- --port 7411 examples/actors.gleam                   # check mode (contract 6.5)
gleam run -- --port 7411 --mode transpile examples/actors.gleam  # transpile mode; prints the session id
```

### Release a session

A finished transpile session keeps the transpiler's storage until it is released (contract 6.6); until then
another transpile session is refused `busy`. After the output has been exported:

```sh
gleam run -- --port 7411 --release intake_1:42
```

prints `released: session intake_1:42, freed true` (exit status 0), or `freed false` when the session is unknown or not
finished (1), or `release failed: …` when there was no answer (1). From Gleam: `sender.release(port, session)`.
