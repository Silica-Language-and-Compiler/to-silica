# erlang-to-silica-poc

A proof of concept of the Erlang side of to-silica: an **inbound codex** and **TCP sender**, written in Erlang.
It parses Erlang source with Erlang's own parser (`epp`), maps the abstract forms to the frames of the
[to-silica TCP transport contract, version 1](../contract/tcp-transport-v1.md), and sends them to the transpiler
([../silica-sink](../silica-sink)). The transpiler does the rest (contract §1).

**The codex decides every type and every numeric conversion** (contract §8.6). The transpiler infers nothing and
converts nothing: this sender states the type of every value the contract asks a type for, writes a conversion
node wherever Erlang converts a number, and sends a gap, with the reason, where Erlang gives no type.

**The sender also owns Erlang's process semantics** (contract §1 "What you own", T9.13a). The transpiler writes a
receive only in tail position of its function and splits nothing; `src/e2s_split.erl` cuts every function at a
receive that has code after it, before anything is sent. See
[Processes: what this sender splits](#processes-what-this-sender-splits).

**And OTP's supervisor behaviour** (contract T9.14b). `src/e2s_sup.erl` reads a module with
`-behaviour(supervisor)`: its `init/1`, its child specifications and their start functions, and sends each
child as a **static child** of the unit's supervisor, with the restart policy and the strategy the source
writes. See [A static supervisor](#a-static-supervisor).

Status: proof of concept, 2026-11-13. Checked against the transpiler's check mode (contract §6.5), which validates
shapes, indices and hints. It is meant as a foundation to build on: see [Extending this sender](#extending-this-sender).

## Known deviations from Erlang (read this first)

These are places where the translated program does not behave as the Erlang program does, and the sender does
**not** send a guard for them. They are stated here because the contract leaves every arithmetic edge to the
language side (T8.15).

- **Integers are 64 bits.** Erlang's integers are unbounded; `integer()` is sent as `i64` (the contract's fallback,
  T8.7). An Erlang program whose `+`, `-`, `*` or `bsl` leaves the range −2^63 … 2^63−1 computes a big integer in
  Erlang and does something else in Silica (what Silica's integer overflow does was not measured, Appendix B).
  The sender sends **no overflow check**: guarding every `+`, `-` and `*` would triple the code of ordinary
  arithmetic, and no cheap honest check was found. An integer **literal** beyond 64 bits is a gap.
- **Float results that Erlang refuses.** Erlang fails (`badarith`) when a float operation overflows; a Silica float
  operation gives a value that is not a usable number instead (limitation observed for division by zero,
  Appendix B; overflow not measured). Only division by zero is guarded (below). `trunc/1` and `round/1` of a float
  outside the 64-bit range give a big integer in Erlang and are undefined here (T8.12).
- **`to_float` beyond 2^53.** Erlang compares an integer with a float exactly; the sender converts the integer
  (`to_float`), which is exact only up to 2^53 (T8.12).
- **A record field that is left out** of `#r{…}` takes its default in Erlang; the sender sends only the fields
  that are written.

- **Processes** (all of them in [Processes: what this sender splits](#processes-what-this-sender-splits)):
  selective receive is not kept (a message no clause of the waiting receive takes is dropped by the transpiler's
  lowering); a trapped exit is delivered only for an end the source writes; `io:format` prints floats as
  Silica's `print_float64` does (at most 15 decimal places, cut and not rounded).
- **A supervisor** ([A static supervisor](#a-static-supervisor)): its children exist from the program's start,
  not from the call of `supervisor:start_link`; the supervisor itself is no process (no pid, no stop, no
  `which_children`); `intensity` and `period` are not carried.

What **is** kept: `div`/`rem` by zero end the process in Erlang and in Silica (`badarith`; nothing is added), and
float `/` by zero, which fails in Erlang and not in Silica (limitation observed), is sent with an explicit guard.

## What it translates

| In the subset | Contract nodes |
| --- | --- |
| integers, characters, floats, atoms, `true`/`false`, `<<"bytes">>` literals | H1, H2, H5, H6, H4 |
| lists: `[]`, `[A, B]`, `[H \| T]`, in expressions and patterns; a string literal, as the list of character codes it is; `++` | H7, H10, H9, Appendix B |
| tuples; records: `#r{}` construction, update, field access, patterns | H8, H12, H13 |
| `-record` with typed fields, `-type` without parameters | §9.3 `:type` forms, sent before everything else of the unit (T8.14) |
| variables, `_`, `=` | H16, H17, H18 |
| an alias pattern, `P1 = P2` in a pattern | H18 in pattern position, both children patterns (see below) |
| functions with a `-spec`: clauses, patterns, guards (`,` and `;`), `begin … end` | §9.3 `:function`, H29, H19 |
| calls: local, `M:F(…)`, computed `M:F(…)`, calls through a fun | H32, H34, H33 |
| operators of the contract's Appendix B, with Erlang's conversions written out | H31, T8.12 |
| `float/1`, `trunc/1`, `round/1` | the conversion operators `to_float`, `trunc`, `round` |
| `case`, `if`, `fun … end`, `fun name/arity` | H28, H30, H36, H35 |
| `self()`, `spawn/1,3`, `spawn_link/1,3`, `!`, `receive … after … end`, `link/1`, `exit/1,2`, `error/1` | H20, H21, H22, H23, H24, H25, H26 |
| a receive with code after it, several receives in one function, a call of a function that receives with code after it | the same nodes, in functions the sender cuts the source function into (T9.13a) |
| `process_flag(trap_exit, true)` followed by `spawn_link` and a receive of `{'EXIT', Pid, Reason}` | an unlinked H21 of a linked copy of the child's function, which sends the message (T9.15) |
| `-behaviour(supervisor)`: `{ok, _} = supervisor:start_link(Name, ?MODULE, Args)`, with `init/1` and the children's start functions | for each child H38 `(:register)` of an unlinked H21 `(:spawn)` with literal arguments and an A4.4 override: a static child (T9.14b, T7.6) |
| `name ! Message` with a literal name | H39 `(:send_named)` (T9.14c) |
| `io:format/1,2` with a literal format of `~p ~w ~b ~s ~n ~~` | L1 `(:sl_call)` of Silica's print builtins (T9.16) |
| a literal in a record pattern, `f(#r{a = 0})` | the field as a variable and `=:=` in the clause's guard |

Everything else is sent as a **gap** (contract T9.10), so a session always completes: maps, bit syntax,
comprehensions, `try`/`catch`, `--`, `xor`, the other OTP behaviours (`gen_server`, …) and a supervisor this sender
cannot read, `register/2` outside a supervisor child's start function, `whereis/1`, `unregister/1`,
`process_flag/2` anywhere but as a statement
`process_flag(trap_exit, true)`, monitors, types with parameters, a receive inside an expression,
and **everything that reaches another node** (`{Name, Node} ! Msg`, `rpc`, `erpc`, `global`, `pg`, `node/0`,
`spawn/2,4` …): inter-node communication is outside the proofs of concept.

## Types and conversions

### Where the types come from

Erlang is dynamically typed, so the codex takes types only from what the program states, and never from how a
value is used:

| Source | Gives | Strength of the hint |
| --- | --- | --- |
| `-spec` | the function's signature; its parameters; the result of every call to it from a module of the session | `declared` |
| `-record` field types, `-type` | the type forms; the type of a field access, of a record construction | `declared` |
| a literal | its own type (the contract fixes it, T8.9: no hint) | none |
| what a variable is bound to: `X = E`, a `case` pattern | the variable's type, position by position through tuples, lists and records | that of `E` |
| Erlang's rules for operators and for the functions in the codex's table (`bif_type/3`: `length/1`, `abs/1`, `io:format/2`, …) | the result | `inferred` |
| a type-test guard: `{add, N} when is_integer(N)` | the type of a variable that a received message or a fun's parameter binds | `inferred` |
| the place a fun or a literal is passed to (a parameter of a `-spec`, a field) | a fun's parameter types; `ok` as `ok \| error`; `[]` as `[integer()]` | `inferred` |

A **received message has no declared type** in Erlang. A receive clause is typed by its pattern and by type-test
guards (`is_integer/1`, `is_float/1`, `is_atom/1`, `is_boolean/1`, `is_binary/1`, `is_pid/1`) on the variables it
binds; a clause that binds a variable with no such guard, or has `_` in its pattern, has no type, and the whole
`receive` is a gap. The examples are written with these guards.

**A type test that only states the type is not sent as a guard** (contract T8.16). `{add, N} when is_integer(N),
N > 0` is sent as the pattern `{add, N}` with the hint `(:t_tagged, add, [int])` and the guard `N > 0`: the test
`is_integer(N)` has become the type of `N`, and the transpiler knows no Erlang type test (a call to
`erlang:is_integer/1` would be a call it cannot write). A test is dropped only when the variable's stated type is
the tested type (`unstated/2` in the codex); a test on a variable of another stated type is sent as written.
For a receive clause this is what makes the clause printable: the transpiler takes the hint on the clause's
pattern as the type of the messages the clause takes (contract T9.12, T9.13).

### Erlang construct → types and conversions sent

| Erlang | Sent |
| --- | --- |
| `integer()` (and `non_neg_integer()`, `pos_integer()`, `char()`, `byte()`, ranges) | `t_int i64` |
| `float()` | `t_float f64` |
| `boolean()`; `atom()`; `ok \| error` | `t_basic boolean`; `t_basic symbol`; `t_symbols` |
| `binary()`; a `<<"…">>` literal | `t_basic bytes`; a `(:bytes)` node with that hint (never `(:text)`: Erlang has no text type) |
| `{A, B}`; `{tag, A}`; a tuple written with an atom first | `t_tuple`; `t_tagged`; a `(:tuple)` hinted `t_tagged` |
| `[T]`, `string()` | `t_list` |
| `#r{}`, a `-type t()` | `t_named` of the type form `<module>_<name>` |
| `A \| B` of different kinds | `t_union` (the atoms among the alternatives as one `t_symbols`) |
| `fun((A) -> B)`; `pid()` | `t_fun`; `t_actor` of `dynamic` (a pid says nothing about its messages) |
| `number()`, `term()`, `any()`, `map()`, a type variable, a type of another module, `no_return()` | **no type**: the function is a gap form |
| `A + B`, `A - B`, `A * B` | both integers: the operator. Either a float: the integer operand under `to_float`, or sent as a `(:float)` when it is a literal (`1 + F` → `1.0 + F`) |
| `A / B` | each integer operand under `to_float`; then `cond Divisor == 0.0 -> fail(badarith); true -> A / Divisor`. An operand that is not a variable or a literal is first bound to a variable of the codex (`E2s__t1`), so it is evaluated once and in Erlang's order. A literal divisor other than zero needs no guard |
| `A div B`, `A rem B` | integer operators, nothing added (both sides end the process on zero) |
| `==` `/=` `<` `=<` `>` `>=` | operands of one type: the operator. An integer and a float: `to_float` on the integer |
| `=:=` `=/=` | operands of one type: the operator. An integer and a float: `(:boolean, false)` or `true` (after the operands, when they are not variables or literals) |
| a comparison of two other different types (`A < atom`) | gap: Erlang orders all terms, Appendix B has no operator for it |
| `float(X)` | `to_float` when `X` is an integer; `X` itself when it is a float |
| `trunc(X)`, `round(X)` | the operator when `X` is a float; `X` itself when it is an integer |
| `-X`; `not`, `and`, `or`, `andalso`, `orelse`; `band` … | `neg` on an integer or a float; boolean operands only; integer operands only |
| `/`, `div`, `rem` in a guard (unless the divisor is a literal other than zero) | gap: a guard that fails is false in Erlang, and would end the process here |

Every `(:op)` node therefore has operands of one stated type (T8.11), and every node the contract requires a type
for (T8.10 a to e) has a hint: every variable binding, every operator, call, tuple, list, record, `case`, `if`,
`receive`, block, `=`, fun, `self()`, `spawn`.

### When there is no type: a gap that says so

Where the contract requires a type and Erlang gives none, the construct is sent as a gap whose note names the
missing type and the reason, never as an untyped node. The transpiler's `T3101`/`T3102`/`T3103` diagnostics should
therefore only ever point at a bug in this sender.

| Missing | Sent |
| --- | --- |
| a function without a `-spec`, with a `-spec` of several clauses or with `when`, or whose `-spec` has a type the codex cannot state | the whole function as a `(:gap)` form: `function f/1 has no -spec, so its signature type cannot be stated (T8.10 a)` |
| the result of a call to such a function, or into a module outside the session that is not in `bif_type/3`, where a type is required (an operand, a binding, a `case` subject, a dropped value) | a gap node in place of the operator, the `=`, the `case` or the statement: `… local call helper/1 has no -spec, so its result type cannot be stated (T8.10 d)` |
| a `receive` clause or a `fun` that binds a variable nothing types | the `receive` or the `fun` as a gap node |
| `[]` or a list whose element type nothing states; a record with an untyped field | a gap node (and a gap form for the `-record`) |
| a body whose value is not of the `-spec`'s result type (`-spec f() -> float(). f() -> 1.`) | a gap node: the codex states no type the code does not have |

A gap replaces the whole construct: what was built for it is not sent. A value that depends on a gap has no type
either, so the note of a later gap carries the first cause.

## Processes: what this sender splits

The transpiler prints a `(:receive)` only in tail position of its function, with each clause ending in a value or
in a tail call (contract T9.13). What Erlang does around a receive is Erlang's, so this sender lowers it
(contract T9.13a). `src/e2s_split.erl` rewrites the abstract forms of a module before the codex types them; what
it makes are ordinary Erlang functions, sent with the ordinary nodes. `main/0` of `examples/actors.erl`:

```erlang
main() ->                                          %% as written
    spawn(actors, supervisor, [self(), 0]),
    Counter = receive {child, Pid} when is_pid(Pid) -> Pid end,
    Counter ! {add, 2},
    Counter ! {add, 5},
    {Total, Adds, Mean} = ask(Counter),
    io:format("total ~p after ~p adds, mean ~p: ~p~n", [Total, Adds, Mean, describe(Total)]),
    ...
```

```erlang
main() ->                                          %% as sent: main, main__k1, ask__c1, ask__c1__k1, main__k2, ...
    spawn(actors, supervisor, [self(), 0]),        %% code before the receive: runs when the process starts
    receive {child, Pid} when is_pid(Pid) -> main__k1(Pid) end.

main__k1(Counter) ->                               %% the code after the first receive: a continuation
    Counter ! {add, 2},
    Counter ! {add, 5},
    ask__c1(Counter, Counter).                     %% ask/1 receives: a copy of it that goes on in main__k2

ask__c1(Counter, E2s_k2) ->                        %% E2s_k2: what main__k2 needs (its live variable Counter)
    Counter ! {get, self()},
    ask__c1__k1(E2s_k2).

ask__c1__k1(E2s_k2) ->                             %% the receive alone, with only the variables it uses
    receive
        {tally, Total, Adds, Mean} when is_integer(Total), is_integer(Adds), is_float(Mean) ->
            main__k2(E2s_k2, {Total, Adds, Mean})
    after 5000 -> exit(no_answer)
    end.

main__k2(Counter, E2s_v1) ->                       %% the code after `= ask(Counter)`
    {Total, Adds, Mean} = E2s_v1,
    io:format(...), ...
```

| Erlang | What the sender sends | Where |
| --- | --- | --- |
| code before a receive | nothing changes: it stays before the receive. The transpiler's process runs it when it starts, in the new process, so `self()` and a send there are right | (nothing) |
| a receive with code after it: `P = receive … end, Rest` or `receive … end, Rest`, also inside the clauses of `case`, `if` and `receive` | the receive becomes the last expression; `Rest` is the **continuation** `f__k<n>(Live…, Value) -> P = Value, Rest`; each clause (and the `after`) ends with a tail call of it | `cut/5` |
| the variables the continuation gets | the variables `Rest` uses that have a value at the cut: bound before the receive, or bound by every clause of it; and the receive's value when it is bound | `cut/5` (`Live`) |
| several receives in one function | one continuation for each (`f__k1`, `f__k2`, …) | `split_body/3` |
| `P = g(…), Rest` where `g` receives (itself, or through a function it calls) | a **copy** `g__c<n>` of `g` with the continuation's variables as extra parameters, whose every end is a tail call of the continuation; a `g` that loops calls its own copy; a function `g` goes on in gets a copy too | `copy/4`, `wrap_last/3` |
| the state a waiting process keeps | in a function the sender made, a receive that does not use every variable is put in a function of its own with the variables it uses (`f__k<n>`), because the transpiler keeps every variable bound at a receive | `split_tail/3` |
| `exit(R)`, `error(R)` in a clause | the process ends there; no continuation is called | `fail_call/1` |
| a function with its receives in tail position already | sent as it is written | |
| a receive, or a call of a function that receives, **inside an expression** (`{ok, receive … end}`, `f(g())`) | **a gap** (`receive inside an expression`) whose note says to bind the value with `=` first | `unsplit/2` |

A function the sender made has no `-spec`. Its parameters get the types of the arguments of the calls of it, and
its result is the `-spec` result of the source function it is cut from (`gen_sigs/2` in the codex: the forms are
typed until those types no longer change; a parameter that one clause gives `ok` and another `error` is
`ok | error`). Its signature hint has the strength `inferred`. It is not exported. Names: see N7 under
[Names](#names).

**Trapping exits.** `process_flag(trap_exit, true)` written as a statement of a function body, and after it in
that body:

| Erlang | What the sender sends |
| --- | --- |
| `process_flag(trap_exit, true)` | nothing |
| `spawn_link(fun() -> g(Args) end)`, `spawn_link(Mod, g, [Args])` with `g` a function of the module | `begin E2s_s1 = self(), spawn(fun() -> g__l(Args, E2s_s1) end) end`: an unlinked spawn of the **linked copy** of `g`, with the parent (bound before the spawn) as one more argument |
| `g__l` | a copy of `g` whose every end sends the parent a message first: `Parent ! {'EXIT', self(), normal}` before a value, `Parent ! {'EXIT', self(), Reason}` before `exit(Reason)` or `error(Reason)` with an atom written there |
| `receive {'EXIT', Pid, Reason} -> …` | the pattern's variables are typed as the message the copy sends (a pid and an atom); a variable that has a value already (`Child`) is replaced by a new one and compared in the guard (`E2s_x1 =:= Child`), because the transpiler binds every pattern variable anew |

**`io:format`.** With a literal format, `io:format/1,2` is sent as what it does: the arguments are evaluated
(one that is not a variable or a literal is bound first), then one L1 call of a Silica print builtin for each
piece of the format (contract T9.16), then `ok`. `~n` and `~~` are text; `~p` and `~w` print an integer, a float,
an atom or a boolean; `~b` an integer; `~s` a binary. Any other control sequence, a value of another type, or a
format that is not a literal makes the call a gap that says which.

**What is not Erlang's behaviour** (each is a deviation of the translated program):

- **Selective receive.** A message that no clause of the receive a process waits in takes is **dropped** by the
  transpiler's lowering; Erlang keeps it for a later receive. Every function this sender cuts has several
  receives, so every one of them gets the transpiler's warning `T4004`. `actors:main/0` is not affected: each
  message it is sent arrives while it waits for that message. (Re-sending an unmatched message to `self()` was
  considered and not done: nothing in the contract lets a sender state it.)
- **A trapped exit is delivered only for an end the source writes.** A child that ends by a failure the runtime
  raises (`badarith`, no matching clause, a gap) sends its parent nothing; in Erlang the parent gets
  `{'EXIT', Child, Reason}`. Under the session's `a4_4` choice `transient` the transpiler's own supervisor then
  starts that child again from its first state, with the same arguments (the same parent).
- **The link's other direction is not kept**: when the parent ends, the child goes on. And a parent that does not
  trap exits is not ended by its child's failure (a `spawn_link` with no `process_flag` before it in the same
  function body is still sent as a linked spawn, which the transpiler does not write: contract T9.15).
- **An exit reason is an atom.** `exit({shutdown, X})` in a linked copy sends nothing. An exit request
  (`exit(Pid, Reason)`) ends the process without any message to the parent.
- **`process_flag(trap_exit, true)` is read where it is written**: in the body of the function that then spawns
  and receives. A process that sets the flag in one function and links in another is not followed (the
  `spawn_link` stays a linked spawn, the receive of `'EXIT'` has no type: gaps).
- **The arguments of `spawn(fun() -> f(Args) end)` are evaluated by the spawner** (contract T9.14), in Erlang
  by the new process: a `self()` written among them is the parent here and the child in Erlang, and a failure
  in them ends the parent. (Not new with the split; the sender does not check it.)
- **`io:format` output**: floats are written by Silica's `print_float64` (the whole part and at most 15 decimal places, cut and not rounded:
  `13.333333333333334` comes out as `13.333333333333333`, `3.14159` as `3.141589999999999`; `3.5` and `12.0`
  come out as in Erlang; a whole part beyond the 64-bit range, `1.0e22`, comes out as `9223372036854775807.0`:
  limitation observed, contract T9.16); an atom is
  written as its name, without the quotes `~p` adds to an atom that needs them.
- **A call of a function that receives costs a copy of that function for each place it is called from** with
  code after the call. The copies are small here; a large module would grow.
- **A variable bound inside a branch and used after a `case` that does not receive** is still not followed (as
  before). After a receive that is cut it is, because the continuation gets it as a parameter.

## A static supervisor

**What this sender maps.** An OTP supervisor is Erlang's own construct; the contract has no node that means
"OTP supervisor", and the transpiler knows nothing of `init/1` or a child specification. What the contract has
is the **static child** (T9.14b): a `(:register)` of a `(:spawn)` with literal arguments, which the transpiler
writes into the child list its unit's supervisor has from its start (Silica's `Supervisor` behaviour; BEES A4.4).
`src/e2s_sup.erl` reads the supervisor and sends that, before the split and before anything is typed:

```erlang
-behaviour(supervisor).

start_sup() ->                                                   %% sent as:
    {ok, _Sup} = supervisor:start_link({local, demo_sup},        %%   (:register, "tally",
                                       ?MODULE, []),             %%      (:spawn, (:fun_ref "demo" "counter" 1),
    ok.                                                          %%               [(:int 0)], link false))
                                                                 %%   with the override on the (:spawn):
init([]) ->                                                      %%      a4_4 chosen restart=transient
    SupFlags = #{strategy => one_for_one, intensity => 3,        %%                  strategy=one_for_one
                 period => 10},                                  %%   then (:symbol "ok")
    Tally = #{id => tally, start => {demo, start_tally, [0]},
              restart => transient},                             %% init/1 and start_tally/1 are not sent:
    {ok, {SupFlags, [Tally]}}.                                   %% what they say is in the static child

start_tally(Start) ->
    Pid = spawn_link(demo, counter, [Start]),
    true = register(tally, Pid),
    {ok, Pid}.

tally_add(N) -> tally ! {add, N}, ok.                            %% (:send_named, "tally", {add, N})
```

| Erlang | What is sent | Where it comes from |
| --- | --- | --- |
| the place of `supervisor:start_link/2,3` | one static child node for each child of the list, in order | the statement `{ok, _} = supervisor:start_link(…)` (or the call alone, not as the last expression) |
| the child list | fixed when the program is sent: `init/1` is **evaluated by the sender** with the literal argument of the start (`erl_eval`; it may build and match data and call nothing) | `init/1` |
| the child's function and arguments | the `(:spawn)`: the function the start function `spawn_link`s, with the start MFA's literal arguments in place of the start function's parameters | `start => {Module, F, Args}` and the body of `F` |
| the child's name | the name its start function registers it under; with no `register/2`, the `id` of its specification | `register(Name, Pid)` / `id` |
| `restart` | the override's `restart`, **as written**; not written: `permanent`, OTP's default | the child specification |
| `strategy` | the override's `strategy`, as written; not written: `one_for_one`, OTP's default | the supervisor flags |
| the link of `spawn_link` | `link` `false`: the child is under a supervisor, which is what that link is for | |
| `intensity`, `period`, `shutdown`, `modules`, a child's `type` other than `worker` | not sent (the contract has no place for them; a `supervisor` child is not read) | |

The session's own `a4_4` choice (for an ordinary `spawn`) is not touched by this: the static child's restart
policy travels in its override.

**What is read.** The start must be `{ok, _} = supervisor:start_link(Name, ?MODULE, LiteralArgs)` (or
`start_link(?MODULE, LiteralArgs)`), the variable `_` or one that starts with `_`. `init/1` must answer
`{ok, {SupFlags, ChildSpecs}}` (maps or the tuple forms) without calling a function. A start function must have
one clause and the body `{ok, spawn_link(…)}` or `Pid = spawn_link(…), [true =] register(Name, Pid), {ok, Pid}`,
where the `spawn_link` is `spawn_link(?MODULE, F, [A, …])` or `spawn_link(fun() -> F(A, …) end)` and each `A` is
an integer, a float or an atom, or a parameter that the specification gives such a value. Anything else, and the
supervisor is not read: the start is a gap whose note says what a supervisor must look like, `-behaviour` is a
form gap, and `init/1` and the start function are sent as the functions they are (usually gaps: maps,
`register/2`).

**What is not Erlang's behaviour.**

- **The children exist from the program's start**, not from the call of `supervisor:start_link`: the unit's
  supervisor is started by `main` (or `to_silica_start()`), with its child list. A child has not run before
  `start_sup/0` is called (where the node stands it is sent its start message), but a message sent to its name
  before that starts it. Calling `start_sup/0` a second time does nothing; in Erlang it fails
  (`{error, {already_started, _}}` does not match `{ok, _}`).
- **The supervisor is no process.** Its children are children of the unit's own supervisor, beside every process
  the module spawns. It has no pid (a start whose value is used is a gap), it cannot be stopped, and
  `supervisor:which_children/1`, `terminate_child/2` and the rest are gaps. Its registered name (`demo_sup`) is
  not a name of the output.
- **`one_for_all` and `rest_for_one` are not followed**: the unit has one supervisor, whose strategy is the
  session's (`one_for_one` here); the transpiler reports the difference (`T2001`).
- **`intensity` and `period` are not carried**: the unit's supervisor allows 100 restarts in 10 seconds, and when
  that is passed the whole program ends, not one supervisor.
- **A restarted child is started lazily**: it runs to its first receive when its next message arrives (contract
  T9.14). For a child whose function starts with its receive, as `counter/1`, that is the same.
- **A child that is not registered in Erlang has a name here**: the `id` of its specification.
- **The start function is not run.** Only its `spawn_link` and `register` are read: anything else it does is a
  reason not to read the supervisor.

## A node program: three nodes that send messages to each other

**What this sender maps** (contract T9.17, added 2026-11-16). One Erlang module is one node. `-silica_node([...])`
declares the node, the nodes it talks to and the registered names that cross; the sender sends it as one `(:node)`
form and the transpiler writes BEES's manifest and `bees.config` (BEAM mode: EPMD and a cookie) beside the unit.
`{Name, Node} ! Message` to a name the attribute declares as a remote is sent as `(:send_named)` (H39), the same node
as a send to a local name: BEES registers a proxy under the remote name.

```erlang
-silica_node([{name, 'hub@localhost'},                         %% this node
              {cookie_file, "cookie"},
              {peer, 'a@localhost', "localhost", listen},       %% a node it talks to; listen or dial
              {local, hub_in, request, [atom, integer]},        %% a registered name here: {request, Atom, Integer}
              {remote, a_inbox, 'a@localhost', reply, [integer]}]).  %% a name there: {reply, Integer}
%% {redial, off} | {redial, InitialMs, MaxMs}: on a node with a dial peer (BEES has no default); not on one without
%% optional: {creation, N} {listen_address, S} {listen_port, N} {epmd_port, N} {net_ticktime_s, N}
```

A field kind is `integer | float | atom | boolean | binary` (what the fields after the tag are; Erlang's messages have
no declared type, so the attribute states it, contract 8.6). The message is the tuple `{Tag, Field...}`. A pid does
not cross a node: **a request names the registered name its answer is to go to** (an atom field), and the answering
process picks the send by that field, as `answer/2` of `examples/three_nodes/hub.erl` does.

`examples/three_nodes/` is the hub topology: `hub.erl` listens, `edge_a.erl` and `edge_c.erl` dial it, each edge asks
the hub's `hub_in` to double a number and receives `{reply, N}` on its own inbox. All three convert with no gap.

`examples/three_nodes_mesh/` is the complete mesh: `mesh_a.erl`, `mesh_b.erl` and `mesh_c.erl`, each with a link to
both others (`mb` dials `ma`; `mc` dials `ma` and `mb`). A node may mix `listen` and `dial` peers, as `mesh_b` does.
Every node serves requests on `<x>_in` and asks both other nodes to double a number, so six requests and six
answers cross the three links, each link in both directions. All three convert with no gap and ran live on
2026-11-19 (`../tools/node_kit/live_run_mesh_*.txt`).

`examples/five_nodes_mesh/` is the complete mesh of five nodes: `mesh5_a` to `mesh5_e`, nodes `na` to `ne`, ten links. A node
dials every node whose letter comes before its own and listens for the rest. Every node asks the four others to
double a number, so twenty requests and twenty answers cross the ten links, each link in both directions. All five
convert with no gap and ran live on 2026-11-20 (`../tools/node_kit/live_run_mesh5_*.txt`).

| | Sent as a gap |
| --- | --- |
| `Pid ! Message` to a pid on another node, `spawn/4` on another node, `monitor_node`, `net_kernel`, `global`, `rpc` | yes (no meaning: BEES sends to registered names) |
| `{Name, Node} ! Message` for a name or node `-silica_node` does not declare as a remote | yes, with a note that says so |

BEES connects every `peer` line (a hub holds a link to each edge). A peer host is a name or an IPv4 literal: with
the `epmd` port BEES resolves the name on each dial, then asks that host's EPMD, so the examples write `"localhost"`
(run live 2026-11-18). An IPv6 literal is refused by BEES's `bees_config_beam.py`. The attribute is
ignored by Erlang itself: the three modules also run on stock Erlang nodes (`erl -sname hub`, and so on).

## Decisions and limits a reader should know

- **Alias patterns.** `f(T = #tally{total = N})` is sent as `(:match, at, T, #tally{…})` where a pattern is
  expected, both children being patterns. The contract says "patterns use the same node kinds as expressions; which
  one a node is follows from where it is referenced" (§9.4) and has H18; it does not say in so many words that a
  match node may stand in a pattern. This is this sender's reading (the Elixir and Gleam senders do the same).
- **`try`/`catch` is a gap.** The contract has a `try` node (H27) with `clauses` and `catches`, but it does not say
  what the patterns of a catch clause are (Erlang's are `Class:Reason:Stacktrace`), nor what `clauses` are, so
  nothing is mapped. No example uses `try`.
- **A hand-written supervisor** (a process that traps exits and links its child, as `supervisor/2` of
  `examples/actors.erl`) is lowered by this sender (above: the linked copy); an OTP supervisor is sent as static
  children ([A static supervisor](#a-static-supervisor)). A `spawn_link` with no `process_flag(trap_exit, true)` before it in the same
  body is sent as a linked spawn (H21 with `link` true), which the transpiler does not write (contract T9.15); a
  `process_flag/2` anywhere else is a gap node, and a receive of `{'EXIT', Pid, Reason}` outside such a body is a
  gap when it binds the reason (an exit reason is any term, so the message has no type).
- **Calls to modules outside the session** (`erlang:is_process_alive/1`, `lists:reverse/1`) are sent as ordinary
  `(:call, …)` nodes with the module as written, hinted with their result type when `bif_type/3` knows it. Check
  mode accepts them; the contract does not say what they mean (T9.9: there is no foreign call), and the
  transpiler does not write them. `io:format` with a literal format is not such a call any more (above).
- **Strings.** `"abc"` is sent as a list of three integers, which is what it is in Erlang. A long format string
  is therefore a long list node.
- **A variable bound inside a branch** (`case … of _ -> X = 1 end, X`) is not followed out of the branch: its
  later uses have no type and become gaps.
- **Several modules in one session.** A call into another module of the same session is typed from that module's
  `-spec`. A `(:type)` form must come before the forms that name it (T8.14): list a module after the modules
  whose records and types its `-spec`s get through such calls.

The session is a `:bees` session (the process constructs need it, contract T7.10) with one lowering choice per BEES
requirement (T7.1), the ones of the contract's worked example. The unit prefix is `erl_`.

## Names

The same scheme is used by the three proof-of-concept senders, so that names made by different senders are
spelled alike. N4 and N6 are **injective**: two different source names, or one name at two arities, never give
the same sent name, and a reader gets the source name back.

| | What | Rule | Example |
| --- | --- | --- | --- |
| N1 | `silica_unit` | the prefix `erl_`, then the module name: its segments (split at `.` and `/`) in snake_case, joined with `_`; a character outside `[A-Za-z0-9_]` becomes `_x<hex>_` (`?` → `_q`, `!` → `_b`) | `actors` → `erl_actors`; `myApp` → `erl_my_app` |
| N2 | `unit_name`; the `module` of `(:call)` and `(:fun_ref)` | the module name as the user writes it (T5.2). Not changed | `lists`, `io` |
| N3 | type names: a `:type` form's `head.name`, `t_named`, the name of a `(:record)` | `<module as in N1, no prefix>_<record or type name in snake_case, then N4>`. `t_named` names a type of the whole session (T8.14), and two modules may each have a record `state` | `#tally{}` in `actors` → `actors_tally` |
| N4 | function, variable and field names | `ident`, below. No change for an ordinary Erlang name | `'is-ok?'` → `is__x2d_ok__q` |
| N5 | symbols: `(:symbol)`, `t_symbols`, the tag of `t_tagged` | the atom's own text, unchanged. Making a symbol a Silica atom is the transpiler's work (H5, BEES A6.3) | `'EXIT'` → `EXIT` |
| N6 | a function name the module defines at more than one arity | `<ident(name)>__<arity>`, at **every** arity of that name: in `head.name`, in local calls, in `(:fun_ref)`, in the `entry` form. A name with one arity is `ident(name)` alone | `total/1`, `total/2` → `total__1`, `total__2` |

**`ident(name)`** goes through the source name's characters from left to right:

- `[A-Za-z0-9]` is kept;
- `?` → `__q`; `!` → `__b`;
- `_` is kept as `_` only when it stands alone: the character before it is not `_`, and the character after it
  (if there is one) is a kept one, that is neither `_` nor a character that gets escaped. Every other underscore
  (next to another underscore, or directly before an escaped character) is written `__x5f_`;
- any other character → `__x<lowercase hex code point>_`;
- the empty name → `__e`; a name that starts with a digit gets that digit escaped (`1abc` → `__x31_abc`).

So `__` appears in the result only as the start of an escape, and a left-to-right reader inverts it (`decode/1` in
`test/e2s_test.erl`). `__` followed by a digit is never an escape, which is what keeps N6's arity suffix apart:
strip `__<digits>` from the end, then decode. Examples: `valid?` → `valid__q`, `valid__q` →
`valid__x5f___x5f_q`, `a_?` → `a__x5f___q`, `x_` → `x_`, `sum_list` → `sum_list`.

snake_case (N1, N3): `_` goes between a lowercase letter or digit and an uppercase letter, and between an uppercase
letter and an uppercase letter that a lowercase letter follows; then everything is lowercased (`HTTPServer` →
`http_server`). The functions are `e2s_codex:ident/1`, `snake/1`, `unit_ident/1`; `fname/4` adds N6's suffix.

**What remains for names** (not decided by the contract yet; the sender does nothing about it):

- **Silica reserved words and builtins, and `main`.** A function `main`, `fn` or `send` is sent under that name;
  the transpiler reports it. How such names are to be mangled is not decided.
- A module **outside the session** is not seen, so a call into it never gets an arity suffix, even if that module
  defines the name at several arities.
- N1 and N3 are not injective (snake_case folds case; `my_app` and `myApp` give one unit name). Unit names are
  checked by the transpiler (T5.2, `:bad_unit_name` for a repeat).
- The codex's own variables are spelled `E2s__t<n>`. No Erlang variable gives that spelling through `ident`
  (`__t` is not an escape), so they cannot collide. The variables `e2s_split` makes are `E2s_k<n>` (what a copy
  passes on), `E2s_v<n>` (a receive's value), `E2s_r<n>`, `E2s_x<n>` (an `'EXIT'` pattern) and `E2s_p<n>` (a
  record field): Erlang variables, each one chosen so that the module has no variable of that name.
- **N7: functions the sender makes.** `<the sent name of the function it is made from>` followed by `__k<n>` (the
  n-th continuation), `__c<n>` (the n-th copy that goes on in a continuation) or `__l` (the linked copy):
  `main__k1`, `ask__c1`, `ask__c1__k1`, `counter__l`. `ident/1` never writes `__k`, `__c` or `__l`, and N6's
  suffix is `__` and a digit, so no source function has such a name.

## Files

- `src/e2s_split.erl`: Erlang's process semantics, lowered on the abstract forms before the codex sees them
  (`forms/1`): the cut at a receive, copies, the linked copy, literals in record patterns. Its header shows the
  rewriting.
- `src/e2s_sup.erl`: OTP's supervisor behaviour, read on the abstract forms before the split (`forms/1`,
  `read/2`): a supervisor start becomes a mark for each static child. Its header shows the rewriting and lists
  what is read.
- `src/e2s_codex.erl`: Erlang abstract forms to frames, with the typing pass. Its header lists its sections.
- `src/e2s_sender.erl`: the TCP protocol: `run/3` (length-prefixed ETF, welcome, credit, replies, resume) and
  `release/3`.
- `src/e2s.erl`: the command line.
- `examples/demo.erl`: one small function per construct of the subset, the numeric conversions, one name at two
  arities, and a supervisor with a static child list (`-behaviour(supervisor)`: `start_sup/0`, `init/1`,
  `start_tally/1`, and `tally_add/1`, `tally_total/0`, `tally_stop/0`, which talk to the child by its name).
  Nothing of it is a gap. It runs as ordinary Erlang:

  ```sh
  erlc -o /tmp examples/demo.erl && erl -noshell -pa /tmp -eval \
    'ok = demo:start_sup(), ok = demo:tally_add(3), ok = demo:tally_add(4), io:format("~p~n", [demo:tally_total()]), ok = demo:tally_stop(), halt().'
  # 7
  ```
- `examples/actors.erl`: a small working application of three actors: a coordinator, a supervisor with one linked
  child that it restarts if it ends abnormally, and a counter whose state is a record. It runs as ordinary Erlang:

  ```sh
  erlc -o /tmp examples/actors.erl && erl -noshell -pa /tmp -s actors main -s init stop
  # total 7 after 2 adds, mean 3.5: small
  # total 36 after 3 adds, mean 12.0: large
  # the counter stopped; restarts: 0
  ```

  Every function of it is sent, and none of it is a gap: `main/0` as nine functions (itself, four continuations, and two copies
  of `ask/1` of two functions each: its receives and its two calls of `ask/1` have code after them), `supervisor/2` with the linked copy `counter__l`. Transpiled, compiled and
  run as a program it prints the same three lines (`../silica-sink/STATUS.md`).
- `test/`: the tests.

## Run

Needs Erlang/OTP 26 or later (`erl`, `erlc`). No other dependency.

```sh
mkdir -p ebin && erlc -o ebin src/*.erl
# print the frames, send nothing
erl -noshell -pa ebin -run e2s main -extra --dump examples/demo.erl
# send to a transpiler on 127.0.0.1:7411 in check mode (the default mode)
erl -noshell -pa ebin -run e2s main -extra --port 7411 examples/demo.erl
# transpile; the first output line names the session, for example: session intake_1:42 (…)
erl -noshell -pa ebin -run e2s main -extra --port 7411 --mode transpile examples/demo.erl
# release that session when its output has been exported
erl -noshell -pa ebin -run e2s main -extra --port 7411 --release intake_1:42
```

Options: `--port N` (default 7411), `--mode check|transpile` (default `check`), `--dump`, `--release Session`,
`--resume Session`. A session id is the text the transpiler gives (`<region>:<number>`, T6.5b); the sender passes
it on unchanged. The exit status is 0 when the result's status is `ok` (or, for `--release`, when the session was
freed), 1 otherwise, 2 for a usage error.

What the sender does on the wire:

- **Credit** (T6.2, T6.3, T6.11a). The welcome gives a window (64 as built). Before every frame the sender takes in
  whatever the transpiler has already sent, `(:stored, n)` and `(:credit, 32)` after each half window, rejections;
  when its credit is used up it waits for more and sends nothing. It never writes everything first and reads
  afterwards.
- **Counts** (T5.3b). `forms` in the unit end is the number of form frames sent, `units` in the end the number of
  units. A count the transpiler does not agree with is not a rejection: it comes back as a `T1002` diagnostic,
  which is printed with the others, and the result is not `ok`.
- **Result** (T6.8). `ok`, `partial` or `failed` is printed with its counts; a `failed` result has `files 0`, and a
  unit of which nothing could be written is named by a `T4003` diagnostic.
- **Resume** (T6.5, T6.5a). `--resume Session` with the same files sends the same hello with the session id; the
  frames below the welcome's `resume_from` are not sent again. A session whose `(:end)` was already stored
  answers with credit 0: nothing is sent and the result is awaited. A check session cannot be resumed (T6.12).
- **`max_frame`** (T6.1). A frame larger than the welcome's `max_frame` is not sent: the session is given up with
  `(:abort, …)` and an error is printed.

## Extending this sender

### How the typing pass works

`e2s_codex` works in two steps.

1. **The pre-pass** (`scan/1`, `session/1`) reads every file of the session and keeps: each `-record` and `-type`
   as a type term (`defs`), which of them cannot be stated and why (`bad`), each function's `-spec` as parameter
   and result types, or why it gives none (`funs`), and which names have several arities (`multi`).
2. **The forms** (`unit/3`). The type forms go first. Then each function: `function/3` takes its signature from
   `funs`, and `clause/6`, `pattern/5` and `expr/3` build the node table. Every builder function returns the
   node's index **and its type**, as one of the codex's own type terms:

   ```
   int | float | boolean | atom | {atoms, [Name]} | bytes | {tuple, [T]} | {tagged, Tag, [T]} | {named, Name}
   | {list, T} | {union, [T]} | {'fun', [T], T} | {actor, T} | dynamic
   | none            no value (exit/1), or the element type of []
   | {unknown, Why}  Erlang gives no type here; Why is the text a gap's note will carry
   ```

   `expr(Abstract, Expected, B)` also takes the type the place states (`any` when none): the `-spec`'s result for a
   body, a parameter's type for an argument, a field's type. Only literals and constructions use it (`fit/3`): `ok`
   where `ok | error` is expected, `[]` where a list of integers is, a fun where a fun type is.
   `pattern(Abstract, Type, Strength, GuardTypes, B)` binds the pattern's variables (`#b.vars`) with the type of
   their position in `Type`.

The builder `#b{}` is a value. To give up a construct after building part of it, return to the builder from
before it: `gap(Anno, Construct, Note, B0)`. That is how every gap is made, so no frame holds a node that nothing
refers to. A pattern that would bind a variable with no type throws `{e2s_untyped, Why}`; the nearest function,
`case`, `receive`, fun or `=` catches it and becomes the gap.

### State a type for a new construct

- Finish the construct with `node(Tag, Anno, Fields, Type, B)`: it emits the node **and its hint** (when the type
  can be stated; `why/2` says whether). `plain/5` emits a node with no hint: a literal, whose type the contract
  fixes (T8.9), or a node with no value.
- The strength is `inferred` unless the node is marked: `mark(Index, declared, B)` for a type that comes only from
  a `-spec` or `-record` (a call's result, a field, a variable bound to one of those).
- If the contract requires the type (T8.10) and it may be unknown, check it: `case why(Type, B) of ok -> node(…);
  Why -> gap(Anno, Construct, [..., Why, " (T8.10 x)"], B0) end`. `construction/7` does this for records and lists.
- A new Erlang type: a clause in `ty/2` (Erlang type → type term); for a new kind of type term also `entry/2`
  (type term → the contract's type table, §8.5), `why/2`, `compat/4` and `show/1`.
- The result of a function outside the session: a clause in `bif_type/3`. The arguments' types are given, so the
  result may depend on them (`abs/1`, `hd/1`).
- A new type test in guards: `type_test/1`.

### Where conversions are inserted

All in the section "operators: types and conversions" of `e2s_codex.erl`:

- `as_float/2` is the one place a `to_float` is written: an integer literal becomes a `(:float)`, an integer value
  goes under `(:op, at, "to_float", [X])`, a float stays.
- `arith/5` (`+ - *`) and `compare/5` call it on both operands when exactly one is a float; `compare/5` also
  writes the constant for `=:=`/`=/=` between an integer and a float.
- `fdiv/4` (`/`) calls it on both operands and writes the zero guard; `once/2` binds an operand that must not be
  evaluated twice.
- `call/5` maps `float/1`, `trunc/1`, `round/1`.

To add a conversion the contract gains (floor, ceiling, other widths: T8.12 calls them gaps today), add the BIF's
clause to `call/5` next to `trunc`. To add a guard for another edge (T8.15), follow `fdiv/4`.

### Change what is split (`src/e2s_split.erl`)

`e2s_split:forms/1` takes a module's abstract forms and answers `{Forms, Gen}`: the forms with every receive (and
every call of a function that receives) in tail position, and what each function it made is made from. It knows
no types. To see what it does to a file, print its forms:
`erl -noshell -pa ebin -eval '{ok, F} = epp:parse_file("examples/actors.erl", [{location, {1, 1}}]), {O, _} = e2s_split:forms(F), [io:format("~s~n", [erl_pp:form(X)]) || X = {function, _, _, _, _} <- O], halt().'`

- **Which functions wait** (`blocking/2`): a function with a receive, or one that calls such a function (outside
  a fun). Only these are touched.
- **Where a body is cut** (`split_body/3`, `shape/2`, `cuttable/2`): at the first statement that waits and is
  `P = B` or `B` with `B` a receive, a call of a function that waits, a `case`, an `if` or a block. To cut at
  another shape (a receive as an argument, say), add the shape here and say in `wrap_last/3` how its value
  reaches the continuation; until then `unsplit/2` makes it a gap with a note.
- **What a value does at the end of a body** (`wrap_last/3`, `value/3`): `{cont, Name, Args, UsesValue}` calls a
  continuation, `{notify, Parent}` sends the `'EXIT'` message of a linked child. A new kind of ending (a monitor's
  `'DOWN'` message, say) is a new `K` here and in `copy/4`.
- **Trapping exits** (`trap/2`, `rewrite/3`, `exit_clause/4`), **literals in record patterns** (`literals/2`).
- In the codex, a made function is typed by `gen_sigs/2` and `fsig/2`, named by `fname/4` (N7), and a call of
  it notes its argument types in `session_call/6`. `io:format` is `io_format/4` and `print_value/5`: add a
  control sequence or a printable type there, and its Silica builtin to contract T9.16 and the transpiler first.
- Add a case to `split/0` in `test/e2s_test.erl` (`split/3`: a snippet and what its frames must hold).
  **What `e2s_split` makes is Erlang.** `split_runs/0` compiles the split forms of `examples/actors.erl` in place
  of the module and requires them to print and return what the module does: a change to the splitter that
  changes a program's behaviour fails there, before any transpiler is involved. (The linked copy is written so
  that this holds: the parent is bound before the spawn, because `self()` inside the fun would be the child.)

### Change what is read of a supervisor (`src/e2s_sup.erl`)

- `start/2` and `start_call/1` say which statement is a supervisor start; `init/3` evaluates `init/1`;
  `strategy/1` and `spec/1` read the flags and a child specification (OTP's defaults are there); `child/4`,
  `start_body/1`, `registered/2` and `spawned/2` read a start function; `scalar/1` says which literals a child's
  argument may be (the transpiler writes integers, floats, symbols and booleans into a child list: contract
  T9.14b). Every refusal is a `throw` of a sentence; the supervisor is then left as it is written.
- The mark `e2s_sup:static_child(Name, Restart, Strategy, Function, Args)` is turned into nodes by
  `static_child/7` of the codex: the `(:spawn)`, its A4.4 override (the builder's `overrides`), the
  `(:register)`.
- Add a case to `supervisor/0` in `test/e2s_test.erl` (`sup/3` and `sup_source/3`: a supervisor module from
  three strings, and what its frames must hold). `demo_runs/0` holds `examples/demo.erl` to being an Erlang
  program whose supervisor starts and whose child answers.

### Add a construct mapping

1. Find the construct's abstract form (`erl -noshell -eval '{ok, Fs} = epp:parse_file("x.erl", []), io:format("~p~n", [Fs]), halt().'`)
   and the contract node it should become (contract §9.4; the schema `../contract/tcp_transport_v1.silica` is the
   authority on the node's shape). **If the contract has no node for it, do not invent one: emit a gap.**
2. In `src/e2s_codex.erl`, add a clause to `expr/3` in the section of the node's family (literals and data, lists,
   names matching and control, processes and messages, operators, calls). If the construct differs in a pattern,
   add a clause to `pattern/5` too. A built-in of the module `erlang` that has its own node goes in `call/5`; a
   top-level attribute in `form/3`.
3. Build the children first, then the node: `{Child, ChildType, B1} = expr(E, any, B0), node(tag, Anno, [Child, …],
   Type, B1)`. Children always come before parents (T9.2). Decide `Type` by Erlang's rules from the children's
   types. Names go through `ident/1` (N4) or `fname/4` (N6), never as atoms (T4.4).
4. Add one line to `mappings/0` in `test/e2s_test.erl` (a source snippet and the nodes expected) and one to
   `typing/0` (`hinted/3`: the hints expected; `gapped/4`: the gap when the type is missing). Both also run the
   frames through the contract's checker and through `typing_faults/1`.
5. Add a use of the construct to `examples/demo.erl` and its node kind to `missing_kinds/1` in the test.

### Emit a gap

`gap(Anno, <<"construct">>, B0)` or `gap(Anno, Construct, Note, B0)` emits `(:gap_node, at, construct, note)` (H40)
in place of an expression or pattern, from the builder `B0` of before the construct; `form_gap/5` makes a `(:gap, …)`
form for a whole declaration. The last clause of `expr/3` turns every abstract form that has no clause into a gap,
so nothing is ever left out silently. Name the construct the way a user would recognise it
(`erlang:process_flag/2`, `try`, `map`, `operator +`), and for a missing type say in the note which type is missing,
why, and the rule (`… has no -spec, so its result type cannot be stated (T8.10 d)`).

### Names

See [Names](#names). Use `ident/1` for anything that becomes an identifier, `fname/4` for a function's name,
`type_name/2` for a record's or a type's name, and leave symbols and module names as written.

### Run the tests

```sh
test/run_test.sh          # offline: mappings, typing, the split, names, both examples, flow control and release against stand-in listeners
test/run_test.sh 7411     # also online, against a transpiler on that port
```

Offline, every frame is checked with `../contract/bindings/erlang/check_frame.erl`, and every function form with
`typing_faults/1` of the test, which reads the frames the way contract §8.6 says the transpiler must (a node's
stated type by T8.9, the required types of T8.10, one type per operator by T8.11, the operand kinds of T8.12). The
last line counts the tests and the failures. An online test that could not be decided because the transpiler
ended is reported apart (`TRANSPILER FAULT`), not as a pass.

### Run check mode and transpile mode

Start a transpiler (`../silica-sink/STATUS.md`, "Commands"), then use the commands under [Run](#run). Check mode
validates every frame and stores nothing; accept a change only when it ends `result: ok`. Transpile mode stores
and prints, and holds a storage region until the session is released: a transpile session is refused `busy` when
every region is held.

### Release a session

`erl -noshell -pa ebin -run e2s main -extra --port 7411 --release intake_1:42`, or
`e2s_sender:release("127.0.0.1", 7411, <<"intake_1:42">>)`, which returns `{ok, #{session := S, freed := Boolean}}`.
It sends `(:release, {session})` as the only frame of a new connection (contract M7, T6.13) and prints the
`(:released, …)` answer: `released: session intake_1:42, freed true`. `freed` is `false` for a session that is
unknown or not finished. If the transpiler closes the connection without answering, the command says so and
exits 1.
