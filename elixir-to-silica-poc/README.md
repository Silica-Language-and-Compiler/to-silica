# elixir-to-silica-poc

A proof of concept of the language-owned half of a to-silica transpiler, for Elixir and written in Elixir: an
**inbound codex** and a **TCP sender**. It is the Elixir twin of `../erlang-to-silica-poc`.

It takes Elixir source, parses it with Elixir's own parser (`Code.string_to_quoted/2`), maps the AST to the frames
of the to-silica TCP transport contract, version 1 (`../contract/tcp-transport-v1.md`, shapes in
`../contract/tcp_transport_v1.silica`), and sends them over TCP to a transpiler. The parser is the gate: if a file
does not parse, nothing is connected and nothing is sent.

It is a plain mix project with no dependencies.

| File | What it is |
| --- | --- |
| `lib/e2s/codex.ex` | the codex: Elixir AST to hello, unit_begin, form, unit_end and end frames, and the typing pass (every type and every numeric conversion the contract's 8.6 requires) |
| `lib/e2s/split.ex` | the split: Elixir's process semantics lowered before anything is typed (a receive with code after it, a call of a function that receives, a trapped exit, a literal in a struct pattern); see "Processes: what this sender splits" |
| `lib/e2s/sup.ex` | Elixir's `Supervisor`, read before the split: `use Supervisor`, `init/1`, the child specifications and their start functions become the contract's static children; see "A static supervisor" |
| `lib/e2s/lift.ex` | a `fn` that captures nothing, written where an `@spec` declares a function type, becomes a function of the module; see "A fn that captures nothing" |
| `lib/e2s/codex/types.ex` | the types of the typing pass: reading `@spec` and `@type`, and the questions asked of two types |
| `lib/e2s/names.ex` | the naming scheme: the only place a name is spelled (see "Names") |
| `lib/e2s/codex/scope.ex` | variable names for the rebinding lowering |
| `lib/e2s/codex/truthiness.ex` | the truthiness lowering of `if`, `cond`, `&&`, `\|\|`, `!` |
| `lib/e2s/sender.ex` | the sender: 4-byte length + ETF framing, welcome, credit, replies read while sending and until the result, resume; `release/3` |
| `lib/e2s/cli.ex`, `lib/mix/tasks/e2s.ex` | the command line (`mix e2s`, also buildable as an escript) |
| `examples/demo.ex` | the example program: one small function per construct of the subset, a supervisor with a static child (`use Supervisor`). It compiles and runs as ordinary Elixir and is sent with **no gap** |
| `examples/actors.ex` | a small working application of three actors, written as Elixir is usually written (a coordinator, a supervisor with one linked child, an account whose state is a struct); run it with `elixir -r examples/actors.ex -e "Actors.main()"`. It is sent with no gap: its receives are split, its trapped exit and its `IO.puts`/`IO.inspect` lowered by this sender, and its `main/0`, run as the Silica program, prints the five lines Elixir prints (`../silica-sink/STATUS.md`). Each answer of the account has a tag of its own (contract T9.12: a message tag has one type in a unit) |
| `test/e2s_test.exs` | the tests |
| `test/fixtures/gaps.ex` | what `examples/demo.ex` used to leave out on purpose (a function without `@spec`, `number()`, a list type, a value that may be `nil`, an untyped `fn`, a closure, `Process.link/1`, an inter-node call): the tests of the gaps read it |
| `test/fixtures/split_shapes.ex` | one module with every shape the split cuts and a `main/0` that runs them all; the tests compile it as written and as split and compare what the two print |

## What is sent

One session per run: a hello (profile `:bees`, one choice for each of the 11 BEES requirements, hint policy
`proven: :trust, declared: :check, inferred: :check`, language `"elixir"`, prefix `"ex_"`), then one unit for each
top-level module, then the end frame. A module `Demo` becomes the Silica unit `ex_demo`, `My.Mod` becomes
`ex_my_mod` (see "Names"). Each function (all its clauses) is one `:function` form; each `defstruct` is one
`:type` form. **The type forms of a module are sent first**, and a type before a type that names it (T8.14).

Identifiers travel as binaries, never atoms (T4.4). Node tables are flat and in post-order (T9.2), and every node
has its own location entry, so a node's `at` is its own index. The same source always gives the same bytes.

**Every type and every numeric conversion is stated by this sender** (contract 8.6): the transpiler infers no
type and converts no number. A function form carries its signature (a `declared` hint on node `-1`, from
`@spec`; `inferred` for a function the split made, from the calls of it) and one hint for every node the contract requires a type for; where Elixir converts a number, the
conversion is a node. Where the codex cannot state a required type, it sends a gap that says which type is
missing and why. See "Types and conversions".

## Scope

Only the subset below is translated. Everything else is sent as a gap (T9.10), a `:gap_node` for an expression or a
`:gap` form for a whole declaration, so a session always completes.

In scope:

- integers, floats (as decimal text), strings (`:text`), atoms (`:symbol`; `true` and `false` are `:boolean`; `nil`
  is the symbol `"nil"`), tuples
- structs as the record idiom: `defstruct` (in the module itself, or in a nested module that only declares a
  struct) is a `:type` form holding a `t_record`, with field types from `@type t :: %__MODULE__{...}` when it is
  there; `%Point{x: 1}` is `:record`; `%Point{p | x: 1}` is `:record` with a base; `p.x` is `:field`
- variables and `=`; `def` and `defp` with several clauses, patterns and `when` guards
- alias patterns, the pin operator, rebinding and truthiness, each by a lowering described under "Lowerings"
- local calls, remote calls (`Mod.fun(...)`, `:mod.fun(...)`), and `|>`, rewritten to a plain call
- operators, in the contract's Appendix B spellings: `!=` is `/=`, `<=` is `=<`, `===` is `=:=`, `!==` is `=/=`,
  `and` is `andalso`, `or` is `orelse`, `not`, `div` and `rem`, unary minus is `neg`, `<>`; `is_nil(x)` is
  `x =:= nil`
- `case`; `cond` and `if` (both `:cond`); `&&`, `||`, `!`; `fn` (`:lambda`; a `fn` that captures nothing and is
  an argument typed by an `@spec` is sent as a function of the module and a `:fun_ref`, see "A fn that captures
  nothing"); `&name/arity` (`:fun_ref`); `f.(x)` (`:apply`); a module name as a value (the symbol
  `Elixir.<name>`)
- `@spec`, as a `:declared` hint on the function's signature, and the source of the types of parameters and of
  calls to the module's own functions; `@type t :: %__MODULE__{...}` for a struct's field types
- `trunc/1`, `round/1`, `:erlang.float/1` (the conversion operators of T8.12); `abs/1`, `max/2`, `min/2` and
  Kernel's `is_*` tests
- processes: `self()`, `spawn/1,3` and `spawn_link/1,3` (`:spawn`, with the link flag), `send/2`, `receive` with
  `after` **anywhere a statement or the right side of `=` may stand** (the sender splits the function so that
  every receive it sends is in tail position), `Process.link/1`, `Process.exit/2`, `exit/1` (`:fail`)
- `Process.flag(:trap_exit, true)` followed by `spawn_link` and `receive do {:EXIT, pid, reason} -> …`, lowered
  to an unlinked spawn of a copy of the child's function that tells its parent when it ends
- `IO.puts/1` and `IO.inspect/1` of a value whose type is stated, as calls of Silica's print builtins (L1)
- `use Supervisor` with a child list fixed at its start: `{:ok, _} = Supervisor.start_link(__MODULE__, arg)`,
  `init/1` ending in `Supervisor.init(children, strategy: …)`, and the children's start functions, sent as one
  static child for each child (`:register` of a `:spawn`, H38, with an A4.4 override; contract T9.14b)
- `send(:name, message)` with a literal name (`:send_named`, H39; contract T9.14c)

The last five are this sender's own lowerings of what Elixir does: "Processes: what this sender splits" and "A
static supervisor" say what is sent and what is not Elixir's behaviour afterwards.

Out of scope, sent as gaps: lists and keyword lists, maps, bit syntax and string interpolation, comprehensions,
`with`, `try`/`rescue`/`raise`, macros, `use`/`import`/`require` (but `use Supervisor` of a supervisor that is
read), sigils, the other OTP behaviours (GenServer, DynamicSupervisor, Agent, Task and the like) and a supervisor
this sender cannot read, `Process.register/2` outside a supervisor child's start function, `Process.whereis/1`,
`Process.flag/2` anywhere else, monitors.

`try`, `rescue`, `catch`, `raise` and `throw` stay gaps on purpose: the contract's `(:try, …)` node (H27) does
not say what a catch clause holds, so nothing is mapped until it does. No example uses them.

Inter-node communication is cut entirely: `Node.*`, `:rpc`, `:erpc`, `:global`, `:pg`, `node()`, a send to
`{name, node}` and a spawn on another node are each sent as a gap whose note says so. The examples contain no
such call; `test/fixtures/gaps.ex` has one.

The mapping is syntactic. Nothing is macro-expanded or evaluated, so a name that is neither defined in the module
nor a Kernel function is taken as a local call.

## Lowerings

Four Elixir constructs have no node of their own in the contract. Each is lowered here, in the sender, to nodes
the contract has. Each lowering is small, in one place, and tested by one test per case.

**Alias pattern** (`%Account{balance: b} = account`, `{a, b} = pair` inside a pattern). Sent as
`(:match, at, left, right)` with **both children translated as patterns**, in source order. This is this
sender's reading of contract 9.4 ("patterns use the same node kinds as expressions; which one a node is follows
from where it is referenced") together with H18: a match node referenced from a pattern position matches the
value against both sides. The contract does not say so in words; the Erlang and Gleam senders read it the same
way, and it is listed for confirmation in `../SENDER_GAPS_STATUS.md`. Code: the `{:=, …}` clause of `tr/3` for
`:pattern`.

**Pin** (`^x`). In a clause of a function, `case`, `receive` or `fn`, `^x` is sent as a new variable `_pin_1`
and the clause's guard gets `_pin_1 =:= x` in front, joined to the written guard with `andalso` (H29 gives every
clause a guard). The clause then selects exactly the values the pin selects. In a `=` that is a statement of a
block, the match is followed by `true = (_pin_1 =:= x)`, which fails the process as the match would (H18). A `=`
with a pin that is used for its value (`f(^x = v)`, or the last expression of a body) is a gap: a `=` has no
guard to carry the test. Only a variable can be pinned. Code: `pinned_guard/4`, `statement/2`.

**Rebinding** (`x = x + 1`). The contract's `(:var, …)` in a pattern is a binding and it does not say what a
second binding of a name means, so no name is ever bound twice in a function clause: the first binding of `x` is
sent as `x`, every later binding of a variable called `x` as `x_1`, `x_2`, … (skipping names the source uses),
and a reference is sent under the name of the binding it sees. A binding made inside a clause of `case`, `cond`,
`receive` or `fn` ends with that clause, as in Elixir; a later binding of the same name still gets a new name.
The cost is that sent names can differ from the source's. Code: `lib/e2s/codex/scope.ex`.

**Truthiness** (`if`, `cond`, `&&`, `||`, `!`). A condition that is known to be a boolean is sent as it is:
`(:cond, …)`, `andalso`, `orelse`, `not`. It is known by its syntax (a comparison, `not`, `!`, `and`/`or` of
such, a boolean literal, one of Kernel's `is_*` tests) or by its type (a variable whose stated type is
`boolean()`, a call to a function of the module whose `@spec` returns `boolean()`, so `if valid?(x)` stays a
`cond`). Any other condition is rewritten as Elixir's own macros rewrite it, to a `case` that tests the value
once: `case c do t when t === false or t === nil -> … ; _ -> … end`. A `cond` is split at its first such
condition. The two tests are then typed like any other comparison: against a value that can be neither `false`
nor `nil` (an integer, a string) they are the constant `false`; against a value that may be `nil` (`String.t() |
nil`) the test compares two types, which has no operator, and is a gap (see "Types and conversions"). Code:
`lib/e2s/codex/truthiness.ex`.

## Processes: what this sender splits

The transpiler prints a `(:receive)` only in tail position of its function, with each clause ending in a value or
in a tail call (contract T9.13). What Elixir does around a receive is Elixir's, so this sender lowers it
(contract T9.13a, and §1 "What you own"). `lib/e2s/split.ex` rewrites the quoted forms of a module before the
codex types them; what it makes are ordinary Elixir functions, sent with the ordinary nodes.
`mix e2s --split examples/actors.ex` prints the module as it is sent. `main/0` of `examples/actors.ex`:

```elixir
def main do                                          # as written
  spawn(Actors, :supervisor, [self()])
  account = receive do {:account, pid} when is_pid(pid) -> pid end
  send(account, {:deposit, 40})
  send(account, {:deposit, 30})
  IO.inspect(withdraw_from(account, 100))
  IO.inspect(withdraw_from(account, 30))
  {text, balance, mean} = report(account)
  ...
```

```elixir
def main do                                          # as sent: main, main__k1, withdraw_from__c1, ...
  spawn(Actors, :supervisor, [self()])               # code before the receive: runs when the process starts
  receive do {:account, pid} when is_pid(pid) -> main__k1(pid) end
end

defp main__k1(account) do                            # the code after the first receive: a continuation
  send(account, {:deposit, 40})
  send(account, {:deposit, 30})
  withdraw_from__c1(account, 100, account)           # withdraw_from/2 receives: a copy that goes on in main__k2
end

defp withdraw_from__c1(account, amount, e2s_k2) do   # e2s_k2: what main__k2 needs (its live variable account)
  send(account, {:withdraw, amount, self()})
  withdraw_from__c1__k1(e2s_k2)
end

defp withdraw_from__c1__k1(e2s_k2) do                # the receive alone, with only the variables it uses
  receive do
    {:withdrawn, balance} when is_integer(balance) -> main__k2(e2s_k2, {:ok, balance})
    {:refused, short} when is_integer(short) -> main__k2(e2s_k2, {:refused, short})
  after
    1000 -> exit(:no_reply)
  end
end

defp main__k2(account, e2s_h1) do                    # e2s_h1: the argument of IO.inspect, bound first
  IO.inspect(e2s_h1)
  withdraw_from__c2(account, 30, account)
end
```

| Elixir | What the sender sends | Where |
| --- | --- | --- |
| code before a receive | nothing changes: it stays before the receive. The transpiler's process runs it when it starts, in the new process, so `self()` and a send there are right | (nothing) |
| a receive with code after it: `p = receive do … end; rest` or `receive do … end; rest`, also inside the clauses of `case`, `cond`, `if` and `receive` | the receive becomes the last expression; `rest` is the **continuation** `f__k<n>(live…, value)` whose body is `p = value; rest`; each clause (and the `after`) ends with a tail call of it | `cut/5` |
| the variables the continuation gets | the variables `rest` uses that are bound at the top of the function body before the receive, and the receive's value when it is bound. **Elixir's scoping is kept**: a binding made inside a clause of `case`, `cond`, `if` or `receive` ends with its clause and is not passed on; `x = receive …` binds `x` anew, so the value is the parameter `x` whatever `x` was before; a pinned variable is a use | `cut/5`, `binders/1` |
| several receives in one function | one continuation for each (`f__k1`, `f__k2`, …) | `split_body/3` |
| `p = g(…); rest` where `g` receives (itself, or through a function it calls) | a **copy** `g__c<n>` of `g` with the continuation's variables as extra parameters, whose every end is a tail call of the continuation; a `g` that loops calls its own copy | `copy/3`, `wrap_last/3` |
| a receive, or a call of a function that receives, **as an argument, an operand, a tuple element, a `case` subject or an `if` condition**: `IO.inspect(withdraw_from(account, 100))`, `add(a, get())`, `case get() do`, `a \|> wait_add() \|> add(1)` | its value is **bound to a variable first** (`e2s_h1 = withdraw_from(account, 100)`), then cut as above. Only when everything Elixir evaluates before it is a variable or a literal: the order of evaluation is kept | `hoist/2` |
| the state a waiting process keeps | in a function the sender made, a receive that does not use every variable is put in a function of its own with the variables it uses (`f__k<n>`), because the transpiler keeps every variable bound at a receive | `split_tail/3` |
| `exit(reason)`, `raise`, `throw` in a clause | the process ends there; no continuation is called | `fail_call?/1` |
| a function with its receives in tail position already | sent as it is written | |
| a receive, or a call of a function that receives, **after something that is not a variable or a literal** in the same expression (`add(add(a, 1), get())`), as an operand of `&&`, `\|\|`, `and`, `or`, in a struct, a list or a `fn` | **a gap** (`receive inside an expression`, `call of a function that receives, inside an expression`) whose note says to bind the value with `=` first | `unsplit/2` |

A function the sender made has no `@spec`. Its parameters get the types of the arguments of the calls of it, and
its result is the `@spec` result of the source function it is cut from (`made_sigs/2` in the codex: the
functions are typed until those types no longer change; a parameter that one call gives `{:ok, integer()}` and
another `{:refused, integer()}` is the union of the two). Its signature hint has the strength `inferred`. It is
`defp`: not exported. A made function no call of which could be typed (the code before it is a gap) is a gap
form, and so is each call of it. Names: see N6 under [Names](#names).

**Trapping exits.** `Process.flag(:trap_exit, true)` written as a statement of a function body, and after it in
that body:

| Elixir | What the sender sends |
| --- | --- |
| `Process.flag(:trap_exit, true)` | nothing |
| `spawn_link(fn -> g(args) end)`, `spawn_link(fn -> x \|> f() \|> g() end)`, `spawn_link(Mod, :g, [args])` with `g` a function of the module | `(e2s_s1 = self(); spawn(fn -> g__l(args, e2s_s1) end))`: an unlinked spawn of the **linked copy** of `g`, with the parent (bound before the spawn) as one more argument |
| `g__l` | a copy of `g` whose every end sends the parent a message first: `send(parent, {:EXIT, self(), :normal})` before a value, `send(parent, {:EXIT, self(), reason})` before `exit(reason)` with an atom written there |
| `receive do {:EXIT, pid, reason} -> …` | the pattern is typed as the message the copy sends (a pid and an atom): a variable gets `is_pid/1` or `is_atom/1` in the guard (where the codex reads its type; the test itself is not sent, T8.16), `_` and `_reason` become variables of the sender so that they can have one; a pinned variable (`^child`) stays pinned, which the codex sends as a guard test (see "Lowerings") |

**`IO.puts/1` and `IO.inspect/1`.** A call into `IO` is a call outside the session, which the transpiler does not
write. So the two are sent as what they do: the argument is evaluated (and bound to a variable of the codex
unless it is a variable or a literal), then one L1 call of a Silica print builtin for each piece of the text
(contract T9.16), chosen by the argument's **stated type**, then the call's value (`:ok`; for `IO.inspect` its
argument, or `:ok` where the call is a statement whose value is dropped).

| Elixir | Sent as |
| --- | --- |
| `IO.puts(x)`, `x` a string | `println(x)` |
| `IO.puts(x)`, `x` an atom | `println(atom_name(x))` (a literal atom: its name as text; `nil` prints an empty line) |
| `IO.puts(x)`, `x` an integer, a float, a boolean | `print_int64(x)`, `print_float64(x)`, `print_boolean(x)`, then `println("")` |
| `IO.inspect(x)`, `x` an integer, a float, a boolean | the same builtin, then `println("")` |
| `IO.inspect(x)`, `x` a string | `print("\"")`, `print(x)`, `println("\"")` |
| `IO.inspect(x)`, `x` an atom whose type names its atoms (`:ok`, `:empty \| :low`, `nil`) | the text Elixir writes for each (`:ok`, `nil`, `:"two words"`), chosen by a `case` when there are several |
| `IO.inspect(x)`, `x` of the type `atom()` | `print(":")`, `print(atom_name(x))` |
| `IO.inspect(x)`, `x` a tuple (`{:balance, 40, :mean_move, 13.3}`) | the tuple taken apart by a `case` (a tagged tuple) or a `=` (a plain one), `{`, the elements with `, ` between them, `}` |
| `IO.inspect(x)`, `x` a union of tagged tuples and atoms (`{:ok, integer()} \| {:refused, integer()}`) | a `case` over the alternatives, each printed as above |
| a struct, a pid, a list, a map, a function, a value with no stated type; `IO.inspect/2`, `IO.puts/2`, `IO.write` | a gap (`IO.inspect/1`, `IO.puts/1`) that says which type is not lowered; the others stay calls into `IO`, which the transpiler does not write |

**A literal in a struct pattern** (`def boxes(%Box{n: 0})`, in the clauses of functions, `case` and `receive`) is
sent as a variable and `===` in the clause's guard (`%Box{n: e2s_p1}) when e2s_p1 === 0`): the transpiler prints
a record pattern whose fields are variables.

**What is not Elixir's behaviour** (each is a deviation of the translated program):

- **Selective receive.** In Elixir, as in Erlang, a message that no clause of the receive a process waits in
  takes **stays in the mailbox** for a later receive. The transpiler's lowering **drops** it (contract T9.13).
  Every function this sender cuts has several receives, so every one of them gets the transpiler's warning
  `T4004`. `Actors.main/0` is not affected: each message it is sent arrives while it waits for that message.
  (Re-sending an unmatched message to `self()` was considered and not done: nothing in the contract lets a
  sender state it, and it would spin on a message no later receive takes.)
- **A function whose receive the split moved is still no ordinary function.** `report/1` holds a receive; so
  does `piped/1` of the fixture once its call of a receiving function is cut. Called from a process function in
  tail position, or spawned, they run; called as an ordinary function they fail when the call is reached
  (contract T9.13). For a function that itself ends in a tail call of a made function (and holds no receive of
  its own) the transpiler says so in a `T4002` note on the unit, which counts as one gap in the result.
- **A trapped exit is delivered only for an end the source writes.** A child that ends by a failure the runtime
  raises (`ArithmeticError`, no matching clause, a gap) sends its parent nothing; in Elixir the parent gets
  `{:EXIT, child, reason}`. Under the session's `a4_4` choice `transient` the transpiler's own supervisor then
  starts that child again from its first state, with the same arguments (the same parent).
- **The link's other direction is not kept**: when the parent ends, the child goes on. And a parent that does not
  trap exits is not ended by its child's failure (a `spawn_link` with no `Process.flag(:trap_exit, true)` before
  it in the same function body is still sent as a linked spawn, which the transpiler does not write: contract
  T9.15). `Process.link/1` stays `(:link)`, which it does not write either.
- **An exit reason is an atom.** `exit({:shutdown, x})` in a linked copy sends nothing. An exit request
  (`Process.exit(pid, reason)`) ends the process without any message to the parent.
- **`Process.flag(:trap_exit, true)` is read where it is written**: in the body of the function that then spawns
  and receives. A process that sets the flag in one function and links in another is not followed (the flag is
  then a gap, the `spawn_link` a linked spawn).
- **The arguments of `spawn(fn -> f(args) end)` are evaluated by the spawner** (contract T9.14), in Elixir by
  the new process: a `self()` written among them is the parent here and the child in Elixir, and a failure in
  them ends the parent. (Not new with the split; the sender does not check it.)
- **Output**: a float is written by Silica's `print_float64`: the whole part and at most 15 decimal places,
  cut and not rounded (`13.333333333333334` comes out as `13.333333333333333`, `3.14159` as
  `3.141589999999999`, `0.1 + 0.2` as `0.300000000000000`; `3.5`, `0.1` and `12.0` come out as in Elixir).
  Elixir writes the shortest text that reads back to the same float; Silica has no builtin that does (its
  builtins that write a float are `print_float16`, `print_float32` and `print_float64`, and none gives a float's
  text as a string: limitation observed, compiler 999916), so the sender has nothing else to send. A comparison
  of the two outputs must read the floats as numbers. `IO.inspect` of a string does not escape
  it (a `"`, a `\` or a control character inside it is written as it is). An atom whose stated type is `atom()`
  is written `:name` by `IO.inspect` also where Elixir writes `true`, `false`, `nil` or quotes the name.
- **A call of a function that receives costs a copy of that function for each place it is called from** with
  code after the call (`withdraw_from__c1`, `withdraw_from__c2`). The copies are small here; a large module
  would grow.

## A static supervisor

**What this sender maps.** A `Supervisor` is Elixir's (OTP's) own construct; the contract has no node that means
"OTP supervisor", and the transpiler knows nothing of `init/1` or a child specification. What the contract has
is the **static child** (T9.14b): a `(:register)` of a `(:spawn)` with literal arguments, which the transpiler
writes into the child list its unit's supervisor has from its start (Silica's `Supervisor` behaviour; BEES A4.4).
`lib/e2s/sup.ex` reads the supervisor and sends that, before the split and before anything is typed:

```elixir
use Supervisor

def start_sup do                                                  # sent as:
  {:ok, _sup} =                                                   #   (:register, "tally",
    Supervisor.start_link(__MODULE__, [], name: Demo.Sup)         #      (:spawn, (:fun_ref "Demo" "counter" 1),
  :ok                                                             #               [(:int 0)], link false))
end                                                               #   with the override on the (:spawn):
                                                                  #      a4_4 chosen restart=transient
@impl true                                                        #                  strategy=one_for_one
def init([]) do                                                   #   then (:symbol "ok")
  children = [
    %{id: :tally, start: {__MODULE__, :start_tally, [0]},         # init/1 and start_tally/1 are not sent:
      restart: :transient}                                        # what they say is in the static child
  ]

  Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 10)
end

def start_tally(start) do
  pid = spawn_link(__MODULE__, :counter, [start])
  Process.register(pid, :tally)
  {:ok, pid}
end

def tally_add(n) do
  send(:tally, {:add, n})                                         # (:send_named, "tally", {:add, n})
  :ok
end
```

| Elixir | What is sent | Where it comes from |
| --- | --- | --- |
| the place of `Supervisor.start_link/2,3` | one static child node for each child of the list, in order | the statement `{:ok, _} = Supervisor.start_link(…)` (or the call alone, not as the last expression) |
| the child list | fixed when the program is sent: `init/1` is **read, not run**. Its parameter is matched against the literal argument of the start; its body is `name = literal data` statements and then `Supervisor.init(children, options)` | `init/1` |
| a child specification | a map `%{id: …, start: {Module, :function, [literal, …]}}`; or `{Module, argument}` / `Module` for this module when it writes a `child_spec/1` of one clause that ends in such a map (read with the argument, `[]` for the bare module) | the child list, `child_spec/1` |
| the child's function and arguments | the `(:spawn)`: the function the start function `spawn_link`s, with the start's literal arguments in place of the start function's parameters | `start: {Module, :function, args}` and the body of the start function |
| the child's name | the name its start function registers it under; with no `Process.register/2`, the `id` of its specification | `Process.register(pid, :name)` / `id:` |
| `restart:` | the override's `restart`, **as written**; not written: `permanent`, OTP's default | the child specification |
| `strategy:` | the override's `strategy`, as written. It has no default: `Supervisor.init/2` raises without one, so a supervisor that writes none is not read | the options of `Supervisor.init/2` |
| the link of `spawn_link` | `link` `false`: the child is under a supervisor, which is what that link is for | |
| `max_restarts:`, `max_seconds:`, `shutdown:`, `modules:`, the `name:` of the supervisor, a child of `type: :supervisor` | not sent (the contract has no place for them; a supervisor child is not read) | |

The session's own `a4_4` choice (for an ordinary `spawn`) is not touched by this: the static child's restart
policy travels in its override.

**What is read.** The module has `use Supervisor` and one `init/1` clause without a guard. The start is
`{:ok, _} = Supervisor.start_link(__MODULE__, literal)` (the module's own name works too; a third argument, the
options, is allowed), the variable `_` or one that starts with `_`. A start function has one clause, variables as
parameters, and the body `{:ok, spawn_link(…)}` or `pid = spawn_link(…)`, an optional `Process.register(pid,
:name)` (or `true = Process.register(…)`), `{:ok, pid}`, where the `spawn_link` is `spawn_link(__MODULE__, :f,
[a, …])` or `spawn_link(fn -> f(a, …) end)` and each `a` is an integer, a float or an atom, or a parameter that
the specification gives such a value. The function the child runs needs an `@spec` whose parameter types the
arguments have. Anything else, and the supervisor is not read: **the start is a gap whose note says which of
these it missed**, `use Supervisor` is a form gap, and `init/1` and the start function are sent as the functions
they are (usually gaps: no `@spec`, lists, `Process.register/2`). A start whose value is used
(`{:ok, pid} = Supervisor.start_link(…)`) stays a call, which is a gap: the supervisor's own pid has no node.

**What is not Elixir's behaviour.**

- **The children exist from the program's start**, not from the call of `Supervisor.start_link`: the unit's
  supervisor is started by `main` (or `to_silica_start()`), with its child list. A child has not run before
  `start_sup/0` is called (where the node stands it is sent its start message), but a message sent to its name
  before that starts it. Calling `start_sup/0` a second time does nothing and answers `:ok`; in Elixir it raises
  a `MatchError` (`{:error, {:already_started, pid}}` does not match `{:ok, _}`). Run: both.
- **The supervisor is no process.** Its children are children of the unit's own supervisor, beside every process
  the module spawns. It has no pid (a start whose value is used is a gap), it cannot be stopped, and
  `Supervisor.which_children/1`, `count_children/1`, `terminate_child/2` and the rest are gaps. Its registered
  name (`Demo.Sup`) is not a name of the output.
- **`:one_for_all` and `:rest_for_one` are not followed**: the unit has one supervisor, whose strategy is the
  session's (`one_for_one` here); the transpiler reports the difference (`T2001`).
- **`max_restarts:` and `max_seconds:` are not carried**: the unit's supervisor allows 100 restarts in 10
  seconds, and when that is passed the whole program ends, not one supervisor.
- **A restarted child is started lazily**: it runs to its first receive when its next message arrives (contract
  T9.14). For a child whose function starts with its receive, as `counter/1`, that is the same. (Run: a scratch
  copy of the example whose counter has a `:crash -> exit(:boom)` clause gives 7, then 0 after the crash, then 5
  after `tally_add(5)`, in Elixir and in Silica.)
- **A send to the name of a child that has ended** (`tally_total()` after `tally_stop()`) ends the calling
  process in both: `ArgumentError` (`:badarg`) in Elixir, `(:explicit, :actor_not_found)` in Silica.
- **A child that is not registered in Elixir has a name here**: the `id` of its specification.
- **The start function is not run.** Only its `spawn_link` and `Process.register` are read: anything else it
  does is a reason not to read the supervisor. `child_spec/1` and `init/1` are read the same way, as data.

`examples/actors.ex` keeps its hand-written supervisor (`supervisor/1`: it traps exits and links its child),
which the split lowers ("Processes: what this sender splits").

## A fn that captures nothing

The transpiler prints a `(:lambda)` only as the function of a `(:spawn)` (contract T9.14): a Silica function
literal captures only integer literals (limitation observed), so a closure has no lowering there. What a `fn`
is in Elixir is this sender's business, and a `fn` that uses no variable of the function around it is a
function of the module in all but name. `lib/e2s/lift.ex` sends it as one, before the split:

```elixir
@spec twice((integer() -> integer()), integer()) :: integer()
def twice(f, x), do: f.(f.(x))

@spec add_ten(integer()) :: integer()                 # sent as:
def add_ten(n), do: twice(fn x -> add(x, 5) end, n)   #   add_ten(n) = twice(&add_ten__f1/1, n)
                                                      #   and the function add_ten__f1/1 (not exported):
                                                      #   add_ten__f1(x) = add(x, 5), typed (integer() -> integer())
```

- **Which `fn`**: one written directly as an argument of a call of a function of this module whose `@spec`
  declares a function type of the fn's arity for that parameter. That `@spec` is where the made function's own
  signature comes from (Elixir writes no type on a `fn`), with strength `declared`. Every clause of the `fn`
  becomes a clause of the function, with its guard.
- **"Captures nothing"** is decided by names, on the safe side: a variable of a clause's body or guard that is
  not among that clause's parameters, and whose name the function around the `fn` also uses, counts as captured.
- **What stays a `(:lambda)`**: a closure (`fn x -> x + n end`), which this sender sends with its function type
  and the transpiler answers with its own gap (`T4002`); a `fn` bound to a variable or returned (nothing types
  its parameters: this sender's gap, "What the codex cannot type"); an argument of a piped call or of a call
  into another module; the `fn` of a `spawn`, which is the contract's own shape.
- The made function is named `<function>__f<n>` (N6). It behaves as the `fn` does: there is nothing here that is
  not Elixir's behaviour.

## Types and conversions

The contract's 8.6 is binding: **the language side decides all data types and all numeric conversions**; the
transpiler prints what it is told. This sender therefore types the program itself, with Elixir's rules, in one
pass while it writes the nodes (`lib/e2s/codex.ex`, "the typing pass"; types in `lib/e2s/codex/types.ex`).

Where the types come from:

| Elixir | Its type | Strength |
| --- | --- | --- |
| a parameter | the `@spec` of its function, taken apart by the clause's pattern | `declared` |
| a literal | `integer()` is `(:t_int, :i64)`, a float `(:t_float, :f64)`, a string `text`, `true`/`false` `boolean`, an atom the one-atom `t_symbols` | fixed by the node, no hint |
| a local variable | the type of what it is bound to, taken apart position by position by its pattern (a tuple, a tagged tuple, the fitting alternative of a union, a struct's fields) | that of the value |
| a call to a function of the module | the result type of the callee's `@spec` (the codex sees the whole module) | `declared` |
| a struct, `p.x` | the struct's `:type` form; the field's type in `@type t` | `declared` |
| an operator, a Kernel function | Elixir's rule (table below) | `inferred` |
| `fn` | `(:t_fun)`: parameters from the function type declared where the fn is written (an argument of a function of the module), none needed for `fn -> … end`; result from its body | `declared` or `inferred` |
| `&name/arity` of the module, `f.(x)` | the function type of the `@spec`; its result type | `declared` |
| a variable bound by a `receive` clause | the type its guard tests: `{:add, n} when is_integer(n)` (also `is_float`, `is_binary`, `is_boolean`, `is_atom`, `is_pid`) | `inferred` |
| `self()`, `spawn`, a `pid()` | `(:t_actor, dynamic)`: Elixir does not type a process's messages | |
| `IO.puts/1`, `IO.inspect/1`, `String.length/1`, `String.upcase/1` and a few more (`stdlib/4`) | by Elixir's documentation | `inferred` |

Elixir construct -> types and conversions sent:

| Elixir | Sent |
| --- | --- |
| `a + b`, `a - b`, `a * b`, both integers or both floats | `(:op, "+", [a, b])`, of that type |
| the same with one integer and one float (`f * n`) | `to_float` around the integer operand: `f * to_float(n)`; an integer **literal** is written as the float literal (`1 + f` is `1.0 + f`) |
| `a / b` | always a float: `to_float` on each integer operand, then `/`, under the zero guard below |
| `x * 1.0`, `x / 1`, `:erlang.float(x)` | `to_float(x) * 1.0`, `to_float(x) / 1.0`, `to_float(x)` |
| `div(a, b)`, `rem(a, b)` | `div`, `rem` on integers, as they are; a float operand is a gap (Elixir raises) |
| `trunc(x)`, `round(x)` | the conversion operators `trunc`, `round` when `x` is a float; `x` itself when it is an integer |
| `floor(x)`, `ceil(x)` on a float | a gap: T8.12 has no such conversion |
| `a == b`, `a < b`, … with one integer and one float | `to_float` on the integer side |
| `a === b`, `a !== b` with one integer and one float | `(:boolean, false)`, `(:boolean, true)` (after the operands, in a block, if one of them is not a variable or a literal) |
| `==`, `!=`, `===`, `!==` between two types that share no value (`s == 1`) | the same constant |
| `<`, `>`, … between two different types; `==` between types that overlap without being one (`String.t() \| nil` and `nil`) | a gap: T8.11 wants one type, and Elixir's term order across types has no operator |
| `and`, `or`, `not` | operands must be `boolean()`; anything else is a gap |
| `<>` | two strings, gives a string |
| `is_integer(x)` and the other type tests, on a variable | in a guard, a test that the variable's stated type answers with true is **not sent** (contract T8.16): `when is_integer(n) and n > 0` is the guard `n > 0`, and `when is_integer(n) and is_pid(from)` is no guard. Anywhere else, and for a test the type answers with false, `(:boolean, true)` or `(:boolean, false)`; the call to `Kernel` when the type does not decide it |
| an argument of a call to the module's own function, a field value of a struct | must fit the declared type; Elixir converts nothing there, so an integer where `float()` is declared is a gap, not a conversion |

Where a hint is written (T8.10): the signature (a); every variable binding, on its `(:var)` node (b); every
operand of an arithmetic or comparison operator that is not a literal, a variable or an operator (c); every
`(:call)`, `(:apply)`, `(:fun_ref)`, `(:record)`, tuple, `(:self)` and `(:spawn)` whose type is known (d); and,
where it is required, a `(:match)`, `(:case)`, `(:cond)`, `(:block)`, `(:receive)`, `(:send)`, `(:field)` that is a
case subject, a match value, a statement whose value is dropped or an operand; the message of a send; the
pattern of each receive clause; the `(:t_fun)` of each `(:lambda)` (e).

**Division by zero** (T8.15). `div` and `rem` by zero raise in Elixir and end the actor in Silica (`badarith`):
nothing is added. Elixir's `/` raises on a zero divisor, and Silica's float division does not fail (limitation
observed, contract Appendix B), so every `/` is sent under a guard:

    cond do divisor == 0.0 -> (:fail, badarith); true -> dividend / divisor end

Each operand is evaluated once: one that is not a variable or a literal is bound first (`_div_1 = …`) in a block
around the `cond`. A literal divisor other than zero needs no guard.

### Known semantic deviations

- **Integer overflow.** Elixir integers have any size; `integer()` is sent as `(:t_int, :i64)` (T8.7), integer
  literals beyond 64 bits are gaps, and **no check is sent around `+`, `-` and `*`**. In Silica an `int64` result
  that passes the range does not fail and gives the wrapped value (limitation observed, contract Appendix B:
  `9223372036854775807 * 4` printed `-4`), where Elixir gives the exact big integer. A program that relies on
  integers beyond 64 bits gives different results. This is a decision of this sender (T8.15 allows stating it).
- **`to_float` beyond 2^53**: Elixir gives the nearest float; the conversion operator gives a float near the
  integer (T8.12). Elixir also compares an integer with a float exactly; here the integer is converted first.
- **`trunc`, `round` of a float that is not a number, is infinite or is outside `int64`**: Elixir gives a big
  integer or raises; T8.12 leaves it undefined, and no guard is sent.
- **Type tests in guards.** `{:add, n} when is_integer(n)` types `n`, and the test itself is not sent (contract
  T8.16; an alternative of `when a when b` is sent whole, with `true` for such a test): the hint (policy `:check`
  for `inferred`) is what checks the value. In Elixir a message that does not pass the
  guard stays in the mailbox; what the transpiler does with a message of another type is its lowering's business.
- **The result of a function is not checked against its `@spec`** (a body that returns an integer where
  `float()` is declared is sent as written).
- **Processes**: selective receive, trapped exits and output have deviations of their own, listed under
  "Processes: what this sender splits".

### What the codex cannot type: gaps

A required type that the codex does not have is never sent as an untyped node. It is a gap whose `construct`
starts with `missing type:` and whose `note` says which type and why, or with `type rule:` when Elixir allows
something that one stated type per operand does not. `mix e2s --gaps file.ex` lists them. The cases:

| Elixir | Gap |
| --- | --- |
| a function without `@spec`, or whose `@spec` uses `term()`, `any()`, `number()`, a list, a map or a user type | the whole function, a `(:gap)` form: `missing type: function signature` (T8.10 a) |
| a struct with a field that `@type t` gives no type | the `defstruct`, a `(:gap)` form: `missing type: struct field`; every construction of it: `missing type: struct` (T8.14) |
| a call to such a function, or into another module (no `@spec` is visible), where its result needs a type | `missing type: operand of +`, `value of a match (=)`, `subject of a case`, `statement whose value is dropped`, `message of a send` (T8.10 c, d, e) |
| a `fn` with parameters that is not written where a function type is declared | `missing type: parameter of a fn` (T8.10 a) |
| a `receive` clause that binds a variable no guard tests, or has a `_` | the whole `receive`: `missing type: message of a receive clause` (T8.10 e) |
| a pattern that binds a variable its value's type does not reach | the `=`, the `case`, or the whole function: `missing type: variable bound by …` (T8.10 b) |
| comparisons across types, `floor/1`, an argument of another type than declared | `type rule: …` (T8.11, T8.12) |

`test/fixtures/gaps.ex` has one of most of these on purpose (5 of its 6 gaps); its header lists them. The two
examples have none. A construct
the split does not cut and an `IO` call it does not lower are gaps of the sender too, with their own notes
("Processes: what this sender splits").

## How to run

Needs Elixir 1.15 or later (built with 1.20.5 on OTP 29).

    mix compile
    mix e2s --dump examples/demo.ex                    # print the frames, send nothing
    mix e2s --gaps examples/demo.ex                    # print only the gaps the sender would send, send nothing
    mix e2s --split examples/actors.ex                 # print the module as the split leaves it, send nothing
    mix e2s examples/demo.ex                           # check mode, 127.0.0.1:7411
    mix e2s --port 7411 --mode transpile examples/demo.ex
    mix e2s --port 7411 --mode transpile --resume intake_1:42 examples/demo.ex   # after a dropped connection
    mix e2s --port 7411 --release intake_1:42          # free a finished transpile session

`--mode` is `check` (the default: the transpiler validates every frame and stores nothing, contract 6.5) or
`transpile`. `--port` defaults to 7411; the host is always 127.0.0.1 (T3.1). Several files may be given; they are
sent in one session. The exit status is 0 when the result is `:ok`, 1 otherwise, 2 for a usage error.

What the sender does on the connection:

- **Credit** (T6.2, T6.3, T6.11a). The welcome gives a window (64 as built). The sender reads replies while it
  sends: before each frame it takes what has arrived, and when its credit is used up it waits for the
  transpiler's `(:stored, next)` and `(:credit, 32)`. It never sends without credit.
- **The output** names the session (`session intake_1:42 (…): 36 of 36 frames sent, from seq 0`; a check session
  has an id of its own kind), the gaps the sender itself sent, every rejection and diagnostic, and the result. A
  session id is text the transpiler chooses (T6.5b); it is used as given.
- **Counts** (T5.3b). `forms` and `units` are counted from the frames sent. If the transpiler counted otherwise it
  does not reject: it sends a `T1002` diagnostic, which is printed, and the session cannot end `:ok`.
- **A `:failed` result has `files 0`** (T6.8); a unit of which nothing could be written is reported by a `T4003`
  diagnostic. In transpile mode `gaps` in the result is the sender's gaps plus the forms the transpiler could
  not write (T6.8a); the sender's own number is on the line above the result.
- **No reply for 30 seconds** (T3.5): the sender closes and says how to resume. `--resume SESSION` sends the same
  hello with the session's id and only the frames from the welcome's `resume_from` (T6.5); a session whose end was
  already stored gets credit 0, nothing is sent and the result follows (T6.5a). A check session cannot be resumed
  (T6.12). Resume was tested against the stand-in listener of the tests only, not against a transpiler.

`mix escript.build` gives the same command line as a standalone `./e2s`.

## Extending this sender

### Add a construct mapping

1. Find the node in the contract (`../contract/tcp-transport-v1.md` 9.4; shapes in
   `../contract/tcp_transport_v1.silica`). If no node fits, do not invent one: emit a gap (below) and write the
   need down.
2. In `lib/e2s/codex.ex`, add a clause of `tr/3` in the group of its node family. The groups are in the
   contract's order: literals and data (H1 to H15); names, matching and control (H16 to H19, H28 to H37);
   processes and messages (H20 to H26); operators (Appendix B); calls. A clause translates its children first
   and then calls `emit(tag, meta, fields, b)`, which appends the node and returns its index, so children always
   come before their parent (T9.2). A call that is really a built-in (`self()`, `spawn/1`, `send/2`) belongs in
   `builtin/5`, `process/5` (the `Process` module) or `erlang/5`. A node kind the codex has not written before
   also needs a line in `@fields` (which of its fields are child indices).
3. `tr/3` takes `:expr` or `:pattern`. Patterns use the same nodes as expressions; add a `:pattern` clause only
   where a pattern differs (as `=` and `^` do).
4. State its type (next section).
5. Add a test in `test/e2s_test.exs`: a mapping test in "mappings added for the sender-side gaps" (a source
   snippet in, the expected nodes out, with `body/1` or `clauses/1`, which run the codex with `strict: false`
   so that a snippet needs no types), and a typing test in "typing (contract 8.6)" (a module with `@spec`s in,
   nodes and hints out, with `typed/1`). Both run every frame through the contract's checker.
6. Run the tests, then check mode (below).

### State a type for a construct

The typing pass is part of `tr/3`: there is no second walk. The builder `b` carries `ty` (node index ->
`{type, strength}`), `vt` (sent variable name -> `{type, strength}`) and `hints` (what will be sent).

1. **Say what the node's type is.** After `emit`, call `typed(b, i, type, strength)`. The type is a nested
   term of `E2s.Codex.Types` (`Types.int()`, `Types.text()`, `{:t_tagged, "ok", [Types.int()]}`, …), built from
   the children's types (`t(b, child)`), or `Types.unknown("why, in a sentence")` when the codex cannot know it,
   or `:never` for a node with no value (`(:fail)`, a gap). Strength is `:declared` when it comes only from an
   `@spec` or `@type`, `:inferred` when the codex worked it out. A node left without `typed/4` is unknown.
2. **State it where the contract requires it.** `state(b, i)` writes the hint if the type is known and the node
   does not fix it itself (T8.9: literals, variables, operators need none). Call it at once for a node kind
   whose type is "only a hint" (as `local/4` does for a call), or leave it to the place that needs it.
3. **Require the children's types the contract requires** (T8.10) with `need(child, "what it is", b)`: it states
   the child's type, or, when there is none, returns a gap in the child's place whose note is the `unknown`
   reason. Use `missing(meta, what, why, b)` to make the whole construct the gap instead, and
   `unruly(meta, what, why, b)` for typing Elixir allows and the contract does not.
4. **A construct that binds variables** gives them types with `assign(pattern, type, strength, b)` (it takes the
   written pattern apart against the type and hints each `(:var)`), then checks `untyped/3`; `match/4`, the
   `case` clause of `tr/3` and `clause/6` show the three uses. A clause-shaped construct passes `types:` to
   `clause/6` and collects what stayed untyped with `collecting/2`.
5. **A new type spelling in `@spec`** is a clause of `Types.from_spec/2`; a new known function of another
   module is a line of `stdlib/4`; a Kernel function a line of `kernel_type/2`.

Nodes that a later decision replaces (an operand of an operator that became a gap, a clause of a `case` that
became a gap) stay in the builder and are dropped by `compact/2`, which sends only what the function's clauses
reach and renumbers; nothing needs to be undone by hand.

### Where conversions are inserted

All in `ruled/5`, which every operator goes through once its operands are written and typed
(`typed_op/4` first turns an operand without a type into a `missing type` gap):

- `to_float/3`: the integer-to-float conversion. It rewrites an `(:int)` literal in place as the `(:float)` of
  the same value and wraps anything else in `(:op, "to_float", [x])`. Called by the arithmetic clause (mixed
  `+ - *`), the `/` clause (both operands) and the comparison clause (mixed `==`, `<`, …).
- `division/4`, `guarded_division/4`: the zero guard of `/`; `once/3` binds an operand that must not be evaluated
  twice, `again/3` writes a second copy of one that may.
- `static/4`: the constant for `===` between an integer and a float and for equality between types that share
  no value.
- `conversion/4` (`trunc`, `round`, `floor`, `ceil`) and the `:float` clause of `erlang/5`, reached from
  `builtin/5`.

A conversion for a new operator is a new `ruled/5` clause: read the operand types, convert with `to_float/3` or
send `unruly/4`, and finish with `plain/5`, which states the operands' types and gives the result its type.

### Change what is split (`lib/e2s/split.ex`)

`E2s.Split.forms/2` takes the quoted forms of a module body (with the codex's literal encoder: a literal is
`{:__block__, meta, [literal]}`) and answers `{forms, gen}`: the forms with every receive (and every call of a
function that receives) in tail position, and what each function it made is made from. It knows no types.
`mix e2s --split file.ex` prints what it does to a file.

- **Which functions wait** (`blocking/2`): a function with a receive, or one that calls such a function (outside
  a `fn`). Only these are touched; any other function's form is passed on exactly as it was parsed.
- **Where a body is cut** (`split_body/3`, `shape/2`, `cuttable?/2`): at the first statement that waits and is
  `p = b` or `b` with `b` a receive, a call of a function that waits, a `case`, a `cond`, an `if` or a block.
- **What is bound first** (`hoist/2`, `hoist_args/2`, `lift/2`): a part that waits inside a call's arguments, a
  tuple, the right side of `=`, a `case` subject or an `if` condition, when everything before it is a variable
  or a literal. `@no_hoist` lists the forms whose arguments Elixir does not simply evaluate left to right. To cut
  at another shape, add it here; until then `unsplit/2` makes it a gap with a note.
- **Which variables are passed on** (`cut/5`, `binders/1`, `pvars/1`): what the statements before the cut bind
  at the top of the body. A new construct that binds for the code after it (or one whose clauses do not) belongs
  in `binders/1`.
- **What a value does at the end of a body** (`wrap_last/3`, `value/3`, `tails/3`): `{:cont, name, args, uses}`
  calls a continuation, `{:notify, parent}` sends the `{:EXIT, …}` message of a linked child. A new kind of
  ending (a monitor's `{:DOWN, …}` message, say) is a new `k` here and in `copy/3`; a new control construct
  whose branches are in tail position is a clause of `tails/3`.
- **Trapping exits** (`trap/2`, `rewrite/2`, `exit_clause/2`), **literals in struct patterns** (`literals/2`).
- In the codex, a made function is typed by `made_sigs/2` and `made_sig/2`, named by `fname/3` (N6), and a call
  of it notes its argument types in `local/4` (`b.calls`). `IO.puts` and `IO.inspect` are `io/4`, `puts_ast/3`
  and `inspect_ast/4`, which build Elixir forms with `{:"$e2s_print", meta, [builtin, argument]}` for each
  print; `tr/3` sends that as `(:sl_call)`. Add a printable type there, and a new builtin to contract T9.16 and
  the transpiler first.
- Add a case to "the split" in `test/e2s_test.exs` (a module with `@spec`s in, the functions and nodes out), and
  the shape to `test/fixtures/split_shapes.ex` with a line of `main/0` and of `@shapes_output`. **What
  `E2s.Split` makes is Elixir.** The test "the split forms … run as Elixir" compiles the split forms of the
  fixture and of `examples/actors.ex` in place of the modules and requires them to print and return what the
  modules do: a change to the splitter that changes a program's behaviour fails there, before any transpiler is
  involved. (The linked copy is written so that this holds: the parent is bound before the spawn, because
  `self()` inside the `fn` would be the child.)

### Change what is read of a supervisor (`lib/e2s/sup.ex`) or which `fn` is lifted (`lib/e2s/lift.ex`)

Both run on the quoted forms before the split, in `unit/5` of the codex: `E2s.Sup.forms/2`, then
`E2s.Lift.forms/1`, then `E2s.Split.forms/2`. Neither knows a type.

- `E2s.Sup` answers the forms with each supervisor start replaced by one call of `:"$e2s_static_child"` for each
  child (name, restart, strategy, the function the child runs, its literal arguments), which `static_child/7` of
  the codex turns into the `(:fun_ref)`, the literal arguments, the `(:spawn)`, the `(:register)` and the
  override. To read another way of writing a child, add a clause to `specification/3` (what a list element is),
  `start_body/1` (what a start function may do) or `spawned/2` (how it spawns); every way out is a `no/1` with
  the sentence the gap's note will carry, and each has a row in the test "a supervisor that cannot be read".
  `data/3` is the whole of what "literal data" means.
- `E2s.Lift` answers `{forms, lifted}`; `lifted` gives each made function's base and suffix for `fname/3` (N6).
  The made function gets an `@spec` form of its own, copied from the function type the callee's `@spec`
  declares, so the codex types it as any source function. To lift in more places, give `walk/4` another case
  that knows the function type; `captures/2` is the test that keeps closures out.

### Emit a gap

A construct that is not translated is never left out (T9.10): call `gap(meta, "construct name", b)` for an
expression or pattern (a `:gap_node`, H40; `gap/4` takes a note that says why), and return
`form_gap(name, meta, file, construct, note)` for a whole declaration (a `:gap` form). The session still completes
and the transpiler counts the gap.

### Names

`lib/e2s/names.ex` is the only place a name is spelled. The scheme is the same in the three senders:

| | What | Spelling | Example |
| --- | --- | --- | --- |
| N1 | `silica_unit` | prefix `ex_`, then the module path, each segment in snake case, joined with `_` | `MyApp.HTTPServer` is `ex_my_app_http_server` |
| N2 | `unit_name`; `module` of `(:call)` and `(:fun_ref)` | the module name as written, unchanged (T5.2) | `Actors.Account`, `IO`, `erlang` |
| N3 | type names: `:type` form, `t_named`, `(:record)` | a struct is named after its module, N1 without the prefix | `Actors.Account` is `actors_account` |
| N4 | function, variable and field names | `ident(name)`, below; a function name defined at more than one arity gets `__<arity>` | `add` is `add`, `empty?` is `empty__q`, `fetch!` is `fetch__b`; `add/1` and `add/2` are `add__1` and `add__2` |
| N5 | symbols: `(:symbol)`, `t_symbols`, `t_tagged` | the atom's text, unchanged | `:EXIT` is `EXIT`; the module `Foo.Bar` as a value is `Elixir.Foo.Bar` |
| N6 | a function this sender made (the split; a lifted `fn`) | the sent name of the function it was made from, then `__k<n>` (its n-th continuation), `__c<n>` (its n-th copy), `__l` (its linked copy) or `__f<n>` (its n-th lifted `fn`) | `main__k1`, `withdraw_from__c1`, `withdraw_from__c1__k1`, `account__l`, `add_ten__f1` |

`ident` never writes `__k`, `__c`, `__l` or `__f` (it writes `__` only before `q`, `b`, `e`, `x` and, for an arity, a
digit), so an N6 name is no source function's name.

Snake case puts `_` between a lowercase letter or digit and an uppercase letter, and between an uppercase letter
and an uppercase letter that a lowercase letter follows, then lowercases. N1, N3 and N4 always give an identifier
of letters, digits and `_`. N5 does not have to: making a symbol a Silica atom is the transpiler's work (H5,
BEES A6.3).

**`ident(name)` is injective**: two source names never get the same sent name, and a decoder reads the source
name back (it is in the tests, with a few dozen awkward names). The name's characters are taken left to right:

- `[A-Za-z0-9]` is kept;
- `?` is `__q`, `!` is `__b`;
- `_` is kept as `_` only when the character before it is not `_` and the character after it (if any) is neither
  `_` nor a character that is escaped; every other `_` (next to another `_`, or directly before an escaped
  character) is `__x5f_`;
- any other character is `__x<lowercase hex code point>_`;
- the empty name is `__e`; a name that starts with a digit has that digit escaped as `__x3N_`.

So `__` appears in a sent name only where an escape starts, and ordinary names (`add`, `sum_list`, `is_ok`) are
unchanged. `valid?` is `valid__q`, which no other name can be: a source name `valid__q` is sent as
`valid__x5f___x5f_q`.

**Arity.** Elixir tells `add/1` from `add/2`; the contract's function name does not carry the arity in every
place. When a module defines a function name at more than one arity (default arguments define several), **every**
arity of that name is sent as `<ident(name)>__<arity>`: in the form's `head.name`, in local calls, in
`(:fun_ref)` and in the `(:entry)` form. A name with one arity is unchanged. `__` followed by a digit is never an
escape, so the result is still injective.

What remains for names:

- **Silica's reserved words and builtins, and `main`, are not handled here.** A function called `send`, `case`
  or `main` is sent under that name; the transpiler reports it. (The name rule is not a contract decision yet.)
- A call into **another module** is spelled with `ident` alone: this codex does not know at how many arities the
  other module defines the name, so a function that its own unit sends as `add__2` is called as `add` from
  outside. The contract has to say how a cross-unit call names an arity.
- A function called through a computed name (`mod.fetch!(x)`, H34) carries its name as a symbol, so `fetch!`,
  while the function's own form is named `fetch__b`.
- Generated variable names (`x_1` for a rebinding, `_pin_1`, `_div_1`, `_io_1`, `_truthy`; the split's
  `e2s_k1`, `e2s_h1`, `e2s_v1`, `e2s_s1`, `e2s_x1`, `e2s_p1`, `e2s_r1`; the output lowering's `e2s_i1`) avoid
  the names the source uses, but are not marked as generated.

### Run the tests

    mix test                          # offline
    TO_SILICA_PORT=7411 mix test      # also the two check-mode sessions with a transpiler on that port

The offline tests need no transpiler. They check that every frame made from the two examples and from every
snippet passes the contract's Erlang binding checker (`../contract/bindings/erlang/check_frame.erl`, compiled
into the test build), that children come before parents, that `seq` counts from 0, that no atom stands where an
identifier goes, that `examples/demo.ex` uses every node kind of the subset but links and exit requests and has
no gap, that `test/fixtures/gaps.ex` has exactly 6 gaps (5 of them for a type the sender cannot state), that the
same source gives the same bytes, one test per mapping and one per
typing rule, and, over both examples, that every node T8.10 requires a type for has one and that no arithmetic
operator has an integer next to a float. `examples/actors.ex` is also run as Elixir and its output compared;
"a static supervisor" reads `examples/demo.ex` and small supervisors (what is sent for each way of writing a child,
the reason in the gap for each supervisor that is not read), runs `examples/demo.ex` as Elixir (the supervisor
starts, its child answers by its name and stops) and holds the lifting of a `fn` to its rules;
"the split" has one test for each thing the split and the output lowering send, and compiles the split forms
of `examples/actors.ex` and of `test/fixtures/split_shapes.ex` as Elixir and compares what they print. The
sender (credit, a window of 64 with more than 64 frames, resume) and `release/3` are run against a small stand-in
listener inside the test (it is not a transpiler). The two online tests are reported as skipped when
`TO_SILICA_PORT` is not set.

### Run check mode and transpile mode

    mix e2s --port 7411 examples/actors.ex                     # check mode: every frame validated, nothing stored
    mix e2s --port 7411 --mode transpile examples/actors.ex    # transpile mode: prints diagnostics and the result

Accept a change only when the check-mode session ends `result: :ok` with 0 rejected (contract 0). The first line
of the output names the session (`session intake_1:42 (…)`); a transpile session keeps its storage until it is
released. Check mode validates shapes, indices and hints; whether the typing is complete and consistent
(`T3101` to `T3104`, T8.13) only a transpile session says. Those diagnostics should only ever mean a fault of
this sender: a type it cannot state is sent as a gap, not left out.

### Release a session

    mix e2s --port 7411 --release intake_1:42

sends `(:release, { session })` as the first and only frame of a new connection (M7, T6.13) and prints the
answer: `released: session intake_1:42, freed true` (exit status 0), or `freed false` when the session is unknown
or not finished (exit status 1). The session id is the text the transpile session's first line and result named
(T6.5b). From code: `E2s.Sender.release("127.0.0.1", 7411, "intake_1:42")` returns
`{:ok, %{session: "intake_1:42", freed: true}}`. If the transpiler closes the connection without answering, the
command says so and exits 1 (`{:error, :closed_without_reply}`). Release a session only after its output is exported
(T6.14); a session that is not released keeps one of the transpiler's storage regions, and when every region is
held the next transpile session is refused `:busy`.
