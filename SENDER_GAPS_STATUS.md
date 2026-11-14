# Sender-side gaps: status

2026-11-13 (newest update first: 2026-11-14, the Gleam examples have no gap; before it, the Elixir examples have no gap; before that, a static supervisor). This file follows up the sender-side rows of [APP_GAPS.md](APP_GAPS.md) and its "Sender and contract
side" summary. Only `erlang-to-silica-poc/`, `elixir-to-silica-poc/` and `gleam-to-silica-poc/` were changed.
`silica-sink/` and `contract/` were not touched (they were being reworked by someone else), and nothing was changed
in `../silica` or `../project-bees`. Nothing was committed.

## Update: the Gleam examples have no gap (2026-11-14, after the Elixir ones)

User direction: the Gleam example programs are to be transpiled with result `ok` and no gap, as the Erlang and
Elixir ones are, with the same decisions: the deliberate gap examples leave the examples (they are in
`gleam-to-silica-poc/test/fixtures/gaps.gleam`, which the tests read), the examples are simple idiomatic Gleam,
and the `gleam_otp` static supervisor of `actors.gleam` is sent as static children. Changed in this step: **the
Gleam sender, its two examples and its tests only**, and wording in documents (the "16 significant digits" of
`print_float64`, which was wrong everywhere it stood: it writes at most 15 decimal places, cut and not rounded).
**No contract rule and no schema change; `silica-sink/` was not touched** (no printing was missing); nothing in
`../silica` or `../project-bees`; nothing committed.

| Program | Result | `counts.gaps` | Sender gaps | Calls compared | Match | Mismatch | Fail in both | Stub |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Gleam `demo.gleam` | **`ok`** (was `partial`) | **0** (was 8) | 0 (was 3) | 47 | **46** | 0 | 1 | 0 |
| Gleam `actors.gleam` | **`ok`** (was `partial`) | **0** (was 4) | 0 (was 3) | 17 | **17** | 0 | 0 | 0 |

(`actors.gleam`: 14 calls of its pure functions and the 3 lines its `main` prints when the unit runs as the
program, the same three lines as `gleam run -m actors`. `demo.gleam`: the one that fails in both is
`positive(-1)`, a `panic`; beside the 47, `ping_pong(41)` called as an ordinary function fails in Silica by
design, contract T9.13, and is counted apart; spawned, it gives 42 in both. Warnings: `T2001` once for each unit
(`a3_4`, `a3_2`), `T4004` once for `demo.gleam` and twice for `actors.gleam`. The fixture `gaps.gleam`: 7 gaps
sent, result `partial` with 11.)

| Gap (before) | Whose it was | Resolution |
| --- | --- | --- |
| `demo`: `add_four/1`, `pipeline/1`: a `(:lambda)` | transpiler (no closure) | **sender**: `lift.gleam` sends a function literal that captures nothing as a function of the module and a `(:fun_ref)`, where a function of the module declares the function type (as `lift.ex`); a capture with literal arguments (`add(2, _)`) the same way. A real closure is in the fixture |
| `demo`: `receive_message` (an external), and the `T4002` of its two callers | sender (foreign code) | **example**: the process part is written with `gleam/erlang/process` (`process.spawn_unlinked`, `send`, `receive`), which the split lowers. The external receive is in the fixture |
| `demo`: `start_linked/0` (a linked spawn, a link) | transpiler (T9.15) | **example**: left out; in the fixture |
| `demo`: `count/1` (`list.length`), `second/1` (tuple index), `is_distributed` (inter-node) | transpiler (T9.9) / sender | **example**: left out; in the fixture |
| `actors`: `start_auditor/1`, `start_supervisor/1` (the type `process.Name`), `process.new_name` in `start_audit/0`, and the `T4002` of `main` calling it | sender | **sender**: `sup.gleam` reads the static supervisor (`static_supervisor.new(strategy) \|> add(supervision.worker(fn() { … }) \|> supervision.restart(…)) \|> start`, the actor `actor.new(literal) \|> actor.named(name) \|> actor.on_message(handler) \|> actor.start`) and the codex sends each child as a static child (T9.14b) with the restart and strategy **as written** in an A4.4 override; a name is read where it is made (`let n: Name(M) = process.new_name("literal")`, one for a message type in a unit) and is the symbol of its literal; a send to `process.named_subject(n)` is a `(:send_named)` (T9.14c). The example passes the `Name` where it passed the subject, writes `supervision.restart(supervision.Transient)` explicitly, and the auditor's state is an `Int` (a static child's arguments are literals) |
| (new, met when `main` ran) `T4002` on the unit: `main`, exported, reaches a process function as an ordinary function | transpiler rule T9.13 | **sender**: a public function with a receive of its own keeps it (it is a process function, as in the other two senders' examples); a public function that waits only in a function it calls is sent as not exported (`main`: the entry form still names it) |

What a supervisor must look like to be read, and what is not Gleam's behaviour (the children exist from the
program's start, the supervisor is no process, a name is its statement, a named subject is no value, the
strategy and the restart tolerance are not followed): `gleam-to-silica-poc/README.md`, "A static supervisor".
A supervisor that cannot be read is a gap whose note names the rule the source missed.

**What was run** (default build of the sink as it stands, port 7494; compiler 999916; Gleam 1.19.2): both
examples, the fixture and a scratch crash variant in transpile mode, exported, released (`freed true`); both
example units compiled with a driver and run, and the same calls run in Gleam; `actors` also run as its own
program; the scratch variant of the auditor with a `Crash -> actor.stop_abnormal("boom")` clause, run as a
program in both (2 notes before the crash, 0 after it, 1 after one more note: the static child is started again
from its literal state under the same name); `test/run_test.sh` offline (63 passed, the check-mode session
skipped) and with the port (63 passed), and with `TO_SILICA_RELEASE_PORT` (63 passed). **Not run:** restart
`Temporary` and `Permanent` and the strategies `OneForAll` and `RestForOne` end to end (the override is tested
offline), two static children in one unit, a send to a name before the start is reached, a float state.

**Open, for the user:** (1) the session's `a4_4` is still `restart=transient` for an ordinary `spawn` in all
three senders (a Gleam process outside a supervisor never restarts: `temporary` would say that); the example
writes its own restart explicitly, the session default was not touched. (2) Sending a public function that waits
through a call as not exported is this sender's reading of T9.13; a contract sentence could say it (or the
transpiler could leave out the ordinary version of the entry). (3) One name for a message type in a unit is
this sender's rule; a contract node for "the process registered under a name" (a `whereis`) would let a named
subject be a value. (4) A function whose result is a union and whose last expression is its receive (`fn ask()
-> Result(a, Nil)`), sent as a process function, does not compile (`E2005`, limitation observed, HOWTO 6a); the
example avoids it because `ask` and `notes` are private and every call is replaced by a copy.

## Update: the Elixir examples have no gap (2026-11-14, last)

User direction: the Elixir example programs are to be transpiled with result `ok` and no gap, as the Erlang ones
are, with the decisions already made for Erlang: the deliberate gap examples leave the example, the example is a
well-formed idiomatic program, and the hand-written supervisor of the demo becomes a **static** supervisor.
Changed in this step: **the Elixir sender and its example `demo.ex` only** (and one "as built" note and two
mentions in the contract: no new rule, no schema change). `silica-sink/` was not touched (no printing was
missing), nothing in `../silica` or `../project-bees`, nothing committed.

| Program | Result | `counts.gaps` | Sender gaps | Calls compared | Match | Mismatch | Fail in both | Stub |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Elixir `demo.ex` | **`ok`** (was `partial`) | **0** (was 8) | 0 (was 6) | 55 | **53** | 0 | 2 | 0 |
| Elixir `actors.ex` | `ok` | 0 | 0 | 35 | **35** | 0 | 0 | 0 |

(Beside these, each driver still calls process functions as ordinary functions, 1 call in `demo.ex` and 5 in
`actors.ex`: they fail in Silica by design, contract T9.13, and are counted apart. The two that fail in both:
`ratio(7, 0)`, and `tally_total()` after `tally_stop()`. `actors.ex` gets 4 `T4004` warnings, the selective
receive that is not kept; `demo.ex` none. Both get the `T2001` of the choices `a3_4` and `a3_2`.)

### Each gap of `demo.ex`, and what was done about it

| Gap (before) | Whose it was | Resolution | Kind |
| --- | --- | --- | --- |
| `supervise/1`: a hand-written supervisor (trap_exit, spawn_link); it was sent, and no driver could reach its child | example | replaced by Elixir's `Supervisor`: `use Supervisor`, `start_sup/0`, `init/1` with one child registered as `:tally`, `start_tally/1`, `tally_add/1`, `tally_total/0`, `tally_stop/0`. Sent as a static child (T9.14b) and `(:send_named)` (T9.14c) | (a) example, (b) sender: `lib/e2s/sup.ex` |
| `add_ten/1`: `twice(fn x -> add(x, 5) end, n)`, a `(:lambda)` the sink does not print | sink (closures) | the sender sends a `fn` that captures nothing as a function of the module (`add_ten__f1/1`, its type from `twice/2`'s `@spec`) and a `(:fun_ref)`. The example is unchanged | (b) sender: `lib/e2s/lift.ex`; an "as built" note at H36 |
| `boxed/1`: a `fn` bound to a variable, whose parameter nothing types | sender (deliberate) | removed from the example | (a) |
| `max_of/2`: no `@spec` | sender (deliberate) | given its `@spec` | (a) |
| `area/1`: `number()` | sender (deliberate) | floats throughout (`float()`), as in `demo.erl` | (a) |
| `name_or/2`: `String.t() \| nil`, and truthiness of it | sender (the `=:=` across types) and sink (a union with `nil`) | removed from the example | (a) |
| `stop_counter/1`: `Process.link/1` on a process that exists | sink / contract T9.15 | removed from the example | (a) |
| `sum_list/1`: a list type | sender (it maps no lists) | removed from the example: the user's rule is "lists only as already mapped", and this sender maps none (the Erlang and Gleam senders do; mapping them here is open sender work) | (a) |
| `shout/1`: `:rpc.call` | out of scope by rule (inter-node) | removed from the example | (a) |

What left the example is in `test/fixtures/gaps.ex`, which the sender's tests of gaps now read (the same 6
sender gaps; sent in transpile mode it is `partial` with 8 gaps, as the old `demo.ex` was).

**No contract rule was needed** ((c): none) and **no sink printing was missing** ((d): none): the static child,
the send to a name and the function reference were all there. The contract got a note under H36 (what the sink
writes of a `(:lambda)`, and that a function literal without captures can be sent as a function and a
`(:fun_ref)`), and Elixir is named beside Erlang in T9.14b's "What it is for" and in the status line.

### The Elixir sender's static supervisor (`lib/e2s/sup.ex`)

The same decision as for Erlang (the section below): `(:register, name, (:spawn …))` with literal arguments and
an `a4_4` override that carries `restart` and `strategy` **as the source writes them**; the sink knows nothing
of Elixir. What differs is how the supervisor is read, because the language differs:

| | Erlang (`e2s_sup.erl`) | Elixir (`E2s.Sup`) |
| --- | --- | --- |
| the mark | `-behaviour(supervisor)` | `use Supervisor` |
| the start | `{ok, _} = supervisor:start_link([Name,] ?MODULE, Args)` | `{:ok, _} = Supervisor.start_link(__MODULE__, arg[, opts])` |
| `init/1` | evaluated (`erl_eval`, no calls) | **read as data, nothing is run**: its parameter matched against the argument, `name = literal data` statements, then `Supervisor.init(children, opts)` |
| a child | a map or the six-element tuple | a map `%{id:, start: {M, f, args}, restart:}`; `{Module, arg}` or `Module` for this module with a `child_spec/1` that ends in such a map |
| `restart` not written | `permanent` (OTP) | `permanent` (OTP) |
| `strategy` not written | `one_for_one` (OTP) | **not read**: `Supervisor.init/2` raises without one, so there is no default to take |
| the start function | `Pid = spawn_link(…), [true =] register(Name, Pid), {ok, Pid}` | `pid = spawn_link(…)`, `[true =] Process.register(pid, :name)`, `{:ok, pid}` |
| a supervisor that is not read | one general note | the gap's note says **which rule it missed** (10 reasons are tested) |

Not carried, as for Erlang: `max_restarts`, `max_seconds`, `shutdown`, the supervisor's own name and pid, a
child that is a supervisor, a strategy other than the session's (`T2001`).

### Floats: is there a shortest round-trip form in Silica?

No (compiler 999916: limitation observed). The builtins that write a float are `print_float16`, `print_float32`
and `print_float64`, and no builtin gives a float's text as a string or takes a precision (the builtin names the
sink knows are in `silica-sink/DECISION_DATA_printer.md` and in the printer's list of reserved names;
`../silica/docs` names no other). `print_float64` writes the whole part and **at most 15 decimal places, cut, not rounded** (it stops earlier
when nothing is left): `40.0 / 3.0` is written `13.333333333333333` (Elixir: `13.333333333333334`), `3.14159` is
written `3.141589999999999`, `2.0 / 3.0` `0.666666666666666`, `0.1 + 0.2` `0.300000000000000`; `0.1`, `0.3`,
`3.5`, `5.0` are written as Elixir writes them; a whole part beyond the 64-bit range is written as
`9223372036854775807` (`1.0e22`). (Measured in this step with a ten-line program; the documents said "16
significant digits" until then, and every place that did was corrected on 2026-11-14.)
Writing the shortest form in Silica itself would be the sink's or a
library's work (an algorithm such as Ryu over `float64_bits`), not a sender's. So the example is as it was, the
README says so, and **the comparison reads floats as numbers** (scratch `exzero/compare2.py`: two lines match
when they are equal once each float in them is read as a number, to one unit of the 15th decimal place plus the
float's own precision). With that, `mean_move(40, 3)`, the report's mean, line 4 of `Actors.main/0` and
`area({:circle, 1.0})` match; the first three were the one mismatch of before.

### The `T4002` note of a function only processes run (proposal P15)

Neither example gets it: `counts.gaps` is 0 for both. It is still given to
`test/fixtures/split_shapes.ex` (result `partial`, 1 gap, no sender gap): there, source functions that hold no
receive of their own end in a tail call of a made copy (`get__c1/0`, …), and the sink writes an ordinary
version of each that calls a process function. The minimal rule that would remove it is P15 as it stands (a
sender marks a function as a piece of a process, and the sink writes no ordinary version of it); a rule in
the other direction (the sink does not count the note as a gap when the function is exported) would hide a
call that does fail. Nothing was changed for it: no example needs it.

### What differs from Elixir (the README has each: "A static supervisor", "Processes: what this sender splits")

| Difference | Run? |
| --- | --- |
| the static child exists from the program's start, not from `Supervisor.start_link` | stated (T9.14b) |
| a second `start_sup()` answers `:ok` and does nothing; Elixir raises `MatchError` (`{:error, {:already_started, pid}}`) | **run**, a scratch copy |
| a child that fails is started again under its name with its first state: 7, then 0, then 5 after `tally_add(5)` | **run**, the same in both (scratch copy with a `:crash -> exit(:boom)` clause) |
| a send to the name after the child has ended normally ends the caller: `ArgumentError` in Elixir, `(:explicit, :actor_not_found)` in Silica | **run** (a row of the table: fails in both) |
| the supervisor is no process: `Demo.Sup` is no name, no pid, no `which_children`, no stop | stated; a use is a gap |
| `max_restarts: 3, max_seconds: 10` are not carried (100 restarts in 10 s) | stated; not run |
| a float is printed with at most 15 decimal places, cut | **run** (above) |
| `actors.ex`: selective receive is not kept (`T4004`, 4 functions); a trapped exit only for an end the source writes | as before; the example is not affected |

### What was run (default build of the sink as it stands, compiler 999916), and what was only written

**Run:** both examples sent in transpile mode, exported, compiled, linked with the scratch drivers
(`exzero/drv/ex_demo.body`, `ex_actors.body`), run, and compared call by call with `elixir` against the real
modules (`exzero/native/*.exs`); `Actors.main/0` as the unit's own program (Elixir's five lines, the float as
above); the crash copy and the second start; the two fixtures sent in transpile mode
(`split_shapes.ex`: `partial`, 1 gap, its `main` prints Elixir's 16 lines; `gaps.ex`: `partial`, 8 gaps);
`mix test` offline and with `TO_SILICA_PORT` (96 tests offline, 0 failed, the 2 online ones skipped; 98 with `TO_SILICA_PORT`, 0 failed: check-mode sessions of `demo.ex` (0 gaps) and of the fixture `gaps.ex` (6 gaps), and of `actors.ex`). The sink was not rebuilt or
re-tried: none of its sources changed (the build used is the one of the static-supervisor step).
**Written, not run:** `permanent` and `temporary` static children and `{Module, arg}` children in a program
(the tests hold what is sent for them); a strategy other than `one_for_one`; the restart limit; a message to
the name before the start is reached; two children in one supervisor in a program; a lifted `fn` of several
clauses in a program (`add_ten__f1/1` of one clause was run). The Erlang and Gleam senders were not touched
and their suites not run.

## Update: a static supervisor (2026-11-14, later)

User direction: the hand-written supervisor `supervise/1` of `erlang-to-silica-poc/examples/demo.erl` (it trapped
exits and linked its child; a driver could not reach the child, so it was never run) is replaced by a real
static supervisor: OTP's `supervisor` behaviour, whose `init/1` answers the child list, with the counter as its
one child, registered as `tally`. Changed in this step: the Erlang sender, **the contract (two numbered rules,
no schema change)** and **the sink (it prints two node kinds it did not print)**. Nothing in `../silica` or
`../project-bees`; nothing committed. `examples/actors.erl` still has its hand-written supervisor
(`supervisor/2`: `process_flag(trap_exit, true)`, `spawn_link`, a receive of `'EXIT'`), lowered as before; it was
left as it is.

### The decision, and why

**Decision.** A supervisor whose child list is fixed at its start is sent with nodes the schema already had:
for each child a `(:register, name, process)` (H38) whose `process` is a `(:spawn)` (H21) with literal
arguments, and an `a4_4` override (T7.6) on that `(:spawn)` for the child's own `restart` and its supervisor's
`strategy`. The contract's new rule **T9.14b** says that this pair is a **static child**: the transpiler writes
it into the child list that the unit's supervisor has from its start (Silica: the list `init` answers), with
`name` as child id and registered name. **T9.14c** says what a `(:send_named)` (H39) is. The schema unit
`contract/tcp_transport_v1.silica` and `contract/bindings/erlang` are unchanged (no recompile of the schema was
needed, the goldens are as they were).

| Considered | Taken? | Why |
| --- | --- | --- |
| the new node of proposal P8, `(:supervise, children, { strategy, restart, max_restarts, period })`, whose value is the supervisor's process | no | a schema change (the node sum is written three times in the schema unit; bindings and goldens follow), and it promises more than can be printed: in Silica a unit is one `impl <unit> for Supervisor` with one `init`, so a second supervisor of the same unit cannot be written, and one in another unit could not exchange messages with the unit's processes (T9.12: one message sum for a unit). A supervisor "process" with a value has nothing behind it |
| a new form `(:supervisor, …)` beside `(:function)`, `(:type)`, `(:entry)` | no | declarative and honest, and still a schema change; the existing nodes say the same thing |
| the low-level layer (L3 `(:sl_spawn_child)`, L7 `(:sl_behaviour)`) | no | L3 adds a child with an id from a pool while the program runs, which is the opposite of static; and a sender would have to know the names of the sink's generated behaviour and phases |
| the sender lowers the supervisor to an ordinary `(:spawn)` (the child is added by the unit's spawner when the start is reached) | no | it runs, and it is not what was asked: the child would not be in the supervisor's list at its start, would have a pool id and no name |
| **`(:register)` of a `(:spawn)` with literal arguments, the restart in an `a4_4` override** | **yes** | the high-level nodes already say it ("a new process under a supervisor, with a name, with this restart policy"); how it is written is the transpiler's (contract §7.1), and in Silica a supervised actor that has a name **is** a child whose id is the name; literal arguments are what makes it possible to write it into `init`. The rule is numbered and stated, so nothing is bent silently: before it, no `(:register)` was written at all |

**Who decides what** (contract §1, §8.6, T9.13a). The sender: which source construct is a static supervisor,
what its child list is (`e2s_sup` evaluates `init/1`), which function a child runs, its name, and its `restart`
and `strategy` **as the source writes them** (OTP's defaults where it writes none: `permanent`,
`one_for_one`). The sink: nothing about Erlang or OTP; it prints the node pair as a row of `init`.

**Restart and strategy: what the contract allows.** Per static child: `restart` `permanent`, `transient` or
`temporary`, from the override; the session's `a4_4` `restart` (the senders' `transient`, for ordinary spawns)
is not involved and was not changed. `strategy`: carried in the override, followed only when it is the
session's (the unit has one supervisor); another one gets a `T2001`. **Not carried at all:** `intensity` and
`period` (BEES A4.4 has `restart` and `strategy` only; the unit's supervisor allows 100 restarts in 10 s),
`shutdown`, a child that is itself a supervisor. Whether these get parameters is the contract owner's decision.

**What it does not keep** (the sender's README, "A static supervisor", has the list): the children exist from the
program's start and not from the call of `supervisor:start_link`; the source's supervisor is no process of the
output (no pid, no stop, no `which_children`); a restarted child runs to its first receive when its next message
arrives.

### What was changed

- **Contract** (`contract/tcp-transport-v1.md`): T9.14b, T9.14c (new); H38 and H39 rows ("as built", their
  values); T7.5 (the one override that is read); T9.11 (child ids the transpiler makes); T9.14 and §9.2 (a
  pointer each); the status line.
- **Sink**: `ts_print` (`register_ex`, `send_named_ex`, `send_ex` with a name, `override_a4_4`, `static_rows`,
  `static_ids`; the printer's context carries the form's overrides), `process_runtime.silica.tmpl`
  (`to_silica_static`, `to_silica_send_named`, the rows of `init`, `to_silica_is_static` for the warden), design
  §5.5, trial `p4_processes` (two static children, two sends to a name, a restart under the name, and the two
  things that are not written).
- **Erlang sender**: `src/e2s_sup.erl` (new), `e2s_codex` (`static_child/7`, H39 for `name ! Message`, overrides in
  the builder, the gap notes for an unreadable supervisor and for `register/2`), `examples/demo.erl`
  (`supervise/1` removed; `start_sup/0`, `init/1`, `start_tally/1`, `tally_add/1`, `tally_total/0`,
  `tally_stop/0`), tests (`supervisor/0`: 8 cases; two mappings; three demo cases, one of which runs the module
  as Erlang), README ("A static supervisor": what the sender maps, what is read, what is not Erlang's
  behaviour).
- `HOWTO_language_creators.md` §6a: one bullet for a language creator.

### Proposals this touches

- **P8** (supervisors): **partly done another way.** A static supervisor needs no `(:supervise)` node (above).
  Still open from P8: restart intensity (a parameter of `a4_4`, or of the override), a strategy other than the
  unit's, a supervisor as a process (stop it, list its children), supervisors under supervisors, and how `link`
  true on a `(:spawn)` acts together with a restart.
- **P1** (trapping exits): unchanged. The hand-written supervisor of `actors.erl` (and of the Elixir examples)
  still needs the sender's linked copy.
- The Gleam sender's `static_supervisor` gap (G2) could now be sent the same way where the child's name is a
  literal; a name made at run time (`process.new_name`) still has no node. Not done here.

### What was run (default build of the sink, compiler 999916)

| What | Result |
| --- | --- |
| the Erlang sender's tests | 137 tests (133 offline, 4 online in check mode), 0 failed. New: 8 `sup:` cases, 2 mappings (H39; `register/2` outside a start function is a gap), 3 `demo:` cases (one runs `demo.erl` as Erlang: the supervisor starts, the child answers 7 by its name and stops normally) |
| `demo.erl`, transpile mode | 34 frames, `ok`, 0 gaps, 0 rejected, 1 file; `T2001` for `a3_4` and `a3_2` as before |
| the unit compiled, linked with a driver, run; the same calls in Erlang | **43 calls, 43 match**: the 37 of before and `start_sup()` `ok`, `tally_add(3)` `ok`, `tally_add(4)` `ok`, `tally_total()` `7`, the driver's own `tally ! {get, self()}` `7`, `tally_stop()` `ok` |
| after the stop, `tally_total()` again | the calling process ends in both: `badarg` in Erlang, `(:explicit, :actor_not_found)` in Silica |
| a scratch copy whose counter has a `crash -> exit(boom)` clause | Erlang: 7, then after the crash 0 (restarted, a new pid, registered again), then 5 after `tally_add(5)`. Silica: 7, 0, 5; the failure report says `(:explicit, :boom)` |
| the sink's trial suite | the sink's trial suite once, `silica-sink/trials/run_trials.sh <work> 7495 all` (default build, memory and backing store): all trials passed, 172 `ok` lines, 0 `FAIL` (p0 20 cases, 23 goldens, p2 on both stores, p1, p3, p4 with the static children, the restart after `kill -9`, the orderly end) |

**Not run:** `permanent` and `temporary` static children in a program; a message to the name before the start
is reached; a second `start_sup()`; the restart limit; two supervisors or two children in one module (the
trial has two static children in one unit, one never reached); the Elixir and Gleam senders (unchanged).
The details and the table are in `silica-sink/STATUS.md`, "a static supervisor".

## Update: the Elixir and Gleam senders split processes too (2026-11-14)

The table "What the Elixir and Gleam senders would need" of the update below is now done, in the two senders
only: `silica-sink/` and `contract/` were not changed in this step (no rule was added; `HOWTO_language_creators.md`
§6a gained what the two senders taught), nothing in `../silica` or `../project-bees`, nothing committed.

**Elixir** (`elixir-to-silica-poc/README.md`, "Processes: what this sender splits"; the rewriting is
`lib/e2s/split.ex`, on the quoted forms, before the codex types anything):

| Elixir | Sent as | State |
| --- | --- | --- |
| a receive with code after it (`account = receive do … end`), several receives, a receive inside a clause of `case`, `cond`, `if`, `receive` | the receive in tail position; the rest as a continuation `f__k<n>` (`defp`) whose parameters are the live variables and the value; each clause ends in a tail call of it | **done**; `Actors.main/0`, and every shape in `test/fixtures/split_shapes.ex` |
| which variables are live | by Elixir's scoping: what is bound at the top of the function body before the cut (a binding inside a clause ends with it); `x = receive …` rebinds `x`, so the value is the parameter `x`; a pin is a use. The codex's rebinding lowering then names each binding as before | **done** |
| a call of a function that receives, with code after it (`{text, balance, mean} = report(account)`) | a copy `report__c1` of the callee whose every end is a tail call of the continuation | **done** |
| such a call, or a receive, as an argument, a `case` subject, an `if` condition, a pipe stage (`IO.inspect(withdraw_from(account, 100))`) | bound to a variable first (`e2s_h1`), then cut; only when everything Elixir evaluates before it is a variable or a literal, otherwise the sender's gap `… inside an expression` | **done** (the Erlang sender sends the gap for every such place) |
| the state a waiting process keeps | in a made function, a receive that does not use every bound variable is a function of its own | **done** |
| the made functions' types | from the calls of them, to a fixed point (`made_sigs/2`); a parameter two calls give two types is their union; result: the `@spec` result of the source function; hint strength `inferred` | **done** |
| `Process.flag(:trap_exit, true)`, `spawn_link(fn -> … end)` or `spawn_link(M, :f, [args])`, `receive do {:EXIT, ^child, :normal} -> …` | the Erlang sender's lowering: an unlinked spawn of the linked copy `account__l`, which sends `{:EXIT, self(), :normal}` (or the atom of an `exit/1`); `_` and `_reason` in the pattern become variables with a type test; the pin stays the codex's guard test | **done, as an approximation** the README lists |
| `IO.puts/1`, `IO.inspect/1` | `(:sl_call)` of `print`, `println`, `print_int64`, `print_float64`, `print_boolean`, `atom_name` (T9.16), chosen by the argument's stated type: scalars, strings, atoms, tuples, unions of tagged tuples and atoms (a `(:case)` over the alternatives). A struct, a pid, a list, an untyped value: the sender's gap with the reason | **done**. Closes X12 for these two |
| a literal in a struct pattern (`%Box{n: 0}`) | the field as a variable, `===` in the guard | **done** |
| `Process.link/1` on an existing process (`stop_counter/1`) | `(:link)`, which the sink does not write (T9.15) | open: nothing honest to send |
| selective receive | not kept (the sink drops; `T4004`), as for Erlang | open: P13 |

`examples/actors.ex` was changed for it: each answer of the account has a tag of its own, and the clients hold
their receives (`await_reply/0`, whose `term()` no sender can type, is gone). Result (default build of the
trials, `silica-sink/STATUS.md`): `actors.ex` is **`ok`, no gap**, and its `main/0`, run as the program, prints
Elixir's five lines (a float's last digit differs); `demo.ex` has 6 sender gaps (was 8) and `counts.gaps` 8 (was 10).
Suite: 88 tests offline, 0 failed; with `TO_SILICA_PORT` 90.

**Gleam** (`gleam-to-silica-poc/README.md`, "Processes: what this sender splits", "gleam_otp actors"; the
rewriting is `src/gleam_to_silica_poc/split.gleam`, on glance's syntax tree):

| Gleam | Sent as | State |
| --- | --- | --- |
| `process.receive(subject, within)`, `process.receive_forever(subject)` with code after them, in `case` branches and blocks; several | the split of T9.13a: Gleam's receive is a call with a value, so every use is "a receive with code after it"; continuations `f__k<n>`, a timeout and `after` giving `Error(Nil)` | **done** |
| `ask/1`, `summary/1` called with code after (`case ask(counter) { … }`) | copies `ask__c1`, `summary__c1`; a receive that is an operand is bound first | **done** |
| the message type of a subject (was `dynamic`: blocked) | a custom type with variants is sent as it is, one receive clause for each variant; any other type (`Report`, `#(Int, Int)`) as `(:subject__<type>, value)` with a `(:t_tagged)` hint | **done without `dynamic`**. P4 (references) is no longer needed for the examples; a subject still does not select its messages (documented) |
| `actor.new(s) \|> actor.on_message(h) \|> actor.start`, `actor.continue`, `actor.stop` | an unlinked spawn of a loop function the codex writes (a tail receive that calls `h` by name); `Next` as the sender's own values | **done**; not linked (T9.15), documented |
| `io.println(a <> int.to_string(n) <> … <> float.to_string(f))`, `io.print` | `(:sl_call)` of `print`, `print_int64`, `print_float64`, `println`, operands that are calls bound first | **done**; P14 still wanted for a number's text outside a print |
| list values and patterns, `pub const` with a literal value, type aliases without parameters, `list.length`'s type | `(:nil)`, `(:list)` with `t_list`; a function of no parameters; the aliased type | **done** (`list.length` itself is a call into another module: T9.9) |
| `process.new_name`, `actor.named`, `process.named_subject`, the static supervisor | **gaps, kept**: a name made at run time is no literal of H38/H39 (which the sink does not write either), and lowering "a named subject is the process" would not be what a supervisor that restarts under the name means | open: P8 |

Result: `actors.gleam` `counts.gaps` 4 (was 10), its `main` still ends in the stub of `start_audit()`; the same
application without the name and the supervisor (scratch `plain.gleam`) prints, as a Silica program, the three
lines Gleam prints; `demo.gleam` `counts.gaps` 8 (was 14). Suite: 58 tests, 0 failed, offline and against the
sink in check mode.

**Proposals touched by this step** (none written into the contract): P13 (unmatched messages) still open for
all three senders; P14 (text from a number) still wanted by Gleam outside `io.println` and by Elixir for
interpolation; P15 (a function only processes run) would remove the `T4002` note a source function gets when
its receive moved into a made function and it is exported (`split_shapes.ex`, `plain.gleam`: one `counts.gaps`
each); P1 (trapping exits) and P8 (supervisors, names) as before. **New, for the sink's owner** (limitations
observed, `silica-sink/STATUS.md`): a dropped statement or a process's end value of a union type is written
`_: A | B <- e`, which the compiler does not accept; a call of a function sent as a gap form is written as a
call of an unknown function.

## Update: the sender owns its language's semantics; the Erlang sender splits processes (2026-11-13, late)

**Direction (binding):** a language's implementation details are handled by the language-built sender, not by
`silica-sink`. What runs before and after a `receive`, the state a waiting process keeps, several receives in one
function, a receive that is not in tail position: the sender splits the function and sends the already-split
result. The sink prints what it is told and, when it cannot, names the construct and its place and says what the
sender must send. This is the rule of contract §8.6 (the sender decides every type) applied to control flow. It
is now in the contract: §1 "What you own", **T9.13a** (you split a function at a receive), **T9.16** (L1 as
built: a language's output is sent as `(:sl_call)` of Silica's print builtins), and T9.15 (a sender may lower
trapped exits itself). `HOWTO_language_creators.md` §6a is the guide.

**Only the Erlang sender was changed.** What it does now (`erlang-to-silica-poc/README.md`, "Processes: what
this sender splits"; the rewriting is `src/e2s_split.erl`, on Erlang's abstract forms, before the codex types
anything):

| Erlang | Sent as | State |
| --- | --- | --- |
| code before a receive (it runs when the process starts; `self()`, a send) | unchanged, before the `(:receive)`: the sink's process runs it at its start message | nothing to do; run in `actors.erl` (`ask/1` sends its request, then waits) |
| a receive with code after it (`P = receive … end, Rest`), also inside `case`, `if` and `receive` clauses | the receive in tail position; `Rest` as a continuation function `f__k<n>` whose parameters are the live variables and the receive's value; each clause ends in a tail call of it | **done**; `main/0` of `actors.erl` |
| several receives in one function | one continuation each | **done** |
| a call of a function that receives, with code after it (`{T, A, M} = ask(Counter), …`) | a copy of the callee (`ask__c1`) whose every end is a tail call of the continuation, with the continuation's variables as extra parameters | **done** |
| the state a waiting process keeps | in the functions the sender makes, a receive that does not use every bound variable is a function of its own with the variables it uses | **done** (needed: with every bound variable kept, `actors.erl` ended with a memory fault after its last line, limitation observed, STATUS.md) |
| `process_flag(trap_exit, true)`, then `spawn_link`, then `receive {'EXIT', Pid, Reason}` | no gap any more: an unlinked spawn of a copy of the child's function (`counter__l`) that sends its parent `{'EXIT', self(), normal}` (or the atom of an `exit/1`) when it ends; the receive's pattern typed as that message, a bound pid compared in the guard | **done, as an approximation** the README lists: only ends the source writes are reported; the link's other direction is not kept |
| `io:format/1,2` with a literal format | `(:sl_call)` of `print`, `print_int64`, `print_float64`, `print_boolean`, `atom_name` (contract T9.16), then `ok` | **done** for `~p ~w ~b ~s ~n ~~` on integers, floats, atoms, booleans, binaries; anything else is the sender's gap with the reason. Closes E8 for `io:format` |
| a literal in a record pattern (`average(#tally{adds = 0})`) | the field as a variable, `=:=` in the guard | **done** (was the sink's gap that decided `actors.erl`) |
| pure code before a receive, hoisted into the spawner | **not done, not needed**: the code before a receive already runs in the new process at its start; a `spawn(fun() -> f(Args) end)` has its arguments evaluated by the spawner (contract T9.14), which is the hoisting the contract can express | no contract change proposed |
| selective receive (a message no clause takes stays in the mailbox) | **not kept**: the sink drops it, and every split function gets the warning `T4004`. Re-sending an unmatched message to `self()` was considered: nothing in the contract lets a sender say it (the sink's waiting phase answers `nomatch` itself), and it would spin on a message no later receive takes | open; a proposal is P13 below |
| a receive, or a call of a function that receives, inside an expression (`{ok, receive … end}`) | the sender's gap `receive inside an expression`, whose note says to bind the value with `=` first | deliberate limit of the splitter |

The made functions have no `-spec`: their parameter types are the types of the arguments of the calls of them
(`gen_sigs/2`), their result the `-spec` result of the function they are cut from. Names: N7 (`main__k1`,
`ask__c1`, `ask__c1__k1`, `counter__l`).

Result for the two Erlang examples (default build of the trials, `silica-sink/STATUS.md`, "The split, run"):
`actors.erl` is now **`ok`, no gap**, and its `main/0`, run as the program, prints the three lines Erlang prints
and ends with status 0; `demo.erl` has 5 gaps (was 7: `supervise/1` is written).

Run: `test/run_test.sh 7492` from a scratch copy against the default build of the trials: 125 tests, 0 failed
(121 offline). In this step `silica-sink/` and `contract/` were changed too (the printing of `(:sl_call)`, two
diagnostics, T9.13a, T9.16: STATUS.md); nothing in `../silica` or `../project-bees`; nothing was committed.

### What the Elixir and Gleam senders would need (as written 2026-11-13; **done 2026-11-14**, see the update above)

Neither was touched in that step. Each row is work in that sender only; the sink and the contract need nothing more for it.

| Sender | Construct in its examples | What it would have to send | Where it would go |
| --- | --- | --- | --- |
| Elixir | `Actors.main/0`: `account = receive do … end` followed by code; a second receive at the end | the split of contract T9.13a: the code after each receive as a continuation (`main__k1`, …) with the live variables and the value as parameters. Elixir rebinds variables, so the live set must be taken after the sender's renaming | a pass over the quoted AST before `E2S.Codex` types it, as `e2s_split.erl` is for Erlang; the continuations' types from the calls of them (the Elixir codex has the same typing pass) |
| Elixir | `IO.inspect(withdraw_from(account, 100))`, `{text, balance, mean} = report(account)`: calls of functions that receive, with code after them | a copy of `withdraw_from/2` and of `report/1` for each such call, ending in the continuation. Both go on in `await_reply/0`, whose result is `term()`: the sender's own gap (no type), which must be given a type first (one reply tag for each answer: T9.12) | the same pass; and the example (`{:reply, …}` has three types today) |
| Elixir | `IO.puts/1`, `IO.inspect/1` | `(:sl_call)` of the print builtins (T9.16). `IO.inspect` prints Elixir's own text of a term (`{:ok, 40}`, `{:balance, 40, :mean_move, 13.3…}`): the sender writes the punctuation as `print` calls and each scalar with its builtin, for the types it can state; a term whose type it cannot state is a gap | `E2S.Codex`, where calls into `IO` are mapped |
| Elixir | `Process.flag(:trap_exit, true)` with `spawn_link` (`supervise/1`, `supervisor/1`) | the Erlang sender's lowering fits as it is (the same runtime semantics): the linked copy that sends `{:EXIT, self(), :normal}` | the same pass |
| Elixir | `Process.link/1` (`stop_counter/1`) | nothing honest with today's nodes (a link made after the spawn, between two existing processes): stays `(:link)`, which the sink does not write (T9.15) | open: contract |
| Gleam | `main/0` of `actors.gleam`, `ask/1`, `summary/1`: `process.receive` on a subject, results used by code after the call | Gleam's receive is a function call with a value, so every use is "a receive with code after it": the split of T9.13a applies to every `process.receive` and `process.call`. First the sender needs a typed message for a subject: today the hint is `dynamic` (P4 below: references), which the sink does not write whatever the split | `codex.gleam`; blocked by `dynamic` (sink / contract), not by the split |
| Gleam | `io.println(a <> int.to_string(n) <> …)`, `float.to_string` | `(:sl_call)` of `println`/`print` for text; `int.to_string` and `float.to_string` have no builtin on the T9.16 list (they give text, they do not print): either the sender lowers `io.println(s1 <> int.to_string(n) <> s2)` to a sequence of prints when the whole argument is such a concatenation, or the contract gains the conversions (proposal P14) | `codex.gleam` |
| Gleam | `gleam_otp` actors (`actor.start`, a supervisor) | an OTP behaviour is the sender's to lower into processes and receives (contract §9.2), then to split | not started |

## Update: the examples run as Silica programs (2026-11-13, night)

Every example of the three senders was converted, compiled, linked with a hand-written driver and run, and
compared call by call with the same calls in its own language: `silica-sink/STATUS.md`, "The examples, run".
What that changed in the senders:

| Change | Where | State |
| --- | --- | --- |
| **Contract H22: the value of a `(:send)` is the message.** `process.send` gives `Nil`, and the sender sent the `(:send)` hinted `Nil` where `Nil` was the function's value: `T3103` for `actors.add/3` | Gleam: `send/7` and the new `send_statement/1` in `src/gleam_to_silica_poc/codex.gleam`. The `(:send)` is hinted with the message's type. Where the call's value is used (a function's result, a `case` branch, the last statement of a block) it is the block `{ send, nil }`; as a statement that is not the last of its block it is the send alone. An external `erlang:send` declared with the message as its result is the node alone; declared `Nil`, the block; declared with any other type, a gap. README, the mapping table and "Processes" | **done.** 1 new test (`send_is_a_statement_before_nil_test`: two sends, a whole body, a `case` branch, a dropped statement, Erlang's own send), 1 changed (`library_processes_test`). `actors.gleam`: `add/3` is written, `counts.gaps` 11 to 10, no `T31xx`. Run as Silica in the scratch unit `sendnil.gleam` (the same `add/3`, public): 10 calls of 10 give Gleam's values, the messages included |
| the same pattern in the other two senders | Erlang (`expr/3`, the `'!'` clause) and Elixir (`builtin(:send, …)`) hint the `(:send)` with the message's type, which is its value in both languages. A function whose `-spec`/`@spec` result is another type than the message it ends with is a wrong spec, not a mapping | **nothing to change.** Erlang: 1 new test ("H22: … the send that is a function's value is hinted with the message's type"). Elixir: its test "T8.10 (d), (e) …" already asserts the hint |
| **Contract T8.16** in the Elixir sender (open since the process nodes): a type test in a guard that only states the type its variable already has was sent as `true` (`true andalso n > 0`, `true andalso true`), which the sink wrote as a second `case` inside the receive arm | Elixir: `guard/2`, `whole_guard/2`, `states_type?/2` in `lib/e2s/codex.ex`. `when is_integer(n) and n > 0` is the guard `n > 0`; `when is_integer(n) and is_pid(from)` is no guard. A test the stated type does not answer is still sent as the call; an alternative of `when a when b` is sent whole. README, "Types and conversions" | **done.** 2 new tests ("T8.16: …"). Both examples run as Silica with the same values before and after |
| a symbol message whose hint states the whole message type (Gleam's constructor of no fields: `Reset` of `Add(Int) \| Reset`) | no sender: the sink refused it (`T4002`) and now writes it (contract T9.12, amended) | **done in the sink**; found with `sendnil.gleam` (`maybe/2`) |

Found by the runs, **not** changed in any sender:

- **Elixir `actors.ex` states three types for the message tag `reply`** (`{:reply, {:ok, n}}`,
  `{:reply, {:refused, n}}`, `{:reply, {text, balance, mean}}`). Contract T9.12 wants one type for a tag in a
  unit. The sender sends them, the sink writes three alternatives, the unit compiles, and an actor that matches
  such a message ends the program with a memory fault (limitation observed). The example would need one tag for
  each reply, or the sender a check; whether the sink reports it is open (APP_GAPS.md).
- **Gleam `demo.gleam` binds `receive_message` to `demo_ffi`, a module the repository does not have**, so
  `ping_pong/1` and `pong_loop/0` cannot run as Gleam from the repository. The native run used a scratch
  `demo_ffi.erl` (`receive M -> M end`).
- Functions that are private in the source (`add/3`, `ask/1`, `summary/1` of `actors.gleam`; `ask/1` of
  `actors.erl`; `negate/1` of `demo.gleam`) are not exported by the unit, so no driver can call them: they are
  reached only through `main`, which is a failing stub in all three `actors` units.

Suites after these changes, against the transpiler's default build of the trials: Erlang
`test/run_test.sh 7472` 104 tests, 0 failed (100 offline); Elixir `TO_SILICA_PORT=7472 mix test` 80 passed (78
offline, 2 skipped); Gleam `test/run_test.sh 7472` 52 passed. Each from a scratch copy of its directory.

## Update: process nodes in the sink (2026-11-13, evening)

The sink now writes processes (contract §9.4a; `silica-sink/silica_sink_design.md` §5.5). What that changed for
the senders:

| Change | Where | State |
| --- | --- | --- |
| **Contract T8.16 (new):** a type test that only states the type of a variable is not sent as a guard; a receive clause's pattern hint is the type of the messages the clause takes | Erlang: `unstated/2`, `stated/2` in `src/e2s_codex.erl` (a guard `is_integer(N)`, `is_pid(P)`, … on a variable whose stated type is that type is left out; every other test is sent as written). README, "Types and conversions" | **done in the Erlang sender.** 2 new tests ("T8.16 …"), one changed (`H23 receive with after`: the node indices moved). `test/run_test.sh`: 99 tests, 0 failed offline; `test/run_test.sh 7462` against the sink's default build: 103 tests, 0 failed |
| the same rule | Elixir, Gleam | **Elixir: done the same night** (the section above). At the time: **not changed** (not needed for `demo.erl`). The Elixir examples' process functions were written by the sink with the sender as it is (its receive clauses came out with no type-test guard); Gleam has no type tests. Not re-checked against T8.16 line by line. Their own suites against the same build: Elixir 78 passed, Gleam 51 passed |
| **Contract T9.11 (new):** function names that are Silica reserved words or `main` are written with `__` appended by the transpiler | none: the senders send the names as they are | closes "Not handled by any sender (names)" below for functions; a **field** named like a reserved word is still not written |
| **Contract §9.4a (new, T9.12 to T9.15):** what a sender must send for a process node to be written | no sender was changed for it | what the three examples still get as gaps because of it is in [APP_GAPS.md](APP_GAPS.md), "Status after the process nodes": a receive that is not in tail position (`actors:main/0`, `Actors.main/0`); Gleam's message hints, which state the whole message sum instead of one `(:t_tagged)`; `Process.link` |

Found for the Gleam sender (**changed the same night**, the section above): contract H22 now says that the value of a `(:send)` is the message.
`process.send` gives `Nil`, and the sender sends the `(:send)` where `Nil` is the function's value, so the sink
reports `T3103` for `actors.add/3`. The sender should send `(:block, [send, nil])` there.

A sender that wants more of its processes written can, with no contract change: put the code after a receive
into a function of its own and call it in tail position (T9.13); hint each message with the `(:t_tagged)` of its
tag (T9.12). Proposal P5 below (alias patterns) is now what the sink does.

## Update: the senders after the types decision (2026-11-13, later the same day)

**Decision (binding): the language side decides all data types and all numeric conversions** (contract §8.6,
T8.8 to T8.15; `silica-sink/DECISION_DATA_printer.md` §6). Each sender was changed to follow it and re-synchronised
with the contract as the transpiler now implements it. The rest of this file is the earlier record.

What every sender now does:

| | Erlang | Elixir | Gleam |
| --- | --- | --- | --- |
| Typing pass (in the codex) | `-spec`, `-record`, `-type`; what a variable is bound to; operator rules; a table of BIFs; type-test guards type messages and fun parameters | `@spec`, `@type`, structs; `assign` takes patterns apart; Kernel rules; a small standard-library table; guards type receive variables | annotations; `let` annotations; operator spelling (`+` Int, `+.` Float); same-module signatures with type variables bound; constructors; a small standard-library table |
| Hints sent (contract T8.10) | signature; every binding; calls, tuples, lists, records, fields, `case`, blocks, matches, lambdas, sends, receive clause patterns | signature; every binding; calls, applies, records, tuples, lambdas; match values, case subjects, dropped statements, messages | signature; every pattern variable; lambdas, calls, matches, blocks, cases, records, tuples, fields, constructor symbols |
| Conversions (T8.12) | `to_float` on the integer side of mixed `+ - *` and comparisons and on both operands of `/`; `float/1`, `trunc/1`, `round/1` as operators; `=:=` between integer and float as a boolean | the same for `+ - * /`, comparisons, `trunc/1`, `round/1`, `:erlang.float/1`; `===` between integer and float as a boolean | none implicit (Gleam has none); `int.to_float`, `float.truncate`, `float.round` as the operators |
| Its language's edges (T8.15) | `/`: `cond` on a zero divisor with `(:fail)` `badarith`; `div`/`rem`: nothing (Silica's ends the actor too); overflow: **not guarded**, documented | the same | `/`, `%`, `/.`: a `case` on a zero divisor giving `0` / `0.0`; overflow: **not guarded**, documented |
| A type it cannot state | a gap with the reason (form or node) | a gap with the reason (`missing type: …`, `type rule: …`) | a gap with the reason |
| `(:type)` forms | first in the unit, dependencies first (T8.14) | first, dependencies first | first, dependencies first; generic types with `t_var` and arguments |
| Names | the injective `ident` (`?` → `__q`, `!` → `__b`, other → `__x<hex>_`, an underscore beside an underscore or before an escape → `__x5f_`); `name__<arity>` for a name with several arities | the same | the same `ident`; one arity per name in Gleam; its one generated function is `gleam_otp_actor_loop__g<n>` |
| Replies while sending (T6.2, T6.3) | drains replies before every frame, waits at zero credit | reads while sending; gives up after 30 s with no credit | polls before every frame; waits at most 30 s |
| Resume (T6.5) | `--resume Session` | `--resume SESSION` (tried against a stand-in only) | not implemented |
| Session ids | opaque text (`intake_1:42`) in README, help and tests | the same | the same |

What was run (all against the transpiler built from the repository's `silica-sink/` with compiler 999916, port 7454,
after the senders' own agents had run them against an earlier build in check mode):

| Sender | Its tests, online | `demo` in transpile mode | `actors` in transpile mode |
| --- | --- | --- | --- |
| Erlang | `test/run_test.sh 7454`: 101 tests, 0 failed | `partial`, 35 frames, unit compiles | `partial`, 14 frames, unit compiles |
| Elixir | `TO_SILICA_PORT=7454 mix test`: 78 passed | `partial`, 36 frames, unit compiles | `partial`, 17 frames, unit compiles |
| Gleam | `test/run_test.sh 7454`: 51 passed | `partial`, 41 frames, unit compiles | `partial`, 26 frames, unit compiles |

**The transpiler reported no `T31xx` for any of the six**: every type it needed was stated and no operator mixed
types. The gaps that remain, with the side each belongs to, are in [APP_GAPS.md](APP_GAPS.md), "Status after the
types decision". The examples were changed by the senders' work: specs and annotations were added, the Erlang and
Elixir receive clauses got type-test guards, and each demo got functions that show a conversion and a deliberate
missing-type gap.

Not handled by any sender (names): a function or field named like a Silica reserved word or builtin (`move`,
`unit`, …) and `main`; unit names (N1) and type names (N3) are not injective (`Foo.Bar` and `FooBar`).

Points of contract §8.6 the senders found unclear, and what was done: whether a tagged or named hint on a
`(:tuple)` is consistent (yes: now a note under T8.9); the stated type of `(:bytes)` and of a `(:gap_node)`
(notes under T8.9); which node carries a receive message's type (the clause's pattern; note under T8.9). Still
open: process references with no message type (`pid()` is sent as `(:t_actor, dynamic)` and printed as
`actor_ref`; a Gleam `Subject`'s message as `dynamic`, which is not printed); a failing test in a guard (Erlang
treats it as false; there is no node for that, so `/` in a guard is the sender's gap); atoms of two different
unions compared (the senders send a constant or a gap).

Status words: **fixed** (done in the sender with nodes the contract already has); **partly** (what the contract
allows is done, the rest is named); **needs-contract-change** (the sender cannot do it without a node or rule the
contract does not have; the sender still sends a gap or the closest thing, as before); **unfixable** (not a matter
for the sender or the contract).

## What was run, and against what

- **The transpiler**: the scratch build of the 04:23 copy of `silica-sink/` (APP_GAPS.md's "new" build, compiler
  999919, Apple Silicon), as three copies of the binary whose port text was changed to 7441, 7442 and 7443, one
  per sender, so the three could be tested at once. The repository's `silica-sink/` as it stands now was **not**
  built or run.
- **The transpiler's release fault (APP_GAPS C1) was met again**, many times: a release connection ends the
  transpiler with `fault … in silica_rt_message_copy`. With the Erlang sender it happened on the 1st, 2nd and 3rd
  release of a fresh transpiler in different runs, and not at all in others; the Elixir and Gleam work met it too
  (in two of the Elixir runs with no `fault` line on standard error). Each sender now reports it as "the
  transpiler closed the connection without a (:released, …) answer". The transpiler was restarted after each fault.
- Per sender: its tests offline and online, a check-mode and a transpile-mode session of each example, a release,
  and the example application in its own language. The lines are in the sections below.
- **Not run**: anything on Linux; the exported Silica was not compiled again (the printer did not change);
  nothing was linked or executed as a Silica program.

## Decisions that hold for all three senders

1. **Names** (each README, "Names"; rules N1 to N5). `silica_unit` is the prefix and the module in snake_case
   with `.` and `/` as `_`; `unit_name` and the module of a call stay as the user writes them (T5.2); a type is
   named `<module>_<type>` in snake_case (for an Elixir struct, its module), because `t_named` names a type of the
   whole session; function, variable and field names pass through one `ident` function (`?` → `_q`, `!` → `_b`,
   other characters → `_x<hex>_`); symbols are the atom's run-time text on the BEAM, unchanged (so a Gleam
   constructor `Ok` is the symbol `ok`, as Gleam's Erlang backend writes it).
2. **Alias patterns** (`P1 = P2` in Erlang and Elixir, `pattern as name` in Gleam) are sent as a `(:match, …)`
   node in pattern position whose two children are patterns. The schema allows it and §9.4 says "which one a
   node is follows from where it is referenced", but the contract does not say it in so many words: see proposal
   P5.
3. **`try`/`catch`/`rescue` stays a gap** in every sender, by direction; no example uses it. See proposal P3.
4. **Release**: every sender has `--release SESSION` and a library function; exit status 0 when `freed` is true.
5. **The example applications** (`examples/actors.*`) were rewritten as plain, idiomatic programs: a coordinator,
   a supervisor shape, a stateful actor with a record or struct; no forced crash, no timeouts other than the usual
   one of a request. Where the idiomatic form has no mapping it was kept and is a gap. Their output is no longer
   the one APP_GAPS.md lists.
6. **Each README has "Extending this sender"** with the same subsections, and each test suite has one small test
   per mapping (source snippet in, expected nodes out) to copy from.

## Erlang: `erlang-to-silica-poc/`

| Id | Status | What changed | Evidence |
| --- | --- | --- | --- |
| E6 `process_flag(trap_exit, true)` | **lowered by the sender (late 2026-11-13)** where it is a statement followed by `spawn_link` and a receive of `'EXIT'` in the same body (the linked copy, above); anywhere else still `(:gap_node, _, "erlang:process_flag/2", …)`. The contract still has no node for trapping exits (proposal P1) | tests "split: trap_exit and spawn_link …", "mapping: T9.10 process_flag/2 is a gap" (its value used); `actors.erl` has no gap |
| E8 calls to modules outside the session | **`io:format` with a literal format: lowered by the sender** to `(:sl_call)` of print builtins (contract T9.16). Every other module call: nothing changed, `(:call, _, "lists", "reverse", …)`, module as written (N2); check mode accepts it; the contract gives it no meaning (proposal P2) | tests "split: io:format …" (3); `--dump` |
| E11 release | fixed in the sender | `e2s_sender:release/3`; `--release Session` in `e2s.erl`; a close without an answer is `{error, closed_without_reply}` and a clear message | 3 offline tests against a stand-in listener; online: `released: session nosuch, freed false` (exit 1), `released: session s3, freed true` (exit 0) after a transpile session; the fault C1 on other releases |
| `try`/`catch` | needs-contract-change (left a gap, by direction) | Nothing. H27 has `clauses` and `catches` but no stated shape for a catch clause (proposal P3) | test "mapping: T9.10 try is a gap"; no example uses `try` |
| alias pattern `P1 = P2` (X13's twin; a gap before) | fixed, on a reading of the contract (proposal P5) | `pattern/2`: `(:match, at, P1, P2)`, both children patterns | test "mapping: H18 an alias pattern …"; `bump/2` of `actors.erl`; check mode `ok` |
| lists and strings (gaps before; needed for `io:format/2`) | fixed | `[]` is H7, a literal list H10, `[H \| T]` H9, in expressions and patterns; a string is the list of its character codes; `++`; `[T]` and `string()` as `t_list` | 6 mapping tests; `sum_list/1`, `greeting/0` of `demo.erl` |
| names | fixed | `ident/1`, `snake/1`, `unit_ident/1`, `type_name/2`; a record's type is `<module>_<record>` (`actors_tally`) in the type form, `t_named` and `(:record)` | 4 "names:" tests |

Files: `src/e2s_codex.erl` (names section, `type/3` now takes the environment, lists, alias pattern, a header
that lists the sections and where to extend), `src/e2s_sender.erl` (`release/3`), `src/e2s.erl` (`--release`),
`examples/actors.erl` (rewritten), `examples/demo.erl` (lists, an alias pattern, a map as the third gap),
`test/e2s_test.erl` (rewritten around one test per mapping), `README.md`.

Run (port 7441):

- `test/run_test.sh`: `39 tests, 0 failed, 0 not decided because the transpiler ended`.
- `test/run_test.sh 7441`: 42 tests, 0 failed; the online release test was decided (`ok`) in one run and
  `TRANSPILER FAULT` (C1) in three others. The test reports that apart from pass and fail.
- Check mode: `demo.erl` `result: ok (units 1, gaps 3, rejected 0, files 0)`, 25 frames; `actors.erl`
  `result: ok (units 1, gaps 1, rejected 0, files 0)`, 14 frames.
- Transpile mode: `actors.erl` `result: partial (units 1, gaps 9, rejected 0, files 1)` (only `describe/1` is
  printed; the nine T4001 are the transpiler's C2 to C7); `demo.erl` `result: partial (units 1, gaps 18, rejected 0,
  files 1)`. A second transpile session before the release: `refused: busy`.
- The application: `total 7 after 2 adds, mean 3.5: small` / `total 36 after 3 adds, mean 12.0: large` /
  `the counter stopped; restarts: 0`.


## Elixir: `elixir-to-silica-poc/`

| Id | Status | What changed | Evidence |
| --- | --- | --- | --- |
| X8 `Process.flag(:trap_exit, true)` | needs-contract-change | Nothing: `(:gap_node, _, "Process.flag/2", …)`; the only gap of `actors.ex` (proposal P1) | test "the only gap is Process.flag/2" |
| X9 the pin, `^x` | fixed in clauses and in `=` statements; partly elsewhere | In a clause of `def`, `case`, `receive`, `fn`: `^x` becomes a variable `_pin_N` and `_pin_N =:= x` is put in front of the clause's guard with `andalso` (exact: clauses have guards, H29). In a `=` that is a statement: the match, then `true = (_pin_N =:= x)`. A pinned `=` used for its value, and a pin of something that is not a variable, stay gaps (proposal P6) | 4 tests; the supervisor of `actors.ex` now has `{:EXIT, ^child, :normal}` |
| X12 `IO.puts/1`, `IO.inspect/1` | needs-contract-change | Nothing: `(:call, _, "IO", "puts", [_])` (proposal P2) | check mode `ok` |
| X13 alias pattern | fixed, on a reading of the contract (proposal P5) | `left = right` in a pattern is `(:match, at, left, right)`, both patterns | tests "alias pattern: …"; `def f({a, b} = t), do: t` gives `…{:tuple,2,[0,1]},{:var,3,"t"},{:match,4,2,3}…`; `deposit/2` of `actors.ex` |
| X15 release | fixed in the sender | `E2s.Sender.release/3`; `mix e2s --release SESSION` (and the escript) | 3 offline tests; online `freed false` for an unknown session, `released: session s1, freed true` after a transpile session; C1 met twice |
| rebinding (`x = x + 1`) | fixed | Each binding in a function clause gets its own sent name: `x`, then `x_1`, `x_2` (skipping names the source uses); a reference uses the binding it sees. Bindings made in a `case`/`cond`/`receive`/`fn` clause end with the clause, as in Elixir (`lib/e2s/codex/scope.ex`). The contract does not say what a second binding of a name means (proposal P7) | 4 tests: `x = 1; x = x + 1; x` sends the variables `x, x_1, x, x_1` |
| truthiness in `if`, `cond`, `&&`, `\|\|`, `!` | fixed | A condition that is boolean by its syntax stays `(:cond)`, `andalso`, `orelse`, `not`. Any other becomes Elixir's own expansion, a `case` with `t when t === false or t === nil` (`lib/e2s/codex/truthiness.ex`); a `cond` is split at its first such condition | 5 tests |
| names | fixed | `lib/e2s/names.ex` is the one place a name is spelled; a struct's type is its module (`actors_account`); `empty?` is `empty_q`; a module alias used as a value is the symbol `Elixir.<name>` | tests "N1", "N4", "N2, N3, N4, N5 in frames" |
| `try`/`rescue`/`catch` | needs-contract-change (left gaps, by direction) | Nothing (proposal P3) | the gap test lists them; no example uses them |

Run (port 7442; reported by the agent that did the Elixir work, the offline run repeated by me):

- `mix test`: `46 passed, 2 skipped` (the online tests). `TO_SILICA_PORT=7442 mix test`: `48 passed`.
- Check mode: `demo.ex` `result: :ok (units 1, gaps 4, rejected 0, files 0)`, 34 frames; `actors.ex`
  `result: :ok (units 1, gaps 1, rejected 0, files 0)`, 18 frames.
- Transpile mode: `actors.ex` `result: :partial (units 1, gaps 12, rejected 0, files 1)`; `demo.ex`
  `result: :partial (units 1, gaps 25, rejected 0, files 1)`.
- The application (`elixir -r examples/actors.ex -e "Actors.main()"`): `{:refused, 30}` / `{:ok, 40}` /
  `ada: low` / `{:balance, 40, :mean_move, 13.333333333333334}` / `account closed`.

Known limits (in the README): truthiness is decided by syntax, so `if valid?(x)` takes the longer `case` form;
the generated variable `_truthy` could be confused with a source variable of that name; a computed call
`mod.fetch!(x)` (H34) carries the name as a symbol `fetch!` while the function's form is named `fetch_b`; a
variable written twice in one pattern (`{x, x}`) is sent as the same name twice. Lists, maps, bit syntax, `with`,
comprehensions and OTP behaviours are gaps as before (the Erlang sender now maps lists; the Elixir one does not yet).


## Gleam: `gleam-to-silica-poc/`

| Id | Status | What changed | Evidence |
| --- | --- | --- | --- |
| G1 `gleam_otp` actor | partly | The plain actor, `actor.new(state) \|> actor.on_message(handler) \|> actor.start`, is lowered with existing nodes: a linked `(:spawn)` of a `(:fun_ref)` to one helper function form per unit, `gleam_otp_actor_loop/2`, with the state and the handler as arguments; the helper is a `(:receive)` whose clause calls the handler and goes on, stops, or fails (H26), under a `(:loop_hint)`. `actor.continue`, `stop`, `stop_abnormal` are sent as the tuples `gleam_otp` itself uses at run time; the value of `start` is `#(ok, #(started, Pid, Pid))`. **Still gaps**: `new_with_initialiser`, `initialised`, `returning` (the start must wait for the actor's acknowledgement and handle a timeout, which needs unlink and monitor: proposal P9), `named`, selectors, `actor.call`. Each unmapped call is now its own gap node written after its translated arguments, so closures are sent. **Lost, and documented**: the actor takes any message of its process; no system messages; `start` does not wait | tests `actor_start_test`, `actor_loop_form_test`, `actor_next_values_test`, `started_pattern_test`, `otp_gaps_keep_their_arguments_test` |
| G2 `gleam_otp` static supervisor | needs-contract-change | Still gap nodes (four for the pipeline; the worker's closure is now sent before its gap). A proxy process with an A4.4 override was considered and rejected: an override can only sit on a spawn of the form being written, a restart must run the child's start function again, how a link and a restart act together is not specified, and it would turn `one_for_one` into `one_for_all` (proposal P8) | README, "gleam_otp actors" |
| G3 `process.receive` takes any message | needs-contract-change | The mapping is as before (a subject is the process that owns it). One improvement: a subject expression that is not a plain variable is now evaluated first. No unique value can be made with existing nodes, so a tagged subject cannot be expressed (proposal P4) | `receive_evaluates_its_subject_test` |
| G4 `Subject`, `actor.Next`, `Result` as `dynamic` | fixed, under the documented lowering | `Subject(m)` is `(:t_actor, m)`; `process.Pid` `(:t_actor, dynamic)`; `Result(a, e)` a union of `(:t_tagged, "ok", [a])` and `(:t_tagged, "error", [e])`; `actor.Next`, `Started`, `StartResult` written out. `List` and other modules' types stay `dynamic` | `library_types_test`; `start_counter/0`: `{t_actor,2}` over `{t_named,<<"actors_counter_message">>,[]}` |
| G13 `io.println`, `int.to_string` | needs-contract-change | Nothing: `(:call, _, "gleam/io", "println", [_])` (proposal P2) | check mode `ok` |
| G14 the application needs `gleam_erlang`, `gleam_otp` | unfixable in the sender (not a defect) | Nothing: they stay development dependencies, `test/actors.gleam` is the compiled copy | `gleam run -m actors` |
| G15 release | fixed in the sender | `sender.release(port, session)`; `--release SESSION` | offline `release_test` (freed true, freed false, closed without answer); online `released: session nope, freed false` 3 of 3; `released: session s1, freed true` after a transpile session, for both examples; C1 met in four other runs, so the online release test runs only when `TO_SILICA_RELEASE_PORT` is set |
| names | fixed | `src/gleam_to_silica_poc/names.gleam`; types `actors_tally`, `actors_counter_message`; constructors are their run-time atoms (`ok`, `error`, `nil`, `add`) | `names_test`, `names_in_frames_test`, `actors_forms_test` |
| alias pattern `pattern as name`; `let assert` (gaps before) | fixed, the first on a reading of the contract (proposal P5) | `(:match, at, name, pattern)` in pattern position; `let assert P = V` is `(:match)`, which is H18's meaning; `let assert … as message` stays a gap | `alias_pattern_test`, `let_assert_test` |

The application's gap nodes went from 6 to 10. The application is a different one (a counter that is a plain
actor and is sent whole, and an auditor that is a *named* actor under a `OneForOne` static supervisor, kept in its
idiomatic form), and each unmapped call of a pipeline is now its own gap: four for the named actor
(`actor.new/1`, `named/2`, `on_message/2`, `start/1`), four for the supervisor, and `process.new_name/1`,
`process.named_subject/1`. The six old gaps are gone.

Run (port 7443; reported by the agent that did the Gleam work, the offline run repeated by me):

- `test/run_test.sh`: `35 passed, no failures`; `test/run_test.sh 7443`: `35 passed, no failures`.
- Check mode: `demo.gleam` `result: ok (units 1, gaps 7, rejected 0, files 0)`, 38 frames; `actors.gleam`
  `result: ok (units 1, gaps 10, rejected 0, files 0)`, 25 frames.
- Transpile mode: `actors.gleam` `result: failed (units 1, gaps 21, rejected 0, files 1)` (all 21 are the
  transpiler's C2 to C7; C17 as before); `demo.gleam` `result: partial (units 1, gaps 29, rejected 0, files 1)`.
- Two transpile sessions with a release between them never got through one transpiler process (C1).
- The application (`gleam run -m actors`): `counter: total 9, adds 3, small` / `mean 3.0` /
  `auditor: notes 3, sum 9`.

Known limits (in the README): the unit name is the file's base name (glance does not know the package root);
`started.data` is a field access on a tuple; the `proven` strength is honest only for source the Gleam compiler
has checked, and the helper function's hint is `inferred`.


## Found on the way, not changed

- **Every hello declares A4.4 `restart` `transient`.** By the contract's wording every `(:spawn)` is then
  restarted when it fails, but Erlang's `spawn`, `spawn_link` and Gleam's `process.spawn` never restart. `temporary`
  is a valid BEES value and would be the honest session default; the three senders were left alike, with the
  worked example's choices. This wants a decision by the contract's owner (see P8).
- **A release connection takes a session id** (`s4` after `s3`), so the id of the next session is not the next
  number. Harmless; the senders print the id the welcome gives.
- **The three senders do not cover the same subset**: Erlang now maps lists, Elixir and Gleam do not.

## Proposed contract additions

Proposals only. Nothing below exists; no sender sends any of it. Shapes are in the schema's notation and keep
Silica's limits (a tuple of at most 8 elements, a record of at most 4 fields, no bare atom in a list of tagged
tuples).

| # | For | Proposal |
| --- | --- | --- |
| P1 | E6, X8: trapping exits | Node `(:trap_exits, int64, int64)`: `at`, then the index of a boolean expression; its value is the earlier setting. Rule: while a process traps exits, an exit signal reaches it as the message `(:tuple [(:symbol "EXIT"), from, reason])` (for Gleam: whatever shape the rule fixes), and an `(:exit_signal)` with reason `kill` still ends it. Requirement A5.5. An alternative with no node: a new A5.5 choice `:trap_as_message` for the session or as an override on a `(:spawn)` |
| P2 | E8, X12, G13: calls to modules outside the session | Either (a) a node `(:foreign_call, int64, string, string, List[int64, mem(normal)])` (`at`, module, function, arguments) with a list, in the app design, of the modules and functions the transpiler implements (`io:format/2`, `erlang:display/1`, `IO.puts/1`, `gleam/io.println/1`, integer and float to text), everything else a T4001 gap; or (b) a rule in T9.9 that a `(:call)` whose `module` names no unit of the session is such a call, plus a form `(:extern, { module: string, name: string, arity: int64, silica: string })` that binds it to a Silica function. (b) changes no node |
| P3 | `try`/`catch`/`rescue` (H27) | Keep the node `(:try, at, body, clauses, catches, after)` and state: `clauses` are `(:clause)` nodes with one pattern, matched against the body's value (Erlang's `of`; empty for Elixir and for a plain `try`); `catches` are `(:clause)` nodes with exactly **two** patterns, the class and the reason, the class being one of the symbols `error`, `exit`, `throw` or a variable or `_`; a stack trace is not available (a third pattern is `:bad_index`); Elixir's `rescue E in Mod` is class `error` with a reason pattern the sender builds. Say which failures of BEES A5.1 each class catches |
| P4 | G3: a subject's own messages; request and reply | Node `(:make_ref, int64)`, a value equal only to itself, and the kind `:reference` in `(:t_basic, …)`. A Gleam subject is then the tuple (owner, reference), a send wraps the message with the reference, and a receive is a clause whose pattern holds the reference (with P6 to compare it) |
| P5 | X13 and the Erlang and Gleam alias patterns | One sentence in §9.4, no shape change: "a `(:match, at, a, b)` referenced where a pattern is expected is an alias pattern: the value must match both `a` and `b`, which are both patterns". The three senders already send this |
| P6 | X9: the pin; equality inside a pattern | Node `(:pin, int64, int64)`: a pattern that matches the values exactly equal to an expression. It replaces the stand-in variable with a guard and covers a pinned `=` used for its value. Also say whether a variable written twice in one pattern means equality (Erlang) or is an error |
| P7 | rebinding | A rule in H16: a `(:var)` in a pattern whose name is already bound in the function clause is (choose one) an error, a new binding that hides the old one, or a test for equality. The Elixir sender avoids the question by renaming; Erlang needs "a test for equality", Elixir and Gleam "a new binding" |
| P8 | G2: supervisors; the meaning of A4.4 | Node `(:supervise, int64, List[int64, mem(normal)], { strategy: :one_for_one \| :one_for_all \| :rest_for_one, restart: :permanent \| :transient \| :temporary, max_restarts: int64, period_seconds: int64 })`: the list holds functions of no arguments that each start one child; the value is the supervisor's process; a restart runs the start function again. And state how `link` true on a `(:spawn)` acts together with the A4.4 restart (does the spawner get an exit signal for a child that is then restarted?), and whether an unlinked `(:spawn)` is restarted at all |
| P9 | G1: an actor's start with an initialiser | Nodes `(:unlink, int64, int64)` and `(:monitor, int64, int64)`, with a stated shape for the down message. `actor.start` must wait for the new process's acknowledgement and end it on a timeout |
| P10 | Gleam `let assert … as message` | Node `(:match_or_fail, int64, int64, int64, int64)`: pattern, value, the reason to fail with |
| P11 | names | Say that a `(:record)` node's `name` and a `t_named` name refer to the `head.name` of a `:type` form, that the session has one namespace for types, and whether those names (and function, field and variable names) must be Silica identifiers. The senders now make them identifiers (N3, N4) |
| P12 | C18 | Make `Result.counts.gaps` mean one thing in check mode and transpile mode, so a sender can compare them |
| P13 | selective receive after a split (T9.13a) | A choice or a hint by which a sender states what the waiting process does with a message no clause takes: `drop` (today), or `keep` (the message is offered again to the next receive the process waits in). `keep` needs a save queue in the process's state, which a first attempt in the sink could not hold (limitation observed, design §5.5); until then a sender cannot ask for it, and re-sending to `self()` from the sender is not expressible (the `nomatch` arm is the sink's) |
| P14 | T9.16: text from a number | The builtins on the L1 list print; none gives the text of a number, because Silica has no integer-to-text or float-to-text builtin (limitation observed). A language whose output is built by concatenation (Gleam's `int.to_string`, Elixir's interpolation) needs either helper functions the sink writes (`to_silica_int_text`, as it writes `to_silica_i2f`) named in T9.16, or its sender must turn every concatenation that is printed into a sequence of prints |
| P15 | T9.13a: a function that only processes run | A way to say that a function is a piece of a process (never called as an ordinary function), so that the sink writes no ordinary version of it. Today the sink writes both versions of a function with a tail call and does not report the dead ordinary one when the function is not exported (T9.13); a marker would let it leave the dead code out |

