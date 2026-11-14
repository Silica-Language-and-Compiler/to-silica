# How to write a sender: a guide for language creators

**Status: 2026-11-13. A guide, not a contract.** The contract is
[contract/tcp-transport-v1.md](contract/tcp-transport-v1.md) (rule ids `T…`, `H…`, `M…`, `R…`) and its normative
schema [contract/tcp_transport_v1.silica](contract/tcp_transport_v1.silica). Where this guide and the contract
differ, the contract is right. This guide is written to be given to an LLM together with the contract: it is ordered
as the work is ordered, and every step names the rule it rests on.

You own a language. You want its programs to run as Silica. You write one program, a **sender**, in any language you
like. It parses your source, turns each module into the contract's frames and sends them over TCP to the
**transpiler** (`silica-sink/`, a Silica application), which checks, stores and prints Silica source. Three
proof-of-concept senders exist as templates: [erlang-to-silica-poc/](erlang-to-silica-poc/),
[elixir-to-silica-poc/](elixir-to-silica-poc/), [gleam-to-silica-poc/](gleam-to-silica-poc/). Each README has an
"Extending this sender" section and each test suite has one small test per mapping.

## 0. Where things are

| You need | It is in |
| --- | --- |
| a template for your sender | the nearest PoC: [erlang-to-silica-poc/](erlang-to-silica-poc/) (`src/e2s_codex.erl`), [elixir-to-silica-poc/](elixir-to-silica-poc/) (`lib/e2s/codex.ex`), [gleam-to-silica-poc/](gleam-to-silica-poc/) (`src/gleam_to_silica_poc/codex.gleam`) |
| the parts that lower language semantics | `split` (code around a `receive`, section 6a), `sup` (static supervisor), `lift` (a `fn` that captures nothing, Elixir and Gleam), in the same directory as the codex |
| programs that are converted | `examples/demo.*` and `examples/actors.*` in each PoC; what a PoC cannot convert is in `test/fixtures/` |
| how to run a PoC and its tests | its `README.md` (quick start, "How to test", "Extending this sender") |
| the rules | [contract/tcp-transport-v1.md](contract/tcp-transport-v1.md); schema [contract/tcp_transport_v1.silica](contract/tcp_transport_v1.silica) |
| a worked session, and 23 recorded ones | [contract/examples/](contract/examples/), [contract/goldens/](contract/goldens/) (`INDEX.txt` lists them) |
| a running transpiler to send to | build it: [silica-sink/build.sh](silica-sink/build.sh) (about six minutes); status in [silica-sink/STATUS.md](silica-sink/STATUS.md) |
| a place for your released transpiler | `<language>-to-silica/` (for example `elixir-to-silica/`); a proof of concept is `<language>-to-silica-poc/` |
| gaps already found, per language | [SENDER_GAPS_STATUS.md](SENDER_GAPS_STATUS.md), [APP_GAPS.md](APP_GAPS.md) |
| a map of the whole repository | [README.md](README.md) |

A good route: read sections 1 and 2, copy the nearest PoC, get one function through check mode (section 4), then
work through section 6 construct by construct, with the PoC's tests as the pattern (section 10).

## 1. Who does what

| You (the language side) | The transpiler |
| --- | --- |
| parse, expand macros, type-check: nothing is sent unless your own compiler accepted the program | decodes and validates every frame with the schema's own decoders |
| the **inbound codex**: source constructs to the contract's nodes (§9 of the contract) | stores the frames, then prints Silica |
| **every data type** and **every numeric conversion** (section 2) | prints the types and conversions you sent; **infers nothing, converts nothing** |
| your language's semantics at the edges: division by zero, overflow, equality between kinds | writes the operator and nothing around it |
| **your language's control flow and process semantics**: what runs before and after a receive, what a waiting process keeps, links, output formatting (section 6a) | prints a receive in tail position, a tail call, a print builtin: **splits nothing, lowers nothing language-specific**; says which construct, where, and what to send instead |
| which lowering each process construct gets (contract §7) | BEES's mechanical rules (contract §1) |
| what you cannot translate: you say so, as a gap (section 8) | a failing stub for each gap, and a diagnostic |
| names that are valid Silica identifiers (section 9) | reports a name it cannot print |

## 2. You decide the types

**This is the rule most senders get wrong first, so it comes first** (contract §8.6, T8.8 to T8.15; decided
2026-11-13).

> The language side decides all data types. The transpiler never infers a type and never converts a value
> implicitly. It prints what it is told, and where a type or a conversion it needs is missing, or the typing you
> sent disagrees with itself, it reports a diagnostic with your file and line and does not write the function.

What that means for your codex:

1. **Run your own typing pass before you emit nodes.** Use everything your language gives you: annotations, specs,
   your type checker's output, the rules of your operators. This is the only place where types are worked out.
2. **State each type with a hint** (contract §8.4): `{ node, type, strength, policy }`, where `type` indexes the
   form's own type table (§8.5). `strength` says where the type came from: `proven` (your type checker),
   `declared` (the programmer wrote it), `inferred` (your codex worked it out).
3. **Send each numeric conversion as an operator** (T8.12): `to_float`, `trunc`, `round`.
4. **Send your own guard** where your language's arithmetic differs from Silica's (T8.15).
5. **When you cannot know a type, send a gap** (section 8) that says which type is missing. Do not send the node
   untyped and hope.

### 2.1 What needs a stated type (T8.10)

| | What | How you state it |
| --- | --- | --- |
| a | every function | a hint on node `-1` whose type is `(:t_fun, [param types], result type)` |
| b | every local variable binding | a hint on the `(:var)` node in the pattern; or let the matched value's stated type carry over (a parameter, a hinted call) |
| c | every operand of an arithmetic or comparison operator | nothing for a literal or a typed variable; a hint on any other operand |
| d | every call result that is used (operand, bound, matched, dropped) | a hint on the `(:call)` or `(:apply)` node |
| e | every value the output must name a type for: a `case` subject, a matched value, a statement whose value is dropped, a list or record built in the middle of a body | a hint on that node |

What needs **no** hint, because the node itself or a type you already stated fixes it (T8.9): a literal; a variable
(its binding's type); a comparison or boolean operator (`boolean`); a conversion operator; an arithmetic operator
(the type of its operands); a tuple whose elements all have stated types; a field of a typed record; a body, which
has the function's result type. **A call never has a type of its own**: the transpiler does not look up the callee.
Hinting more nodes than required is always allowed (T9.7); a hint that contradicts what the node fixes is `T3103`.

### 2.2 No mixing (T8.11)

Both operands of `+ - * div rem /` and of every comparison must have **the same stated type**. `div` and `rem` take
integers. `/` takes floats and gives a float. An integer literal is an integer. Nothing is promoted for you.

### 2.3 Worked example: Erlang and Elixir, `/` on integers

```erlang
-spec mean(integer(), integer()) -> float().
mean(Sum, N) -> Sum / N.
```

In Erlang `/` always gives a float and accepts integers. Silica's `/` on two `int64` is integer division, and Silica
has no implicit conversion. So the codex, which knows both operands are integers, sends the conversion, and, because
Erlang's float division by zero fails the process while Silica's does not (contract Appendix B), its own guard:

```
types: 0 {t_int, i64}   1 {t_float, f64}   2 {t_fun, [0, 0], 1}
hints: {node -1, type 2, declared}
nodes:                                                       printed Silica (provisional printer; laid out here)
 0 {var, _, "Sum"}   1 {var, _, "N"}        patterns        fn mean(p0: int64, p1: int64) -> float64 {
 2 {var, _, "N"}  3 {op, _, "to_float", [2]}                    case (to_silica_i2f(p1) == 0.0) of {
 4 {float, _, "0.0"}  5 {op, _, "==", [3, 4]}                       true -> { _: int64 <- to_silica_gap(0); 0.0 };
 6 {boolean, _, true}  7 {symbol, _, "badarith"}                    false -> (to_silica_i2f(p0) / to_silica_i2f(p1))
 8 {fail, _, 7}  9 {clause, _, [6], -1, 8}                      }
10 {boolean, _, false}  11 {var, _, "Sum"}                  }
12 {op, _, "to_float", [11]}  13 {var, _, "N"}
14 {op, _, "to_float", [13]}  15 {op, _, "/", [12, 14]}
16 {clause, _, [10], -1, 15}  17 {'case', _, 5, [9, 16]}
18 {clause, _, [0, 1], -1, 17}
```

The same holds for `F * N` with a float and an integer (send `F * to_float(N)`), for `1 + 1.5` (send the literal as
`(:float, "1.0")`), and for `A == F` (convert the integer side). `=:=` between an integer and a float is `false`
whatever the values: send `(:boolean, false)`.

Sending `{op, _, "/", [Sum, N]}` with two integer operands gets you:

```
T3103 error demo.erl:2:14  the operator / at node 4: its operands have the type int64, and / takes floats
      (contract Appendix B, T8.11): for an integer division send div; for a float division of integers send
      to_float on each operand (T8.12)
```

### 2.4 Worked example: Gleam, separate operators and division by zero

```gleam
pub fn mean(sum: Float, n: Int) -> Float { sum /. int.to_float(n) }
pub fn half(n: Int) -> Int { n / 2 }
pub fn share(total: Int, people: Int) -> Int { total / people }
```

Gleam never mixes `Int` and `Float` in one operator, so there is nothing implicit to convert. Three things are still
the codex's job:

- **The operator spelling is a type statement.** `+` and `+.` both become the contract's `+`; the operands of `+.`
  are floats and the codex says so (a hint on any operand that is not a literal or a typed variable).
- **Conversions are your standard library's functions**: `int.to_float(n)` is sent as `(:op, "to_float", [n])`,
  `float.truncate` as `trunc`, `float.round` as `round`. They are not sent as calls.
- **Gleam defines division by zero as zero; Silica ends the actor** (integers) or gives an unusable value (floats).
  So `total / people` is sent as a `(:case)` on `people == 0` giving `0`, else `total div people`. `n / 2` needs no
  guard: the divisor is a literal that is not zero.

### 2.5 Local bindings and calls

```erlang
-spec area(integer()) -> integer().
area(R) -> S = square(R), S * 3.
```

`square(R)` is a call: it has no type until you state one. Your codex looks up `square/1`'s `-spec` (you have the
whole module; the transpiler has one form at a time) and puts a hint on the `(:var)` `S` of the match, or on the
`(:call)` node; either is enough for the binding (T8.10 b). Without it:

```
T3101 error demo.erl:2:12  the binding of the variable S to a (:call) at node 1: no type is stated for it
      (contract T8.10 b): the sender must state it with a hint; the transpiler infers no type
```

If `square/1` has no spec and your language gives you no other way to know its result, send the function as a gap
that says so (section 8). A `T3101` from the transpiler means your codex has a bug.

### 2.6 Declared types

A record, struct, custom type or alias is sent as a `(:type)` form and named with `(:t_named, name, args)`
(T8.14). **Send the `(:type)` form before every form that names it**: all of a module's type forms first, and a
module before the modules that use its types. Silica has no type names, so the transpiler writes the type out at
each use; a type that names itself cannot be written out (limitation observed) and is reported `T4002`. A type
parameter is `(:t_var, name)` inside the declaration and an entry of `args` at each use; a generic *function* has
to be specialised by you (T8.7).

### 2.7 The diagnostics you will meet (T8.13)

| Code | Your codex … |
| --- | --- |
| `T3101` | … left out a type T8.10 requires. The message names the node and the letter (a to e) |
| `T3102` | … sent an operator whose two operands have different types, with no conversion |
| `T3103` | … sent typing that contradicts itself: a hint against a literal, `/` on integers, `to_float` on a float, a signature hint with the wrong number of parameters |
| `T3104` | … named a declared type that no earlier `(:type)` form declares, or with the wrong number of arguments |

Each has severity `:error`, your file, line and column (from the node's location, T9.3), and the function is not
written (a failing stub takes its place when its signature can be written). They are reported in **transpile mode**;
check mode validates shapes only (section 10).

## 3. Connect and frame

- TCP to `127.0.0.1`, port 7411 by default (T3.1). No authentication, no encryption (T3.2).
- Every message, both ways: a 4-byte big-endian length, then one ETF term as Erlang's `term_to_binary/1` writes it
  (T4.1, T4.2; Appendix A lists the tags). A BEAM language uses `{packet, 4}` and `term_to_binary`. Any other
  language needs a small ETF encoder and decoder for that subset.
- Identifiers of **your** program (module, function, variable, field names, symbols) are binaries, never atoms
  (T4.4). Atoms appear only where the contract writes one. Records are maps with atom keys, every field present
  (T4.5).

## 4. A first session, in check mode

Check mode (contract §6.5) validates every frame exactly as production does and stores nothing. Start there.

```
you                                              transpiler
(:hello, { contract: 1, session: "", sender, options: { …, run: { mode: :check, max_frame } } })
                                                 (:welcome, { session, …, flow: { resume_from: 0, credit: 64, max_frame } })
(:unit_begin, { seq: 0, unit_name: "demo", silica_unit: "erl_demo", source: "demo.erl" })
(:form,       { seq: 1, unit_name: "demo", body: (:function, …) })
(:unit_end,   { seq: 2, unit_name: "demo", forms: 1 })
(:end,        { seq: 3, units: 1 })
                                                 (:result, { status: :ok, counts: { units: 1, gaps: 0, rejected: 0 }, session, files: 0 })
```

- The hello's `choices` must hold exactly one choice for each BEES requirement in a `:bees` session (T7.1; the table
  is in contract §7.2). Copy the hello of `contract/examples/add_example.erl` and change `sender`.
- `seq` numbers `unit_begin`, `form`, `unit_end`, `end` from 0 with no holes (T5.1). A rejected frame uses its
  `seq`; go on with the next number (T5.1a).
- `forms` and `units` are counts of what you sent (T5.3b). A wrong count is a `T1002` diagnostic, not a rejection.
- The complete worked session, frame by frame, is contract §12 and `contract/examples/add_example.erl`.

## 5. Credit: read while you send

You may send only while you hold credit (T6.2). The welcome gives 64. Each time half of the window is used the
transpiler sends `(:credit, 32)`, in transpile mode after `(:stored, next)` (T6.3). **A sender that writes all its
frames and only then reads will stop after 64 frames.** Keep a counter: subtract one for each frame sent, add `n`
for each `(:credit, n)`, and when it is zero read until credit arrives. `(:rejected, …)`, `(:stored, …)`,
`(:diagnostic, …)` and `(:progress, …)` can arrive at any time between your frames; `(:result, …)` ends the session.

## 6. Build up the constructs

Add one construct at a time, each with a test (source snippet in, expected nodes out), and send each through check
mode. A workable order:

1. Functions over literals, variables, operators and local calls (H1 to H6, H16, H29, H31, H32), with the signature
   hint and the typing pass of section 2.
2. Matching and control: `(:match)`, `(:block)`, `(:case)`, `(:cond)`, tuples, patterns (H8, H17 to H19, H28, H30).
3. Declared types and records (`(:type)` forms, `(:t_named)`, H12, H13); lists (H7, H9, H10).
4. Closures and function values (H33 to H36).
5. Processes and messages (H20 to H27, H38, H39), with the lowering choices of contract §7. **Read contract §9.4a
   first**: it says what the first printer writes for a process (a receive in tail position of its function,
   messages that are symbols or tagged tuples with a `(:t_tagged)` hint, a spawn of a function of the same unit)
   and what it reports instead (links, an exit request whose reason is not a symbol, a receive with code of the same function after it:
   **that one is yours to split, section 6a**). A type
   test in a receive clause's guard is a type you state, not a guard you send (contract T8.16).
   Three things the examples met when they were run (silica-sink/STATUS.md, "The examples, run"):
   **the value of a `(:send)` is the message** (H22), so a language whose send gives something else (Gleam's
   `Nil`) sends `(:block, [send, that value])` where the value is used; **a tag has one type in a unit**
   (T9.12): `{reply, {ok, N}}` and `{reply, {Text, N, F}}` in one unit are two types for the tag `reply`, they
   are written, the unit compiles, and the program faults when such a message arrives (nothing checks it yet),
   so give each reply its own tag; and **a send to a process that has ended ends the sender** under the usual
   `a5_4 accept_sender_death`, where your language may do nothing.
6. The entry point: an `(:entry)` form naming the function the program starts in (T9.6).

### 6a. You own language semantics such as receive continuations

**The transpiler prints what it is told. It does not know what your language does around a receive, a link or a
format string, and it will not learn it** (contract §1 "What you own", T9.13a, T9.16; decided 2026-11-13). This
is the same rule as section 2: there the transpiler infers no type, here it infers no control flow. When it meets
a shape it does not print it answers with a diagnostic that names the construct and its place and says what to
send instead; it never rearranges your program.

The first place every actor language meets this is **a receive that is not the last thing its function does**.
The transpiler writes a `(:receive)` only in tail position of its function, each clause ending in a value or in a
tail call (T9.13). It keeps the waiting process's variables and runs the clause the message matches; that is
all. Erlang (and Elixir, and anything that receives in the middle of a function) means more than that:

| What the language means | Who does it | How |
| --- | --- | --- |
| the code before the receive runs once, when the process starts, in the new process (`self()` is the new process; it may send the request whose answer the receive waits for) | nobody: the shape already means it | leave the code before the `(:receive)`. The spawner sends the new process its start message right after the spawn, and the process runs to its first receive (T9.14) |
| the code after the receive runs in the same process, with the variables it had and the receive's value | **you** | send that code as a function of its own (a continuation) whose parameters are those variables and the value; end each clause of the receive with a tail `(:call)` of it |
| the process may receive again, and again | **you** | one continuation for each receive |
| a function that receives is called, and the caller goes on with its result | **you** | the callee cannot return to a process that is waiting: send a copy of the callee whose every end is a tail call of the caller's continuation |
| what the process remembers while it waits | **you** | the printer keeps every variable bound at the receive. To keep only what is needed, make the receive the whole body of a function whose parameters are the variables it uses |
| the process ends when the function returns | nobody | a value in tail position ends the process (T9.13) |
| a message no clause takes stays in the mailbox (selective receive) | **not kept** (T9.13): it is dropped, and a split function gets the warning `T4004` | say so in your documentation |

**Erlang, worked.** This function of `erlang-to-silica-poc/examples/actors.erl` has two receives and two calls
of a function that receives (`ask/1`), each with code after it:

```erlang
main() ->
    spawn(actors, supervisor, [self(), 0]),                          %% before the first receive
    Counter = receive {child, Pid} when is_pid(Pid) -> Pid end,      %% a receive, then more code
    Counter ! {add, 2},
    Counter ! {add, 5},
    {Total, Adds, Mean} = ask(Counter),                              %% a call that receives, then more code
    io:format("total ~p after ~p adds, mean ~p: ~p~n", [Total, Adds, Mean, describe(Total)]),
    ...
```

Sent as written, `main/0` came back as a failing stub: `T4002 … (:receive) at node 9 is not printed: a receive
is printed only in tail position of its function … THE SENDER MUST SPLIT THE FUNCTION AT THIS RECEIVE (contract
T9.13a)`. The Erlang sender now sends these functions instead (it rewrites its own abstract forms first, in
`erlang-to-silica-poc/src/e2s_split.erl`, and then sends the result with the ordinary nodes):

```erlang
main() ->
    spawn(actors, supervisor, [self(), 0]),
    receive {child, Pid} when is_pid(Pid) -> main__k1(Pid) end.      %% tail position; the clause goes on in k1

main__k1(Counter) ->                                                 %% the continuation: its parameter is the value
    Counter ! {add, 2},
    Counter ! {add, 5},
    ask__c1(Counter, Counter).                                       %% a copy of ask/1 that goes on in main__k2

ask__c1(Counter, K) ->                                               %% K: the variable main__k2 needs
    Counter ! {get, self()},
    ask__c1__k1(K).

ask__c1__k1(K) ->                                                    %% the receive alone: it keeps only K
    receive
        {tally, Total, Adds, Mean} when is_integer(Total), is_integer(Adds), is_float(Mean) ->
            main__k2(K, {Total, Adds, Mean})
    after 5000 -> exit(no_answer)
    end.

main__k2(Counter, V) ->
    {Total, Adds, Mean} = V,
    io:format(...),                                                  %% see below
    ...
```

Each of these is an ordinary `(:function)` form with a signature hint; the continuations' parameter types are
the types of the arguments they are called with, which the sender knows because it decides every type. The
transpiler writes them as the phases of one process, and the program prints what the Erlang program prints
(`silica-sink/STATUS.md`).

The same rule covers what else the examples needed, and it will cover what your language needs:

- **Links and trapped exits.** The contract has no node for trapping exits and the transpiler writes no link
  (T9.15). The Erlang sender sends `process_flag(trap_exit, true)` followed by `spawn_link(fun() -> g(…) end)` as
  an unlinked spawn of a copy of `g` that sends its parent `{'EXIT', self(), normal}` when it ends, and types the
  parent's receive of that message itself. It documents what that does not keep (a failure the runtime raises
  sends nothing; the link's other direction).
- **Output.** `io:format("total ~p~n", [N])` is Erlang's formatting language. The sender parses the format and
  sends one low-level `(:sl_call)` of a Silica print builtin for each piece (T9.16: `print`, `print_int64`,
  `print_float64`, `print_boolean`, `atom_name`). A `(:call)` of `io:format` is a call to a module the session
  does not have and is not written.
- **Pattern details.** A record pattern with a literal field (`#tally{adds = 0}`) is sent as the field bound to a
  variable and compared in the clause's guard; a variable that already has a value in a message pattern is sent
  as a new variable and a comparison in the guard (the printer binds every pattern variable anew).

- **A supervisor with a static child list** (2026-11-14; contract T9.14b). Your language's supervisor (its
  callback module, its child specifications, its start functions, its defaults) is yours to read; the transpiler
  knows none of it. What it prints is a **static child**: a `(:register, name, process)` whose `process` is a
  `(:spawn)` of a function of the unit with **literal** arguments. That child is in the list the unit's supervisor
  has from its start, registered under `name`; an `a4_4` override on the `(:spawn)` (T7.6) carries the restart
  policy and the strategy **your source writes** for it (do not put a restart default of your own there: take what
  the child specification says, and your language's default where it says nothing). Send one such node for each
  child where your source starts the supervisor, and `(:send_named)` where it sends to the child's name (T9.14c).
  The Erlang sender does this in `src/e2s_sup.erl` (it evaluates `init/1` itself, reads each child's start
  function, and sends neither as a function), and its README, "A static supervisor", lists what that does not
  keep: the children exist from the program's start, the supervisor is no process of the output, a strategy other
  than the session's and the restart intensity are not carried. The Elixir sender does the same for
  `use Supervisor` in `lib/e2s/sup.ex`: it **reads** `init/1` as data and runs nothing (literal bindings, then
  `Supervisor.init(children, strategy: …)`; a child as a map or as `{Module, argument}` with a `child_spec/1`),
  and when it cannot read a supervisor the gap's note says which rule the source missed. Either way works; what
  matters is that the child list is known when you send. A supervisor whose children are added while the
  program runs is an ordinary `(:spawn)` (T9.14); one you cannot read is a gap. The Gleam sender
  (`src/gleam_to_silica_poc/sup.gleam`) reads `gleam_otp`'s `static_supervisor.new(strategy) |> add(worker) |>
  start` pipeline the same way, and meets one thing the other two do not: **a name made when the program runs**
  (`process.new_name(prefix)`), where the contract takes a literal. It reads the name where it is made
  (`let n: Name(M) = process.new_name("literal")`), allows one name for a message type in a unit, and so knows
  the literal of every `Name(M)` value by its type; a send to `process.named_subject(n)` is then a
  `(:send_named)`, and a named subject passed on as a value is a gap (its README, "A static supervisor").
- **A function literal that captures nothing** (2026-11-14; contract H36, "as built"). The transpiler writes a
  `(:lambda)` only as the function of a `(:spawn)`; anywhere else it answers `T4002`, because it has no lowering
  for a closure. A literal that uses no variable of the function around it is no closure: send it as a
  `(:function)` form of its own, not exported, and a `(:fun_ref)` where it stands. You need a signature for the
  made function (T8.10 a): the Elixir sender (`lib/e2s/lift.ex`) lifts a `fn` only where it is the argument of a
  function of the module whose `@spec` declares the function type, and copies that type; a real closure it
  still sends as a `(:lambda)`, and keeps closures out of its example. The Gleam sender does the same
  (`src/gleam_to_silica_poc/lift.gleam`: the declared parameter type of the called function), also for a
  capture whose other arguments are literals (`add(2, _)`).
- **An exported function that waits must hold its receive** (2026-11-14, met by the Gleam sender). The
  transpiler writes an exported function that has a tail call also as an ordinary function, and when that
  ordinary version reaches a process function it reports it (`T4002` on the unit, T9.13): a gap. So when you
  split an exported function, leave its first receive in it (it is then a process function, exported and
  spawnable); and an exported function that waits only in a function it calls (Gleam's `pub fn main` whose
  first wait is `ask(counter)`) send as **not exported**: its ordinary version could only fail, and the entry
  form names the entry whatever it exports (T9.6). Say so in your documentation.
- **An example program is no test of the gaps** (2026-11-14). The examples of the three senders now hold only
  what is transpiled with no gap (result `ok`, `counts.gaps` 0), so that a reader can run them in both worlds
  and compare call by call; what a sender answers with a gap lives in its tests (Elixir:
  `test/fixtures/gaps.ex`; Gleam: `test/fixtures/gaps.gleam`). When you compare outputs, read floats as numbers: Silica's `print_float64` writes at
  most 15 decimal places, cut and not rounded, and there is no shortest round-trip form (limitation observed).

**The other two senders, and what they add to the picture** (2026-11-14; each has the same section in its
README, and `silica-sink/STATUS.md` has the runs):

- **Your language's scoping decides which variables a continuation gets.** In Erlang a variable bound in every
  branch of a receive is bound after it; in Elixir a binding made inside a clause ends with the clause, and
  `x = receive … end` binds `x` anew whatever `x` was. The Elixir sender (`lib/e2s/split.ex`, on the quoted
  forms) passes on what is bound at the top of the function body, and the value under the name it is bound to.
- **A receive, or a call of a function that receives, as an argument** (`IO.inspect(withdraw_from(a, 100))`,
  `case get() do`, a pipe stage) has no shape of its own: bind its value first, then cut. Do it only where your
  language evaluates nothing with an effect before it (the Elixir and Gleam senders require that everything
  before it is a variable or a literal); otherwise send a gap that says to bind it by hand.
- **A language whose receive is a library call** (Gleam's `process.receive(subject, within)`) splits the same
  way: the call's value is the continuation's last parameter, the timeout is the receive's `after`. A typed
  language has its message types: send a message of a variant type as it is and give the receive one clause for
  each variant; wrap any other message type (a record, a tuple, a number) in a tagged tuple of your own, one tag
  for each type (T9.12). What the library selects by (a subject's reference) is not kept: say so.
- **A library's behaviour is yours too** (contract 9.2). The Gleam sender sends
  `actor.new(s) |> actor.on_message(h) |> actor.start` as a spawn of a loop function it writes: a tail-position
  receive that calls the handler by name and goes on in itself. A static supervisor of named actors it sends as
  static children (above, "A supervisor with a static child list"); what it cannot send honestly (an
  initialiser, a selector, a supervisor it cannot read) it keeps as gaps with the reason.
- **Output is chosen by the stated type.** A language that prints "a term" (`IO.inspect`) sends the punctuation
  as `print` calls and each scalar with the builtin of its type; a tuple is taken apart by a `(:match)` or a
  `(:case)`, a union by a `(:case)` over its alternatives; a value whose type you cannot state, or one that has
  no text you can write (a pid, a struct, a closure), is a gap. A language that prints concatenated text
  (`io.println(a <> int.to_string(n))`) sends one print for each part of the concatenation.
- **The made functions' types are fixed by iteration.** A continuation is called by a copy, which is called by
  another continuation: type the unit until the argument types of the calls of your made functions no longer
  change (one round types them one call further from a source function, so allow as many rounds as you made
  functions). A parameter that different calls give different types is their union. If a made function ends
  without a type, send it as a gap form **and each call of it as a gap node**: a call of a function that was
  sent as a gap form is written as a call of a function that does not exist.
- **Make your split a program of your own language, and test it there.** The senders rewrite their own syntax
  tree, so what the split makes can be compiled by the language itself: the Erlang and Elixir test suites run
  the split module in place of the original and compare what it prints. A wrong cut then fails before any
  transpiler is involved.
- **Two limits of what is printed that a split meets** (limitations observed, 2026-11-14,
  `silica-sink/STATUS.md`): a statement whose value is dropped, and the value a process function ends with,
  must not have a union type (write the value where it is used, or end the statement with a symbol); and an
  element of a message must not itself be a union (send the variants as messages of their own).

When you lower something yourself, **write down what your lowering does not keep** (the Erlang sender's README,
"Processes: what this sender splits", is the model), and when no lowering is honest, send a gap (section 8).
If the contract lacks a node you need, propose a rule; do not expect the transpiler to guess.

A form's code is a flat node table: children before parents, every child index smaller than its parent's (T9.1,
T9.2). Each node carries `at`, an index into the form's `locations` (line, column). **Give every node its real
location**: it is what the transpiler's diagnostics point at.

What the transpiler prints today is listed in [silica-sink/STATUS.md](silica-sink/STATUS.md). A construct that is
valid in the contract and not printed yet becomes a failing stub and a `T4002` diagnostic: that is the transpiler's
gap, not yours, and `counts.gaps` counts it (T6.8a).

## 7. Transpile, export, release, resume

- **Transpile mode**: the same frames with `run.mode` `:transpile`. Frames are stored; `(:stored, next)` says which
  are durable (T6.4). After `(:end)` come the diagnostics and one `(:result, …)`: `:ok` (everything written, no
  gap), `:partial`, or `:failed` (nothing written; `files` is 0, T6.8).
- **Session ids** are text such as `intake_1:42` (T6.5b). Treat them as opaque.
- **Export**: the output stays in the transpiler's storage (T6.9). Today `tools/export_debug_output.py` cuts the
  files out of the transpiler's debug output (provisional).
- **Release**: when the output is exported, open a new connection and send `(:release, { session })` as its only
  frame; the answer is `(:released, { session, freed })` (T6.13). A finished session holds a storage region until
  it is released, and a transpiler whose regions are all held refuses new sessions `:busy`.
- **Resume**: if the connection drops before the result, connect again and send the same hello with `session` set
  to the id. The welcome's `resume_from` is the first `seq` to send (T6.5, T6.5a). Do not wait for ever on a silent
  connection (T3.5).
- `(:abort, { reason })` gives a session up and frees its storage.

## 8. Gaps: say what you cannot translate

A construct your codex cannot translate, or cannot type, is sent, not left out (T9.10): a whole form as
`(:gap, { name, place: { file, line }, construct, note })`, or one node as `(:gap_node, at, construct, note)`. Write
`construct` and `note` for the person who will read the diagnostic: name the source construct and the reason
(`"local call helper/1 has no -spec, so its result type cannot be stated (T8.10 d)"`). The program still translates
and runs until it reaches the gap. `Result.counts.gaps` counts them, and each has a `T4001` diagnostic.

## 9. Names

Not decided by the contract yet; this is what the three senders do, and it is injective (two source names never
give one Silica name) and safe for several arities of one name.

- **Units** (T5.2): `silica_unit` is your prefix (`erl_`, `ex_`, `gl_`; BEES A1.1) and the module name in
  snake_case, `.` and `/` as `_`. It must be an identifier and unique in the session. `unit_name` stays as your
  users write it.
- **Functions and fields**: letters and digits are kept. `?` becomes `__q`, `!` becomes `__b`, any other character
  `__x<hex code point>_`. An underscore is kept, except one that touches another underscore or stands directly
  before an escaped character, which becomes `__x5f_`. An empty name is `__e`; a leading digit is escaped. So `__`
  appears only as the start of an escape and the name can be decoded.
- **Several arities of one name** (Erlang, Elixir): every arity of such a name is sent as `<name>__<arity>`; a name
  with one arity is unchanged.
- **Declared types** are named `<module>_<type>` in snake_case: a `(:t_named)` names a type of the whole session.
- **Reserved names are the transpiler's** (contract T9.11): a function whose name is a Silica reserved word or
  builtin (`move`, `send`, `concat`, …) or `main` is written with `__` appended (`move__`, `main__`), in its
  definition and in every call; send the name as it is. Do not send function names that start with `to_silica_`
  or end in `__spawn` or `__spawn_watched`. A record **field** named like a reserved word is still not written
  (`T4002`); the list belongs to one compiler version (`silica-sink/DECISION_DATA_printer.md` §3).

## 10. Test

1. **Unit tests of the codex**, offline: a source snippet in, the expected nodes, types and hints out. One per
   mapping; the three senders' test suites are the pattern.
2. **A binding's checker**, offline, if your language has one (`contract/bindings/erlang/check_frame.erl`).
3. **Check mode** against a running transpiler: shapes, indices, hints' indices, counts, profile. The session must
   end `:ok`.
4. **The golden sessions** (`contract/goldens/`, T11.1): the bytes of 23 sessions and the replies a transpiler
   gives. Replay them to test your reader of replies; `ok_types_stated` is a function typed as section 2 asks.
5. **Transpile mode**: this is where typing is judged (`T31xx`). Aim for no `T31xx` at all: each one is a bug in
   your codex. Then export and compile each unit with the Silica compiler.
6. Be deterministic: the same source and options give the same frames, byte for byte (contract §0).

## 11. Checklist

- [ ] no `(:receive)`, and no call of a function that receives, has code of the same function after it in what
      you send: you split the function (section 6a, T9.13a); output, links and the other semantics of your
      language are lowered by you to nodes the transpiler writes, or sent as gaps
- [ ] nothing is sent unless your own compiler accepted the source
- [ ] every function has a `(:t_fun)` hint on node `-1`
- [ ] every local binding, used call result, `case` subject and non-literal operand has a stated type
- [ ] the two operands of every arithmetic and comparison operator have one type
- [ ] every numeric conversion is a `to_float`, `trunc` or `round` operator
- [ ] division by zero and overflow behave as your language says, by guards you send, or the difference is documented
- [ ] every `(:type)` form is sent before the forms that name it
- [ ] what you cannot translate or cannot type is a gap with a readable reason
- [ ] you read replies while sending and never send without credit
- [ ] finished sessions are exported and then released
