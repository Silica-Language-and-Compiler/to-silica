# Gaps found by sending working applications through the senders

2026-11-13. Three applications, each with a coordinator, a supervised stateful actor and a supervisor, were written,
run in their own language, and sent through the proof-of-concept senders to the transpiler (`silica-sink/`) in check
mode and in transpile mode. The Silica output was exported with `tools/export_debug_output.py` and compiled with
`../silica/binaries/silica-999919-macos-applesilicon`. This file records every gap found. Nothing on the transpiler
side was fixed in that first run; what has been fixed since is in the next section.

## Three nodes that send messages to each other (2026-11-16, compiler 999909, BEES BEAM mode with EPMD)

The inter-node gap of the earlier sections (`shout/1`, `is_distributed`: "by rule") is filled **as far as a send to a
registered name and an answer to a registered name**; the rest stays a gap. Contract T9.17 (one `(:node)` form), the
sink (writes `<unit>.wire` and `<unit>.bees.config`), the Erlang and Elixir senders, and a hub example in each
language (`examples/three_nodes/`: `hub`, `edge_a`, `edge_c`).

| What | State |
| --- | --- |
| Erlang hub, edge_a, edge_c sent to the sink (transpile) | `ok`, 0 gaps, 3 files each |
| Elixir hub sent to the sink (transpile) | `ok`, 0 gaps, 3 files (the two Elixir edges were sent in check mode only: the sink's four regions were held by earlier unreleased sessions) |
| the manifest and `bees.config` the sink wrote, for all three Erlang nodes | accepted by BEES's `tools/bees_config_beam.py generate` |
| the three printed Erlang units | compile with 999909 (with `Supervisor.silica`); they cast `(:request, :a_inbox, 21)` to `:hub_in` and `(:reply, v)` to `:a_inbox`, the tuples BEES's proxies carry |
| contract goldens | 27 of 27 against the new sink, with four new ones (`ok_node_declaration`, `reject_bad_node`, `ok_node_redial`, `reject_node_no_redial`) |
| Gleam | **compiled and run 2026-11-18** (Gleam 1.19.2): 68 tests pass, the three examples transpile with no gap, and the three nodes ran live (42 and 68; `tools/node_kit/live_run_gleam_*.txt`). Its examples still write the peer host as `127.0.0.1` |
| **a live run of three nodes** (hub and both edges, Erlang) | **done, 2026-11-17** (`tools/node_kit/`, `live_run_*.txt`): built with BEES's own check (no patch), EPMD lookup, cookie digest, handshake with both edges; `hub: request 21 from a_inbox`, `hub: request 34 from c_inbox`, `a: the hub answered 42`, `c: the hub answered 68`. BEES now takes a unit's `.atoms`, connects every `peer` line, and requires `redial` on a dialing node (the sink writes it: contract T9.17) |
| **a live run of a complete mesh** (three nodes, a link for each pair) | **done: Erlang 2026-11-19, Elixir and Gleam 2026-11-20** (`examples/three_nodes_mesh/` of each sender; `tools/node_kit/live_run_mesh_*.txt`, `live_run_elixir_mesh_*.txt`, `live_run_gleam_mesh_*.txt`): 0 gaps each; `mb` both dials and listens; six requests and six answers, each link used in both directions |
| **a live run of a complete mesh of five nodes** (ten links) | **done, 2026-11-20, Erlang, Elixir and Gleam** (`examples/five_nodes_mesh/` of each sender; `tools/node_kit/live_run_mesh5_*.txt`, `live_run_elixir_mesh5_*.txt`, `live_run_gleam_mesh5_*.txt`): 0 gaps each; every node completed four handshakes; twenty requests and twenty answers in each language |
| still open | the root unit and start-up are written by `tools/node_kit/build_node.sh` with BEES's tools, not by the sink; the Erlang and Elixir examples name the peer host (`"localhost"` with an `epmd` lookup, BEES's Change 3; the Erlang and Elixir sets ran live with it on 2026-11-18; a dialing node is built with BEES's resolver edge, which `build_node.sh` adds); the three modules of the Gleam example do not talk to each other when run as Gleam on the BEAM (nothing starts distribution there); compiler 999906 since 2026-11-18 |
| not carried | a send to a pid on another node, `spawn` on another node, monitors and links across nodes, `nodedown`, `rpc`, `global`: still gaps |
| the answer to a request | the request carries the registered name to answer to (a field); the answering function chooses the send by it, in the source |

## Status after the Gleam examples reached no gap (2026-11-14, after the Elixir ones)

| Program | Result | `counts.gaps` | Calls compared | Match | Mismatch | Fail in both |
| --- | --- | --- | --- | --- | --- | --- |
| Gleam `demo.gleam` | `ok` (was `partial`) | 0 (was 8) | 47 | 46 | 0 | 1 (`positive(-1)`, a `panic`) |
| Gleam `actors.gleam` | `ok` (was `partial`) | 0 (was 4) | 17 (14 calls and the 3 lines `main` prints as the program) | 17 | 0 | 0 |

All three senders' examples are now transpiled with no gap. What was done for Gleam, gap by gap, is in
[SENDER_GAPS_STATUS.md](SENDER_GAPS_STATUS.md) ("the Gleam examples have no gap"): the static supervisor is read
by the sender and sent as static children (T9.14b), a function literal that captures nothing is lifted, the
deliberate gap examples moved to `gleam-to-silica-poc/test/fixtures/gaps.gleam`. No change in `silica-sink/`,
none in the contract.

| What still differs from Gleam in the two examples | Cause | Status |
| --- | --- | --- |
| a float is printed with at most 15 decimal places, cut and not rounded (`3.141589999999999` for `3.14159`) | Silica (limitation observed) | documented; compared as numbers |
| `ping_pong(41)` called as an ordinary function fails; spawned it gives 42 | contract T9.13 (a function that waits runs only as a process) | by design; counted apart |
| `main` (and any public function that waits only in a function it calls) is not exported | the sender, so that the transpiler does not write an ordinary version that can only fail (T9.13) | documented in the sender's README |
| the auditor exists from the program's start, its name is `auditor` (no suffix), its supervisor is no process | contract T9.14b | documented ("A static supervisor") |
| selective receive is not kept (`T4004`, 3 warnings) | transpiler (app design 5.5) | open, as before |

## Status after the Elixir examples reached no gap (2026-11-14, last)

**Read this section first.** The two Elixir examples are now transpiled with result `ok` and `counts.gaps` 0, as
the two Erlang examples are. `demo.ex` no longer holds its deliberate gaps (they are in the sender's
`test/fixtures/gaps.ex`); its hand-written supervisor is Elixir's `Supervisor` with one static child, which the
sender reads and sends as the contract's static child (T9.14b, the rule the Erlang sender uses; no new rule, no
schema change, nothing of the sink changed). Details and the table of every gap's resolution:
`SENDER_GAPS_STATUS.md`, "the Elixir examples have no gap"; the runs: `silica-sink/STATUS.md`, the section of
the same name.

| Program | Result | `counts.gaps` | Calls compared | Match | Mismatch | Fail in both | Stub in Silica |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Elixir `demo.ex` | **`ok`** (was `partial`) | **0** (was 8) | 55 | **53** | 0 | 2 (`ratio(7, 0)`; `tally_total()` after `tally_stop()`) | 0 |
| Elixir `actors.ex` | `ok` | 0 | 35 | **35** (was 34 of 40) | 0 (was 1) | 0 | 0 |
| Erlang `demo.erl` (the section below) | `ok` | 0 | 43 | 43 | 0 | 0 | 0 |

Counted apart: 1 call (`demo.ex`) and 5 calls (`actors.ex`) of a process function as an ordinary function, which
fail in Silica by design (contract T9.13; started as processes the same functions match).

| What remains, for the Elixir examples | Whose | State |
| --- | --- | --- |
| a float is printed with at most 15 decimal places, cut and not rounded (`13.333333333333333` for Elixir's `13.333333333333334`, `3.141589999999999` for `3.14159`; measured in this step; the older sections said "16 significant digits" and were corrected 2026-11-14) | Silica: it has no builtin that writes the shortest text that reads back (limitation observed) | documented; the comparison reads floats as numbers, so the row is no mismatch any more. The example was not changed |
| selective receive is not kept (`T4004`, 4 functions of `actors.ex`) | sink (no save queue; P13) | a warning, not a gap; `Actors.main/0` is not affected |
| what differs for a static supervisor (children from the program's start, a second start does nothing, the supervisor is no process, `max_restarts`/`max_seconds` not carried) | contract T9.14b | stated; the second start and a restart after a failure were run |
| lists in Elixir | the Elixir sender (it maps none) | open sender work; `sum_list/1` left the example for it |
| a closure (`fn x -> x + n end`), a `fn` bound to a variable | sink (no closures) / sender (no type) | gaps as before, in the fixture; a `fn` that captures nothing is now sent as a function |
| the `T4002` note for a function only processes run (P15) | sink / contract | neither example gets it; the fixture `split_shapes.ex` does (1 gap) |

## Status after the static supervisor (2026-11-14, later)

**(Read after the section above.)** The Erlang `demo.erl` no longer has a hand-written supervisor (`supervise/1`, which
no driver could run: its child was out of reach). It has OTP's: `-behaviour(supervisor)`, `init/1` with one
child, the counter registered as `tally`. The sender sends it as a **static child** of the unit's supervisor
(contract T9.14b, new: a rule over the existing nodes `(:register)`, `(:spawn)` and the `a4_4` override; no schema
change), and the sink prints it into the supervisor's `init`. Details: `silica-sink/STATUS.md`, "a static
supervisor"; the decision: `SENDER_GAPS_STATUS.md`, "a static supervisor".

| Program | Result | `counts.gaps` | Calls compared | Match | Mismatch | Stub in Silica |
| --- | --- | --- | --- | --- | --- | --- |
| Erlang `demo.erl` | `ok` | 0 | 43 | **43** | 0 | 0 |

The six calls of the supervised child (`start_sup()`, `tally_add(3)`, `tally_add(4)`, `tally_total()` = 7, the
driver's own `tally ! {get, self()}` = 7, `tally_stop()`) match. After the stop a `tally_total()` ends its
process in both (`badarg` in Erlang, `actor_not_found` in Silica). In a scratch copy whose counter can be made to
fail, the child is started again with 0 under its name in both.

| What differs from Erlang | Whose | State |
| --- | --- | --- |
| the static child exists from the program's start, not from `supervisor:start_link`; a second start does nothing | contract T9.14b (Silica's static child list) | stated in the rule and in the sender's README; not run |
| the source's supervisor is no process (no pid, no stop, no `which_children`); `demo_sup` is no name | contract / sink: a unit has one supervisor | gap in the sender when the source uses them |
| `one_for_all`, `rest_for_one` for a source supervisor | sink: one supervisor for a unit | reported (`T2001`), not followed |
| `intensity`, `period` | contract: BEES A4.4 has no parameter | not carried (100 restarts in 10 s); **open, the contract owner's** |
| OTP supervisors of the Elixir and Gleam examples | their senders | Elixir: **done since** (the section above). Gleam: not done, its `static_supervisor` child has a name made at run time (still a gap) |

**Open decisions, unchanged:** the session's restart default for an ordinary `(:spawn)` (`transient` in the three
senders: a failed process is started again, which none of the languages does). The static child does not depend
on it: its restart is its own, from the child specification.

## Status after the Elixir and Gleam senders' split (2026-11-14)

**(Read after the section above.)** The Elixir and the Gleam sender now lower their own languages as the Erlang sender
does (contract §1 "What you own", T9.13a, T9.15, T9.16): each splits a function at every receive, sends its
language's output as `(:sl_call)` of Silica's print builtins, and lowers what else its examples needed (Elixir: a
trapped exit, a literal in a struct pattern; Gleam: a plain `gleam_otp` actor, a subject's message type, lists,
constants). **Only the two senders changed; the sink and the contract did not.** Tables and how it was run:
`silica-sink/STATUS.md`, "the Elixir and Gleam senders split".

| Program | Result | `counts.gaps` | Calls compared | Match | Mismatch | Fail in both | Stub in Silica | Not in the unit |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Elixir `actors.ex` | **`ok`** (was `partial`) | **0** (was 4) | 40 | **34** (was 20 of 37) | 1: a printed float's 17th digit | 0 | 5, all a process function called as an ordinary function (by design, contract T9.13) | 0 |
| Elixir `demo.ex` | `partial` | 8 (was 10) | 56 | 41 | 0 | 1 | 6 | 8 |
| Gleam `actors.gleam` | `partial` | 4 (was 10) | 18 | 14 | 0 | 0 | 4: `main` | 0 |
| Gleam `demo.gleam` | `partial` | 8 (was 14) | 52 | 44 (was 37 of 47) | 0 | 1 | 6 | 1 |

**`Actors.main/0` (Elixir), run as the program, prints what Elixir prints** (`{:refused, 30}`, `{:ok, 40}`,
`ada: low`, `{:balance, 40, :mean_move, 13.333333333333333}`, `account closed`; Elixir's float ends in `4`) and
ends with status 0. **`main` of `actors.gleam` still prints nothing**: it ends in the stub of `start_audit()`,
which needs `process.new_name`, a named actor and a static supervisor. With those two taken out (a scratch
`plain.gleam`: the counter and the auditor as plain `gleam_otp` actors) the program prints the three lines
Gleam prints and ends with status 0. A scratch Elixir module with every shape the split cuts
(`elixir-to-silica-poc/test/fixtures/split_shapes.ex`) printed, as a Silica program, the 16 lines Elixir prints.

Rows of the earlier tables that this closes or moves:

| Cause | Was | Now |
| --- | --- | --- |
| a receive that is not in tail position (`Actors.main/0`; Gleam `main`, `ask/1`, `summary/1`) | the sender's, not done | **done** in both senders (`lib/e2s/split.ex`, `src/gleam_to_silica_poc/split.gleam`) |
| a call of a function that receives, with code after it or as an argument (`IO.inspect(withdraw_from(account, 100))`, `case ask(counter) {`) | the sender's, not done | **done**: the value bound first where only variables and literals are evaluated before it, then a copy of the callee |
| three types for the tag `reply` (the memory fault of the night's run) | **the example and its sender** | **the example**: each answer of the account has a tag of its own; `await_reply/0` (`term()`) is gone. The sink still does not check two types for one tag (T9.12, open) |
| `Process.flag(:trap_exit, true)` with `spawn_link` (`supervisor/1`, `supervise/1`) | sender / contract | Elixir: **done, as the approximation** the Erlang sender makes (a linked copy that sends `{:EXIT, self(), :normal}`) |
| output (`IO.puts`, `IO.inspect`, `io.println`) | contract (T9.9) | **done** in both senders with the builtins of T9.16; Gleam for a `<>` chain with `int.to_string` and `float.to_string` |
| the type `dynamic` for a Gleam subject's messages and for `actor.Next` | sink / contract | **the sender's, done**: a variant type is sent as it is, any other message type under a tag the sender makes; no `dynamic` is sent for an actor |
| Gleam list patterns, constants, `list.length`'s type, type aliases | sender | **done** (`count/1` is still a stub: `list.length` is a call into another module, T9.9) |

What is **not** the language's behaviour in what is now written (each is in its sender's README):

| Difference | Cause | Seen in the run? |
| --- | --- | --- |
| a message no clause of the waiting receive takes is dropped (Elixir and Erlang keep it; a Gleam subject takes only its own messages) | **sink** (no save queue); every split function gets `T4004` | no: every message the examples' processes get arrives while they wait for it |
| a linked child (Elixir) that ends by a failure the runtime raises tells its parent nothing; the link's other direction is not kept | **sender** (its lowering; the contract has no node, T9.15) | no: the account ends by `:stop` |
| a `gleam_otp` actor is not linked to its starter; `actor.start` does not wait for an initialiser | **sender** (T9.15: no link is written) | no |
| a failed process is started again by the unit's supervisor (`a4_4 transient`), which none of the languages does | **sender's choice** (the hello; a decision for the contract's owner, P8) and contract T9.14 | not tried |
| floats are printed with at most 15 decimal places, cut and not rounded (corrected 2026-11-14: this row said "16 significant digits") | Silica's `print_float64` (limitation observed) | **yes**: `13.333333333333334` prints as `13.333333333333333` (Elixir `Actors.main/0`, line 4) |
| `IO.inspect` writes a string without escaping it, and an atom of the type `atom()` as `:name` always | **sender** (it prints by the stated type) | no |
| a process function called as an ordinary function fails | **by design** (contract T9.13) | yes: 5 rows of `actors.ex`, 1 of `actors.gleam`; started as processes they match |

Still open after this step, by cause:

- **sender (Gleam):** `process.new_name`, `actor.named`, `process.named_subject`, the static supervisor (3 gaps
  of `actors.gleam`; a name made at run time is no literal of H38/H39, and "the named subject is the process"
  is not what a supervisor that restarts under the name means); a tuple index; `use`; an actor handler that is
  a closure; selectors, `actor.call`, initialisers.
- **sender (Elixir):** lists, maps, `number()`, a function without `@spec` (`demo.ex`, on purpose);
  `IO.inspect` of a struct, a pid or a list; a receive after a call in the same expression (a gap that says to
  bind it); `Process.link/1` on an existing process (nothing honest to send: `(:link)`).
- **sink:** selective receive; closures (`add_ten/1`, `add_four`, `pipeline`); `(:link)` and a linked spawn; a
  union with an alternative that is not a symbol, a tagged tuple or a record (`name_or/2`); **a dropped
  statement or a process's end value of a union type** (written `_: A | B <- e`, which Silica does not accept:
  limitation observed; both senders avoid it for the examples); a call of a function that was sent as a gap form
  (written as a call of an unknown function); the result of a process to a watcher when it is not a scalar.
- **contract:** a call to a module outside the session (T9.9: Gleam `list.length`, `receive_message` of
  `demo.gleam`); text from a number outside a print (P14); what happens to an unmatched message (P13); names
  made at run time and supervisors (P8); trapping exits has no node (P1).
- **by rule:** inter-node (`shout/1`, `is_distributed`).

## Status after the Erlang sender's split (2026-11-13, late)

**Read this section first.** By direction, a language's own semantics are the sender's to lower, not the sink's
(contract §1 "What you own", T9.13a, T9.16; `HOWTO_language_creators.md` §6a). The Erlang sender now splits a
function at every receive that has code after it, lowers a trapped exit and `io:format`, and sends the result
with the nodes the sink already printed; the sink gained the printing of one low-level node (`(:sl_call)` of a
Silica print builtin) and a diagnostic that tells a sender to split. The Elixir and Gleam senders were not
changed. Tables and how it was run: `silica-sink/STATUS.md`, "The split, run".

| Program | Result | `counts.gaps` | Calls compared | Match | Mismatch | Stub in Silica | Not in the unit |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Erlang `actors.erl` | **`ok`** (was `partial`) | **0** (was 4) | 22 | **19** (was 6 of 18) | 0 | 3, all three a process function called as an ordinary function (by design, contract T9.13) | 0 |
| Erlang `demo.erl` | `partial` | 5 (was 7) | 40 | 37 | 0 | 2 | 1 |

**`actors:main/0`, run as the program, prints what Erlang prints** (`total 7 after 2 adds, mean 3.5: small`,
`total 36 after 3 adds, mean 12.0: large`, `the counter stopped; restarts: 0`) and ends with status 0.

Rows of the table below ("What differs from the language, by cause") that this closes or moves:

| Cause | Was | Now |
| --- | --- | --- |
| a receive that is not in tail position of its function | **sink** | **the sender's** (contract T9.13a). Erlang: done (`e2s_split.erl`). Elixir `Actors.main/0`: still the sink's stub, because its sender does not split yet (SENDER_GAPS_STATUS.md says what it needs). The sink's diagnostic now says that the sender must split |
| a record pattern with a literal field | **sink** | Erlang: the sender sends the field as a variable and a guard (`average/1` is written, and with it the counter answers `{get, From}`). The sink still does not print a literal there; no other example has one |
| links, trapping exits | **sink** / **sender, contract** | Erlang: the sender lowers `process_flag(trap_exit, true)` + `spawn_link` + the receive of `'EXIT'` to a child that sends the message itself (`supervisor/2`, `supervise/1` are written). **An approximation**, listed below. `(:link)` and a linked spawn without it are still not written (T9.15) |
| output (`io:format`) | **contract** (T9.9: a call to another module) | Erlang: the sender sends `(:sl_call)` of Silica's print builtins (contract T9.16, which the sink prints) |

What is **not** Erlang's behaviour in what is now written (each is in the Erlang sender's README):

| Difference | Cause | Seen in the run? |
| --- | --- | --- |
| a message no clause of the waiting receive takes is dropped (Erlang keeps it) | **sink** (no save queue: limitation observed, design §5.5); every split function gets `T4004` | no: every message `main/0` gets arrives while it waits for it |
| a linked child that ends by a failure the runtime raises tells its parent nothing; the link's other direction is not kept; an exit reason is an atom | **sender** (its lowering of a trapped exit; the contract has no node for it, T9.15) | no: the counter ends by `stop` |
| a failed child is started again by the unit's own supervisor (`a4_4 transient`) with its first state, which Erlang does not do | **sender's choice** (the hello) and **contract** T9.14 | not tried |
| floats are printed with at most 15 decimal places, cut and not rounded (`13.333333333333334` would print as `13.333333333333333`; corrected 2026-11-14: this row said "16 significant digits") | Silica's `print_float64` (limitation observed) | no: `3.5` and `12.0` print as in Erlang |
| `main()` called as an ordinary function from a Silica driver fails (a process function runs only as a process) | **by design** (contract T9.13) | yes: 3 rows (`supervisor/2`, `counter/1`, `main/0` called so); started as processes they match |
| the value a process ends with reaches a watcher only when it is a scalar | **sink** | not visible: `main/0`'s `{restarts, 0}` goes to nobody (the program's exit status is 0, as Erlang's `main` returning has no status either) |

Still open after this step, by cause:

- **sender (Elixir, Gleam):** no split, no lowering of output or trapped exits: `Actors.main/0`, `withdraw_from/2`,
  `report/1`, `supervisor/1`; Gleam `main/0`. Listed in SENDER_GAPS_STATUS.md.
- **sink:** selective receive (a save queue); closures; `dynamic`; `(:link)`; a union with an alternative that is
  not a symbol, a tagged tuple or a record; the result of a process to a watcher when it is not a scalar; the
  `:low_level` checks at receipt (an `(:sl_call)` the printer does not write is accepted in check mode).
- **contract:** trapping exits has no node (a sender can only approximate it); a call to a module outside the
  session has no meaning (T9.9) except through the print builtins of T9.16; text from a number (proposal P14);
  stating what happens to an unmatched message (P13).
- **Silica (limitations observed, nothing changed there):** a program whose entry process ended from a waiting
  phase that kept five values it did not use (`float64, int64, int64, (int64, int64, float64), actor_ref`) ended
  with a memory fault after printing everything; with only the used variable kept it ends with status 0 (the
  Erlang sender now sends it so). Not followed further.

## Status after the examples were run (2026-11-13, night)

**Superseded for the two Erlang rows by the section above.** Every example was converted, compiled, linked with a hand-written driver that
calls every function its unit exports (the process functions through `<f>__spawn_watched`, each failing stub in
an actor of its own, the unit's own `main` as a program of its own) and **run**, and each call was compared with
the same call in the example's own language. The call-by-call tables, and how it was run, are in
`silica-sink/STATUS.md`, "The examples, run". Since the section below: the Gleam sender sends `process.send` as
the contract's send followed by `nil` (H22), the Elixir sender follows T8.16, and the sink writes a symbol
message whose hint states the whole message type (contract T9.12, amended).

| Program | Result | `counts.gaps` | Calls compared | Match | **Mismatch** | Fail in both | Stub in Silica | Not in the unit |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Erlang `demo.erl` (run again) | `partial` | 7 | 40 | 37 | 0 | 0 | 2 | 1 |
| Erlang `actors.erl` | `partial` | 4 | 18 | 6 | 0 | 0 | 12 | 0 |
| Elixir `demo.ex` | `partial` | 10 | 56 | 41 | 0 | 1 | 6 | 8 |
| Elixir `actors.ex` | `partial` | 4 | 37 | 20 | **5** | 0 | 12 | 0 |
| Gleam `demo.gleam` | `partial` | 14 | 47 | 37 | 0 | 1 | 7 | 2 |
| Gleam `actors.gleam` | `partial` | 10 (was 11) | 18 | 14 | 0 | 0 | 4 | 0 |
| scratch `sendnil.gleam` (`add/3` of `actors.gleam`, public) | `ok` | 0 | 10 | 10 | 0 | 0 | 0 | 0 |

"Match": the Silica program printed what the language printed (floats compared as numbers). "Fail in both": the
call ends its process in both (a division by zero, a `panic`). "Stub": the function is a failing stub in the
unit, or its process ends in one: the call was made, and it ended the actor that made it with Silica's
`integer division by zero` (the stub's `to_silica_gap`); no stub returned a value. "Not in the unit": no
signature could be written, so there is nothing to call. **No call that returned gave a wrong value.**

### What differs from the language, by cause (2026-11-13, night)

| Cause | Side | Where it shows | Seen as |
| --- | --- | --- | --- |
| **three types for one message tag in a unit** (`{:reply, {:ok, n}}`, `{:reply, {:refused, n}}`, `{:reply, {text, balance, mean}}`) | **the example and its sender** break contract T9.12 (a tag has one type in a unit); the **sink** does not check it; Silica accepts the sum and a `case` over it faults when such a message arrives (**limitation observed**) | Elixir `Actors.account/1`'s three replies | **mismatch**: the driver's actor ends the program with a memory fault at the first reply (5 rows). In a program of one function the same sum gave `1`, `1002` and then `6089159424` for the third alternative |
| a receive that is not in tail position of its function | **sink** (BEES A3.3 inside one function is not built; contract T9.13) | Erlang `actors:main/0`; Elixir `Actors.main/0` | stub; the unit's own program starts, its entry process ends in the stub, nothing is printed, exit status 0 |
| a record pattern with a field pattern that is not a variable or `_` | **sink** | Erlang `actors:average/1` (`#tally{adds = 0}`), and through it `counter/1`: the counter adds, and ends in the stub when it is asked `{get, From}` | stub: `average/1` itself, the answer to `{get, From}` (nothing is received), the value the counter ends with (nothing comes back) |
| links, trapping exits | **sink** for `(:link)` (contract T9.15); **sender / contract** for trapping exits (no node; sent as the senders' gaps) | Elixir `stop_counter/1`; Erlang `supervisor/2`, Elixir `supervise/1`, `supervisor/1` | stub |
| a function with no type the sender can state (`term()`, `number()`, no `@spec`, a fn parameter, a list type in Elixir, list patterns and `list.length` in Gleam, `process.new_name`) | **sender** (each is the sender's gap with its reason; several are deliberate examples) | Elixir `await_reply/0` and with it `withdraw_from/2`, `report/1` (as processes they send their request and end in the stub), `area/1`, `max_of/2`, `boxed/1`, `sum_list/1`; Gleam `sum_list/1`, `first_of/1`, `count/1`, `start_auditor/1`, `start_supervisor/1`, `start_audit/0`, `limit`, `Pair` | stub, or not in the unit |
| closures | **sink** (a Silica function literal captures only integer literals: limitation observed) | Elixir `add_ten/1`; Gleam `add_four/1`, `pipeline/1` | stub |
| the type `dynamic` (an untyped process reference or message, an external type) | **sink** (no untyped representation, P4) and **contract** (nothing else to send) | Gleam `ping_pong/1`, `pong_loop/0`, `start_linked/0`, `stop/1`, `main/0` of `actors.gleam` and everything of its `gleam_otp` actors | stub, or not in the unit; `actors.gleam`'s own program prints nothing |
| a receive clause that takes any message | **sink** and **contract** (T9.12) | Gleam `ask/1`, `summary/1` (private: reached only from `main`) | stub, not callable |
| a union with an alternative that is not a symbol, a tagged tuple or a record | **sink**, from a Silica limitation observed (E2003) | Elixir `name_or/2` | not in the unit |
| foreign code, inter-node calls | **contract** (T9.9; inter-node is out of scope by rule) | Elixir `shout/1`; Gleam `receive_message`, `is_distributed` | stub, or not in the unit; not called in the language either |
| **a process function called as an ordinary function** | **by design** (contract T9.13): only an actor can receive | `counter(10)`, `account(…)`, `pong_loop()` called from the driver | stub: in the language the caller's process runs it. The driver starts it with `<f>__spawn_watched` instead, and that matches |
| **the value a process ends with reaches its watcher only when it is an `int64`, `float64`, `boolean`, `atom` or `string`** | **sink** (the runtime has `to_silica_result_<type>` for those five) | Erlang `ask/1` (a tuple), Elixir `withdraw_from/2`, `report/1` (a tagged tuple, a tuple): stubs today for other reasons | would show as "nothing comes back" once they are written |
| **a send to a process that has ended ends the sender** | **sender's choice** (`a5_4 accept_sender_death` in the three hellos; Silica's `cast`: limitation observed) | Elixir: the account answered a `withdraw_from` process that had ended in its stub, and ended itself with `actor_not_found`; in Elixir the send does nothing | a consequence of the stubs here; it will show in any program that answers a process that may be gone |
| a function that is private in the source is not exported by the unit | by design | Gleam `add/3`, `ask/1`, `summary/1`, `negate/1`; Erlang `actors:ask/1` | not callable from a driver; `add/3` was run in a scratch copy where it is public (10 of 10) |

Closed since the section below: Gleam `add/3` (`T3103`: the sender now sends the block `{ send, nil }`); a
symbol message hinted with a whole message type (`T4002` in the sink); the Elixir sender's `true andalso …`
guards (T8.16).

### Open decisions (2026-11-13, night)

1. **One type for a tag (T9.12) is not checked by anyone.** Should the sink report two types for one tag in a
   unit, with which code and severity, and is the unit then written? Today the unit is written, compiles and
   faults when it runs. Or should the sink write such messages differently (one alternative for each tag and
   element types)? Not decided here; the contract's T9.12 now says what was measured.
2. **The restart default** (`a4_4 transient` in the three hellos against `temporary`): not touched. Seen in the
   runs: after a counter had ended in a stub its reference was dead (a cast to it ended the caster); whether
   the supervisor started it again was not looked at.
3. **The value of a process that is not one of five scalar types** (see the table): which types a watcher gets.
4. **`demo.gleam` names `demo_ffi`, which the repository does not have**: add the file to the Gleam example, or
   leave the process part of the example as it is (it is a gap in the sink anyway).

## Status after the process nodes (2026-11-13, evening)

**(Superseded by the section above for what remains.)** Since the section below: the printer writes the process nodes as supervised Silica
actors (`silica-sink/silica_sink_design.md` §5.5, contract §9.4a), exit requests, record patterns and alias patterns, `++`, and
function names that are Silica reserved words (contract T9.11); the Erlang sender no longer sends a type test
that only states a type (contract T8.16). `erlang-to-silica-poc/examples/demo.erl` was converted, compiled,
linked with a hand-written driver and **run, its processes included**, and compared call by call with the same
calls in Erlang: `silica-sink/STATUS.md`, "The Erlang demo, run".

What was run: each sender, from a scratch copy of its directory, sent its two examples in transpile mode to a
transpiler built from the repository's `silica-sink/` (default build, one compiler run, 2 regions, memory store);
each session's unit was exported and compiled alone with compiler 999916 behind a prelude unit and with Silica's
`Supervisor` unit; each session was released.

| Source | Frames | Result | `counts.gaps` (was) | Diagnostics | Ordinary functions in full / process functions / failing stubs | Compiles? |
| --- | --- | --- | --- | --- | --- | --- |
| Erlang `demo.erl` | 35 | `partial` | 7 (15) | 4 T4001, 1 T4002, 1 T2001 | 21 / 3 / 4 | **yes**, and runs |
| Erlang `actors.erl` | 14 | `partial` | 4 (8) | 1 T4001, 2 T4002, 1 T2001 | 3 / 2 / 3 | **yes** |
| Elixir `demo.ex` | 36 | `partial` | 10 (17) | 6 T4001, 3 T4002, 1 T2001 | 20 / 3 / 5 | **yes** |
| Elixir `actors.ex` | 17 | `partial` | 4 (10) | 2 T4001, 2 T4002, 1 T2001 | 6 / 1 / 4 | **yes** |
| Gleam `demo.gleam` | 41 | `partial` | 14 (16) | 7 T4001, 7 T4002 | 20 / 0 / 7 | **yes** |
| Gleam `actors.gleam` | 26 | `partial` | 11 (12) | 3 T4001, 7 T4002, 1 T3103 | 5 / 0 / 4 | **yes** |

A process function is a function with a receive: it is written as the phases of an actor, and under its own
name stands a failing stub (not counted in the last number). The T2001 diagnostic names the lowering choices of
the hello that the process runtime does not follow (`a3_4`, `a3_2`); it is no gap. Only the Erlang `demo` unit was
linked and run; the five others were compiled.

### Every remaining gap, and whose it is (2026-11-13, evening)

| Cause | Side | Where it shows |
| --- | --- | --- |
| a receive that is not in tail position of its function (code of the same function runs after it) | **sink** (BEES A3.3 inside one function is not built; contract T9.13) | Erlang `actors:main/0`; Elixir `Actors.main/0` |
| links, trapping exits | **sink** for `(:link)` and a linked spawn (contract T9.15; an exit request with a symbol reason is written); **contract** for trapping exits (no node) | Elixir `stop_counter/1` (`Process.link`); Erlang `supervise/1`, `supervisor/2`, Elixir `supervise/1`, `supervisor/1` (`process_flag`, sent as the senders' gaps) |
| a `(:send)` whose value is stated as another type than the message (`T3103`) | **sender** (contract H22: the value of a send is the message; Gleam's `process.send` gives `Nil`, so its sender must send the send as a statement followed by `Nil`). **Fixed in the Gleam sender (night)** | Gleam `add/3` |
| a receive clause whose pattern is a variable (it takes any message) | **sink** and **contract** (T9.12: the messages of a unit are one sum of tagged tuples, which no sender's type names) | Gleam `ask/1`, `summary/1` |
| the type `dynamic` (a subject's message, an external type) | **sink** (no untyped representation, P4), and the **contract** gives a language with untyped process references nothing else to send | Gleam `demo_message`, `ping_pong/1`, `pong_loop/0`, `start_linked/0`, `stop/1`, `handle_counter/2`, `start_counter/0`, `handle_auditor/2`, `main/0`, the generated actor loop |
| a record pattern with a field pattern that is not a variable or `_` | **sink** | Erlang `actors:average/1` (`#tally{adds = 0}`) |
| closures (`(:lambda)` that is not the fun of a spawn) | **sink** (a Silica function literal captures only integer literals: limitation observed) | Elixir `add_ten/1`; Gleam `add_four/1`, `pipeline/1` |
| a union with an alternative that is not a symbol, a tagged tuple or a record | **sink**, from a Silica limitation observed (E2003). A process function is not touched by it (its value goes to nobody): Erlang and Elixir `ping_pong/1` are written | Elixir `name_or/2` |
| a call to a module outside the session | **contract** (T9.9 gives it no meaning; SENDER_GAPS_STATUS.md P2) | Erlang `lookup/1` (`maps:is_key/2`) |
| foreign code, inter-node calls | **contract** (T9.9; inter-node is out of scope by rule) | Erlang and Elixir `shout/1`; Gleam `receive_message`, `is_distributed` |
| the sender cannot state a type: no spec, `number()`, `term()`, a fn parameter, the result of an outside function | **sender** (each is a gap the sender sends with its reason; several are deliberate examples) | Erlang `untyped/1`, `uses_untyped/1`; Elixir `area/1`, `max_of/2`, `boxed/1`, `await_reply/0` (and with it `withdraw_from/2`, `report/1`, which call it: failing stubs, reported on the unit); Gleam `count/1`, `start_auditor/1`, `start_supervisor/1`, `start_audit/0` |
| lists | **sender** (Elixir sends no list type; Gleam sends list types and no list patterns) | Elixir `sum_list/1`; Gleam `sum_list/1`, `first_of/1` |
| constants, type aliases | **sender** | Gleam `limit`, `Pair` |

Closed since the section below: process nodes in tail position (`pong_loop/0`, `counter/1`, `ping_pong/1`,
`start_counter/0`, `ask/1`, `account/1`); record and alias patterns whose parts are variables (`x_of/1`,
`first_x/1`, `bump/2`, `shift/2`, `deposit/2`, …); `++` (`greeting/0`); the names `move` and `main` (written as
`move__`, `main__`); the entry point of a unit whose entry function is written.

Rows of the first run: C2 (process nodes) **done for what contract §9.4a lists**; C7 (entry) **done**, also for an
entry function named `main` and for one that is a process function; C22 (keyword-named functions) **done**
(contract T9.11); C4 record and alias patterns **done** where their parts are variables; E4, E5, E7, E9, X7, X9,
X10, X14 (processes) **done** where the receive is in tail position; E10 (entry) **done** in the sink, and
`actors:main/0` itself is still a gap for its receives; X13 (alias pattern) **done**.

## Status after the types decision (2026-11-13, later the same day)

**(Superseded by the section above for what remains.) The rest of the file is the record of the first run and its row ids.** Since that run:
the user decided that the language side states every type and every numeric conversion (contract §8.6); the
printer was made to follow it; the three senders got a typing pass of their own; the examples were rewritten with
specs and annotations; the compiler is now `silica-999916-macos-applesilicon`.

What was run: each sender, from the repository, sent its two examples in transpile mode to a transpiler built from
the repository's `silica-sink/` (four-run build, 4 regions, memory store, port 7454); each session's unit was
exported with `tools/export_debug_output.py` and compiled alone with compiler 999916; each session was released.

| Source | Frames | Result | `counts.gaps` | Diagnostics | Functions written in full / as failing stubs | Compiles? |
| --- | --- | --- | --- | --- | --- | --- |
| Erlang `demo.erl` | 35 | `partial` | 15 | 9 T4002, 4 T4001, 0 T31xx | 16 / 9 | **yes** |
| Erlang `actors.erl` | 14 | `partial` | 8 | 6 T4002, 1 T4001, 0 T31xx | 2 / 5 | **yes** |
| Elixir `demo.ex` | 36 | `partial` | 17 | 10 T4002, 6 T4001, 0 T31xx | 16 / 9 | **yes** (was no: E2003, `/` on integers) |
| Elixir `actors.ex` | 17 | `partial` | 10 | 8 T4002, 2 T4001, 0 T31xx | 3 / 7 | **yes** (was no: E2003) |
| Gleam `demo.gleam` | 41 | `partial` | 16 | 9 T4002, 7 T4001, 0 T31xx | 18 / 8 | **yes** (was no: E2005) |
| Gleam `actors.gleam` | 26 | `partial` | 12 | 9 T4002, 3 T4001, 0 T31xx | 5 / 3 | **yes** |

No frame was rejected. No `T31xx` was reported: no sender left out a type the contract requires or mixed
operands. `erl_demo.silica` was also linked with a hand-written caller and run: `add(2, 3)` `5`, `scale(2.5, 4)`
`15.0`, `ratio(7, 2)` `3.5`, `whole(2.6)` `7`, `same(1, 1.0)` `true`, `sum_list([1, 2, 3])` `6`, `classify(0)`
`:zero`, `max_of(3, 9)` `9`, `total__1([1, 2, 3])` `6`, and `ratio(7, 0)` ended the program with `badarith` (the
sender's own guard, as Erlang's `/` by zero fails). A first run of it had printed `0` for `total__1` (`total/1`,
which is `total/2` with an accumulator): a list pattern inside a tuple pattern compiles and takes the wrong arm
(limitation observed, STATUS.md). The printer was changed to match on the list alone, and the run above is of the
unit printed after that change.

### Every remaining gap, and whose it is

| Cause | Side | Where it shows |
| --- | --- | --- |
| process nodes are not printed (`receive`, `spawn`, `send`, `link`, `self`) | **sink** (needs the lowering library, design §5) | Erlang `pong_loop/0`, `start_counter/0`, `counter/1` (both), `ask/1`; Elixir `pong_loop/0`, `start_counter/0`, `counter/1`, `stop_counter/1`, `account/1`, `withdraw_from/2`, `report/1`; Gleam `add/3`, `ask/1`, `summary/1` |
| a record pattern, an alias pattern (`(:match)` as a pattern) | **sink** | Erlang `x_of/1`, `first_x/1`, `bump/2`, `average/1`; Elixir `x_of/1`, `shift/2`, `deposit/2`, `withdraw/2`, `label/1`; Gleam `x_of/1` |
| closures (`(:lambda)`) | **sink** (a Silica function literal captures only integer literals: limitation observed) | Elixir `add_ten/1`; Gleam `add_four/1`, `pipeline/1` |
| `++` (list append) | **sink** | Erlang `greeting/0` |
| a union with an alternative that is not a symbol, a tagged tuple or a record (`integer() \| timeout`) | **sink**, from a Silica limitation observed (E2003) | Erlang and Elixir `ping_pong/1`; Elixir `name_or/2` |
| the type `dynamic` (a pid's or subject's message, an external type) | **sink** (no untyped representation, P4), and the **contract** gives a language with untyped process references nothing else to send | Gleam `demo_message`, `ping_pong/1`, `pong_loop/0`, `start_linked/0`, `stop/1`, `handle_counter/2`, `start_counter/0`, `handle_auditor/2`, the generated actor loop |
| a function named `move` (a Silica builtin) or `main` (Silica's entry point), and the entry point with it | **contract** (names are not decided: DECISION_DATA_printer.md §3) | `move/3` in all three demos; `main/0` and the entry in the three `actors` examples |
| a call to a module outside the session | **contract** (T9.9 gives it no meaning; SENDER_GAPS_STATUS.md P2) | Erlang `lookup/1` (`maps:is_key/2`) |
| trapping exits | **contract** (no node; P1) | Erlang `supervise/1`, `supervisor/2`; Elixir `supervise/1`, `supervisor/1` (`process_flag`) |
| foreign code, inter-node calls | **contract** (T9.9; inter-node is out of scope by rule) | Erlang and Elixir `shout/1`; Gleam `receive_message`, `is_distributed` |
| the sender cannot state a type: no spec, `number()`, `term()`, a fn parameter, the result of an outside function | **sender** (each is a gap the sender sends with its reason; several are deliberate examples) | Erlang `untyped/1`, `uses_untyped/1`; Elixir `area/1`, `max_of/2`, `boxed/1`, `await_reply/0`; Gleam `count/1`, `start_auditor/1`, `start_supervisor/1`, `start_audit/0` |
| lists | **sender** (Elixir sends no list type; Gleam sends list types and no list values or patterns; the sink prints both) | Elixir `sum_list/1`; Gleam `sum_list/1`, `first_of/1` |
| constants, type aliases | **sender** | Gleam `limit`, `Pair` |

### The rows below, fixed or open

| Rows | State |
| --- | --- |
| C1 to C24 | `silica-sink/STATUS.md`, "APP_GAPS.md, id by id". Fixed since the first run: C1, C3, C6 (by decision), C9 (by decision), C10, C11, C13 to C21, C23; C4 and C5 mostly; open: C2, C7 (with names), C8 (where no signature can be written), C12, C22 (names), C24 |
| E1, E2, X1, X2, G5, G6 (declared types, records) | **fixed** (types across forms, contract T8.14); record and alias patterns remain (sink) |
| X4, G7 (float division, `int.to_float`) | **fixed** (the sender sends `to_float` and its own guard; the unit compiles) |
| X11 (no `@spec`) | **decided**: the sender's gap, with its reason (contract T8.10 a) |
| X5, G12 (`<>`, case on a call or a Bool) | **fixed** |
| E11, X15, G15 (release) | **fixed** in the senders |
| X13 (alias pattern) | sent by the senders; **open** in the sink |
| E4, E5, E7, E9, X7, X9, X10, X14, G1 to G3, G9, G10 (processes) | **open** (sink: process nodes; contract: P1, P4, P8, P9) |
| E6, X8, E8, X12, G13 | **open**, contract (P1, P2) |
| E10, G10 (entry) | **open** (names: `main`) |
| G4, G8 (`dynamic`, type variables) | **open** |
| G11 (`failed` with a file) | **fixed** (C17) |

## The first run (2026-11-13, early)

| Application | Run with | Prints |
| --- | --- | --- |
| `erlang-to-silica-poc/examples/actors.erl` | `erlc -o /tmp examples/actors.erl && erl -noshell -pa /tmp -s actors main -s init stop` | `{first,12,2,6.000000e+00,large}` `{second,4,1,small}` `{restarts,1}` `{same_child,false,supervisor_alive,false}` |
| `elixir-to-silica-poc/examples/actors.ex` | `elixir -r examples/actors.ex -e "Actors.main()"` | `{:refused, -30}` `{:withdrawn, 30}` `ada: low` `{:first, 40, 13.333333333333334, :low}` `ada: empty` `{:second, 0, false}` `{:restarts, 1}` |
| `gleam-to-silica-poc/examples/actors.gleam` | `gleam run -m actors` | `first: total 12, adds 2, large` `mean 6.0` (one OTP supervisor report on standard error, the crash is deliberate) `second: total 4, adds 1, small` `auditor: notes 4, sum 13` `the supervisor restarted the counter` |

## What was run, and against what

- **The transpiler.** Two builds, both on Apple Silicon with compiler 999919:
  - *new*: a copy of `silica-sink/` and `contract/` taken at 04:23 on 2026-11-13 and built with that copy's own
    `build.sh` in a scratch directory (the repository's `silica-sink/` was being reworked by someone else at the
    time and was not touched). **All results below are from this build** unless a row says otherwise.
  - *old*: the binary of 2026-11-12 23:17 (scratch build `b11`), with only its port changed. Used first; the
    Erlang application gave the same diagnostics and the same output on both.
- **Per application**: run in its language (output above); `--dump`; check mode; transpile mode; export; compile.

| Application | Check mode | Transpile mode | Exported unit, compiled |
| --- | --- | --- | --- |
| Erlang | `ok`, 15 frames, 1 gap, 0 rejected | `partial`, 10 gaps, 1 file | compiles; it holds 1 function of 9 (`describe/1`) |
| Elixir | `ok`, 19 frames, 1 gap, 0 rejected | `partial`, 13 gaps, 1 file | **does not compile** (E2003); it holds 2 functions of 13 |
| Gleam | `ok`, 25 frames, 6 gaps, 0 rejected | `failed`, 21 gaps, 1 file | compiles; it holds no function at all (0 of 15) |

- **No frame of any application was rejected**, in either mode. Every gap on the transpiler side is in the
  printer, the result, the diagnostics, or the process's life, not in validation.
- Because the printer stops at the first thing it cannot print and makes the whole function a gap, the
  applications alone do not show *which* construct stopped it. To find out, three scratch probe units (one function
  per construct, each with a signature the printer accepts) were sent the same way and each printed function was
  compiled on its own. Rows whose evidence says "probe" come from these; the probes are not in the repository.
- **Not run**: nothing was linked or executed as a Silica program (no unit got far enough to have a `main`); nothing
  on Linux; the repository's `silica-sink/` as it stands now (it may have changed since the copy); the sinks' own
  trials.
- The senders' tests pass with the applications added: Erlang `test/run_test.sh 7438` 18 of 18, Elixir
  `TO_SILICA_PORT=7438 mix test` 26 passed, Gleam `test/run_test.sh 7438` 21 passed.

Severity: **high** stops an application from being transpiled or stops the transpiler; **medium** gives wrong or
unusable output for a common construct; **low** is a wrong detail or an unhelpful message.

## Common to all three languages (transpiler side)

These were met with every application; the language tables refer to them by id.

| Id | Construct | What happened | Side | Evidence | Severity |
| --- | --- | --- | --- | --- | --- |
| C1 | `(:release, …)` (M7) | **The transpiler process ends with a memory fault** on a release connection. New build: in a fresh transpiler the 9th release is the one that ends it (4 runs of 4, one with a client that waits for the close), and after two transpile sessions it was the 2nd. Old build: less regular, the 1st release of a fresh transpiler (twice), the 7th, and one straight after a `busy` refusal. The sender sees the connection closed with no `(:released, …)`; the next connect is refused. Check sessions (25 in a row) and `busy` refusals (12 in a row) do not do it | sink | standard error: `[silica] fault at 0x…904 in silica_rt_message_copy+0x774 addr=0x0000000000000000`; nothing on standard output; exit without a message | high |
| C2 | process nodes: `self`, `spawn`, `send`, `receive`, `link`, `exit_signal`, `fail` (H20 to H26) | None is printed. A function that holds one becomes a gap, so no actor of any application is transpiled | sink | probe: `p_self`, `p_spawn`, `p_spawn_link`, `p_send`, `p_receive`, `p_receive_after`, `p_link`, `p_exit_signal`, `p_fail` each `… is a gap: it uses a construct outside the minimal printer, or its last clause does not match everything` | high |
| C3 | `(:match, …)` and `(:block, …)` (H18, H19): a local variable | Not printed: `M = N + 1, M * 2` makes the function a gap. Every application function with a `let`/`=` is lost for this reason alone | sink | probe `p_match/1`, Gleam probe `p_let/1`: same T4001 text as C2 | high |
| C4 | `(:type, …)` forms; `(:record, …)`, `(:field, …)` (H12, H13); `t_named` in a signature | A type form is a gap (`type declarations are not printed yet`); a signature naming the type is refused; a body that builds or reads a record is a gap. The state of every actor is a record | sink | `tally is a gap: type declarations are not printed yet`; `bump/2 is a gap: its name or a type of its signature is outside the minimal printer`; probe `p_record/1` | high |
| C5 | signature types `t_actor`, `t_union`, `t_tagged`, `(:t_basic, :dynamic)`, `(:t_basic, :bytes)` | A function whose hint holds one is a gap. `pid()` is `t_actor`, a message type is a `t_union` of `t_tagged`, Gleam's `Subject` and Erlang's `binary()` are `dynamic` and `bytes` | sink | `ask/1` (`pid()`), `main/0` (`{restarts, integer()} \| timeout`), probe `p_tagged_in/1`, `p_text/1` (`binary()`): `its name or a type of its signature is outside the minimal printer` | high |
| C6 | a function with no hint | A gap: `it has no type hint on its signature (the untyped representation is not built)`. The contract makes hints optional in a `:bees` session (T8.1) | sink | Elixir `await_withdrawal/0`; Gleam probe `p_unannotated/1` | high |
| C7 | `(:entry, …)` | A gap: no `main` is written, so no application can be linked or run (T9.6) | sink | `entry main is a gap: the entry point (main) is not printed yet` | high |
| C8 | a gap function is left out, its callers are not | A function that is a gap is written as a comment (contract T9.10 says a failing stub). A printed function that calls it then names a function that does not exist, and the unit does not compile | sink | probe: `fn p_pipe(p0: int64) -> int64 { p_cond(p_if(p0)) }` with `p_cond` a gap: compiler `E2007 unknown function: p_cond` | high |
| C9 | `/` (Appendix B: float division) on integers; arithmetic on a float and an integer | Printed as written, `(p0 / p1)` with `int64` operands and a `float64` result, `(p0 * p1)` with a `float64` and an `int64`. Silica refuses both. No conversion is inserted and the form is not made a gap | sink | Elixir application, `mean_move/2`: `E2003 type mismatch: p0`, `ex_actors.silica` line 20; probe `p_float_div/2`, `p_mixed/2` (STATUS.md names the second case) | medium |
| C10 | patterns: a tuple in a clause head; `case` on anything but a variable | Gaps. `case f(x) of`, `case {A, B} of`, Gleam's `case n < 10 { True -> … False -> … }` (Gleam's only conditional) and a clause head `{A, B}` are all refused | sink | probe `p_tuple_in/1`, `p_case_call/1`, `p_case_tuple/1`, Gleam probe `p_case_bool/1` | high |
| C11 | a function, `case` or `cond` whose last clause does not match everything | A gap. The contract says the transpiler adds the failing catch-all (H28, BEES A5.3) | sink | probe `p_nonexhaustive/1`, Elixir probe `p_cond/1`, `p_case_open/1` | medium |
| C12 | calls: `(:lambda)`, `(:apply)`, `(:fun_ref)`, a `(:call)` with a module | Gaps. A call to another module (`erlang:abs/1`, `IO.puts/1`, `gleam/int.to_float`) has no meaning in the contract either (T9.9 has no foreign call; the Gleam README lists this as open) | sink, contract | probe `p_lambda/1`, `p_fun_ref/1`, `p_remote/1`; Gleam probe `p_to_float/1` | high |
| C13 | `<>` (Appendix B) on text | A gap | sink | Elixir application `label/2`; Elixir probe `p_concat/2`; Gleam probe `p_concat/1` | medium |
| C14 | diagnostics have no place | Every diagnostic has `file` empty, `line` 0, `column` 0, although the form's head has the file and the node table has a location for every node. The senders print `(:0)` | sink | `#{seq => 2, unit_name => <<"probe">>, place => #{line => 0, file => <<>>, column => 0}, …}` for a form with `file => <<"probe.erl">>` and `locations => [{94,12}, …]` | medium |
| C15 | diagnostics do not say what was refused | Two texts cover almost everything: `its name or a type of its signature is outside the minimal printer` (the name, or which type?) and `it uses a construct outside the minimal printer, or its last clause does not match everything` (which construct, which node, or is it the last clause?). Finding the cause of one function needed a probe per construct | sink | every T4001 above | medium |
| C16 | a sender's own `(:gap_node, …)` | Its `construct` and `note` are lost: the function is reported with the generic text of C15, the sender's reason (`erlang:process_flag/2`, `outside the proof of concept`) is in no diagnostic and not in the output's comment | sink | probe `p_gap_node/1`: frame holds `{gap_node,1,<<"erlang:process_flag/2">>,…}`, diagnostic is the C15 text | low |
| C17 | `Result.status` and `files` | A session in which no form was printed ends `failed` with `files` 1 (the file holds only comments). T6.8: `failed` is "nothing was written" | sink | Gleam application: `result: failed (units 1, gaps 21, rejected 0, files 1)` | low |
| C18 | `Result.counts.gaps` means two things | Check mode counts the gaps the sender sent (1); transpile mode counts the forms the printer could not print (10) and does not count the sender's gap node separately. A sender cannot compare the two | sink, contract | Erlang application: check `gaps 1`, transpile `gaps 10` | low |
| C19 | session ids | `s1`, `s2`, … start again when the transpiler starts. A debug log that spans a restart holds two sessions `s2`, and `export_debug_output.py` then writes both sessions' files into one directory | sink, tool | the Gleam export also wrote `erl_actors.silica` from an earlier run's `s2` until the log was cut at the last `listening` line | low |
| C20 | float text with an exponent (H2 names `1.0e-3`) | A gap | sink | Elixir probe `f_exp/1`: node `{:float, 2, "1.0e10"}`, T4001 with the C15 text; `2.0` and `0.001` print | low |
| C21 | the largest and smallest `int64` literal | A gap | sink | probe `p_big/1`: `9223372036854775807 + -9223372036854775808` | low |
| C22 | a function named with a Silica keyword | Printed unescaped: `export case/1;` and `fn case(p0: int64) -> int64`. Not valid Silica | sink | probe `'case'/1`; compiled alone: `E4016 module must define main/0, export at least one function, or export a trait` | low |
| C23 | a text literal with a tab | A gap (not narrowed further: the literal also held `\"`, `\n`, `\\` and `é`, each of which prints alone) | sink | Elixir probe `p_text_lit/1` | low |
| C24 | the transpiler says nothing when it ends | When the process ends (C1) there is no line on standard output and no last frame to the sender; the only trace is the runtime's fault line on standard error | sink | C1 | low |

What the printer did print, and the compiler accepted (probe functions compiled one by one): integer arithmetic
with `div` and `rem` (as `/` and `%`), unary minus (as `0 - x`), comparisons and `=:=`, `=/=`, `/=`, `and`/`or`/`not`
for `andalso`/`orelse`/`not`, a tuple result, atom and text literals and equality, clause heads with literals,
variables and `_`, guards with `,` and `;`, `cond`/`if` ending in `true`, `case` on a variable, a pipe of local
calls, Gleam's `Nil` as the atom `:Nil`. Not checked: whether Silica's `and`/`or` skip their right operand as
`andalso`/`orelse` do, and what Silica's `/` and `%` give for a zero divisor (Gleam defines 0).

## Erlang: `erlang-to-silica-poc/examples/actors.erl`

No change to the sender's mapping was needed. Sent: 1 type form, 9 functions (each with a `-spec`, so a `declared`
hint), 1 entry.

| Id | Construct / source line | What happened | Side | Evidence | Severity |
| --- | --- | --- | --- | --- | --- |
| E1 | `-record(tally, …)`, line 13 | gap, C4 | sink | `tally is a gap: type declarations are not printed yet` | high |
| E2 | `new_tally/0`, `bump/2`, `average/1`, lines 18 to 27 (`#tally{}` in the spec, record build, update, field, pattern) | gaps, C4 | sink | `… its name or a type of its signature is outside the minimal printer` | high |
| E3 | `describe/1`, line 30 | **printed and compiles**: `fn describe(p0: int64) -> atom { case (p0 < 0) of { true -> :negative; false -> case (p0 < 10) of { true -> :small; false -> :large } } }`. The result type `small \| large \| negative` (a `t_symbols`) is widened to `atom` | sink | exported `erl_actors.silica`; compiler exit 0 | low |
| E4 | `counter/1`, line 39: `receive` with five clauses, guard, send, record | gap. First refused at the signature (`#tally{}`, C4); the body would be refused for C2 | sink | T4001, signature text | high |
| E5 | `supervisor/2`, line 53: `spawn_link(fun …)`, `receive {'EXIT', Child, normal}` | gap. Signature (`pid()`, C5), then C2 | sink | T4001, signature text | high |
| E6 | `process_flag(trap_exit, true)`, line 54 | The sender sends a gap node: the contract has no node for trapping exits, so a supervisor written by hand cannot be expressed. The `{'EXIT', …}` clauses travel as ordinary receive clauses whose messages nothing will ever send | sender, contract | `{gap_node, _, <<"erlang:process_flag/2">>, <<"outside the proof of concept">>}`; reported by the sink only as C16 | medium |
| E7 | `main/0`, line 65: `spawn(actors, supervisor, [self(), 0])`, sends, tuple match, `receive … after` | gap. Signature (`{restarts, integer()} \| timeout`, a `t_union` of a `t_tagged` and a `t_symbols`, C5), then C2, C3 | sink | T4001, signature text | high |
| E8 | `erlang:display/1`, `is_process_alive/1`, lines 72 to 84 | Sent as `(:call, …, "erlang", …)`. Check mode accepts them; nothing in the contract says what a call to a module outside the session means (C12). The application prints with `erlang:display/1` because `io:format/2` needs a string and a list, which the sender sends as gaps | sender, contract | `--dump`: `{call,_,<<"erlang">>,<<"display">>,[_]}` | medium |
| E9 | `await_child/0`, `ask/1`, lines 88 and 95: `receive … after 1000 -> exit(…)` | gaps. Signature (`pid()`, C5), then C2 | sink | T4001, signature text | high |
| E10 | the entry, `main/0` | gap, C7 | sink | `entry main is a gap: the entry point (main) is not printed yet` | high |
| E11 | releasing the session to send again | the sender has no way to send `(:release, …)`; without it a second transpile session is refused `busy`. A scratch script was used, and met C1 | sender | `refused: busy (the storage region is in use by another transpile session; …)` | medium |
| E12 | one transpile session (old build) | `the transpiler closed the connection without a result`: the transpiler had ended. Not reproduced with the same frames on a fresh transpiler; it came one session after a release, so it is most likely C1 | sink | sender output; the process was gone | high |

## Elixir: `elixir-to-silica-poc/examples/actors.ex`

No change to the sender's mapping was needed. Sent: 1 type form (`Actors.Account`), 13 functions (12 with a
`@spec`), 1 entry.

| Id | Construct / source line | What happened | Side | Evidence | Severity |
| --- | --- | --- | --- | --- | --- |
| X1 | `defstruct`, line 15 | gap, C4 | sink | `Actors.Account is a gap: type declarations are not printed yet` | high |
| X2 | `open/1`, `deposit/2`, `withdraw/2`, lines 21 to 34 | gaps, C4 (`Account.t()` in the spec) | sink | T4001, signature text | high |
| X3 | `level/1`, line 37 (`cond`) | **printed and compiles** alone: `case (p0 <= 0) of { true -> :empty; false -> case (p0 < 50) of { true -> :low; false -> :healthy } }` | sink | exported `ex_actors.silica` | none |
| X4 | `mean_move/2`, line 47: `balance / moves` | **printed, and the unit does not compile**: `case (p1 == 0) of { true -> 0.0; false -> (p0 / p1) }` with `int64` parameters and a `float64` result, C9. This one function makes the whole exported unit useless | sink | `E2003 type mismatch: p0`, `ex_actors.silica` line 20 column 48 | medium |
| X5 | `label/2`, line 50: `case level(balance) do`, `owner <> ": empty"` | gap: C10 (case on a call) and C13 (`<>`) | sink | `label/2 is a gap: it uses a construct outside the minimal printer, or its last clause does not match everything` | medium |
| X6 | `twice/1`, line 59: `fn x -> x * 2 end`, `n \|> double.()` | gap: C3, C12 | sink | T4001, construct text | medium |
| X7 | `account/1`, line 67: `receive` with six clauses, a nested `case` on tagged tuples, sends | gap. Signature (`Account.t()`, C4), then C2 | sink | T4001, signature text | high |
| X8 | `Process.flag(:trap_exit, true)`, line 102 | as E6 | sender, contract | `{:gap_node, 2, "Process.flag/2", "outside the proof of concept"}` | medium |
| X9 | `supervisor/2`, line 101: `spawn_link(fn …)`, `{:EXIT, pid, :normal} when pid == child` | gap. Signature (`pid()`, C5), then C2. The guard is there because the pin operator (`^child`) is a gap in the sender (its README; not sent here) | sink; sender for the pin | T4001, signature text | high |
| X10 | `main/0`, line 115 | gap: signature (`t_union`, C5), then C2, C3 | sink | T4001, signature text | high |
| X11 | `await_withdrawal/0`, line 154 (no `@spec`) | gap, C6: the contract allows a function with no hint | sink | `await_withdrawal/0 is a gap: it has no type hint on its signature (the untyped representation is not built)` | high |
| X12 | `IO.inspect/1`, `IO.puts/1`, lines 122 to 142 | as E8: sent as calls to module `IO` | sender, contract | `--dump`: `{:call, _, "IO", "inspect", [_]}` | medium |
| X13 | an alias pattern in a clause head, `%Account{balance: b} = account` | The first version of `withdraw/2` used one; the sender sends a gap node (the contract has no node for it) and the clause is lost. The application was rewritten with a field access in the guard | sender, contract | `{:gap_node, 0, "alias pattern", "outside the proof of concept"}` (first version) | medium |
| X14 | `await_child/0`, `report/1`, the entry | gaps: C5, C2, C7 | sink | T4001 | high |
| X15 | release | as E11: `mix e2s` cannot release. The release sent from the scratch script to free the region for this application's transpile session ended the old-build transpiler (C1) | sender; sink | `{error, closed}` from the release, then `error: {:connect, :econnrefused}` from `mix e2s` | medium |

## Gleam: `gleam-to-silica-poc/examples/actors.gleam`

The sender's mapping was extended (inside `gleam-to-silica-poc/` only): `process.self`, `new_subject`, `spawn`,
`spawn_unlinked`, `send`, `receive` and `receive_forever` of `gleam/erlang/process` are now the contract's `self`,
`spawn`, `send` and `receive` nodes, with a subject lowered to the process that owns it (README, "Processes"). A
`receive` node was added to the sender's frames. Sent: 5 type forms, 15 functions (all with a `proven` hint), 1
entry; 6 gap nodes.

| Id | Construct / source line | What happened | Side | Evidence | Severity |
| --- | --- | --- | --- | --- | --- |
| G1 | **`gleam_otp` actor**: `actor.new_with_initialiser … \|> actor.on_message(handle) \|> actor.start`, line 119; `actor.continue`, `actor.stop_abnormal`, lines 101 to 110 | **The sender cannot represent a `gleam_otp` actor.** glance gives one module's syntax; the actor's receive loop is inside the library. Five gap nodes. The whole pipeline becomes one gap node, so the initialiser closure inside it (which holds a mappable `process.send`) is not sent at all | sender, contract (9.2 open) | `{gap_node,1,<<"gleam/otp/actor.start/1">>,<<"OTP actors and supervisors are outside the proof of concept (contract 9.2)">>}` is the whole body of `start_counter/1` | high |
| G2 | **`gleam_otp` supervisor**: `supervisor.new(supervisor.OneForOne) \|> supervisor.add(supervision.worker(…)) \|> supervisor.start`, line 133 | One gap node. The strategy and the child are not sent. The contract's only supervision is the session's A4.4 choice plus a linked spawn | sender, contract | `{gap_node,2,<<"gleam/otp/static_supervisor.start/1">>,…}` | high |
| G3 | `process.receive(subject, 1000)`, lines 145 to 214; `process.new_subject()` | **Mapped, but not exactly.** The receive takes any message of the process, not only the subject's; the coordinator holds `announce` and a reply subject at once, so the transpiled program could hand a `Report` to a receive that expects a counter. The contract has no tagged mailbox | sender, contract | `ask/1`: `{self,2}` for `new_subject()`, `{'receive',18,[13],14,17}` with the one clause `_message -> {Ok, _message}` | medium |
| G4 | `Subject(…)`, `actor.Next(…)`, `Result(a, Nil)` in signatures | Sent as `(:t_basic, :dynamic)` with strength `proven`: the sender has no type for a subject (`t_actor` needs a message type and names a process, not a subject) | sender, contract | `start_counter/1`: `types => [{t_basic,dynamic},{t_basic,dynamic},{t_fun,[0],1}]` | medium |
| G5 | the five `pub type`s, lines 23 to 50 | gaps, C4. `CounterMessage` and `AuditorMessage` are the actors' message types | sink | `Tally is a gap: type declarations are not printed yet` and four more | high |
| G6 | `new_tally/0`, `bump/2`, `describe/1`, `size_name/1`, lines 54 to 77 | gaps at the signature: `t_named` (C4), also for `Size`, which has no fields and is only three symbols | sink | T4001, signature text | high |
| G7 | `mean/2`, line 79: `case adds { 0 -> 0.0  _ -> int.to_float(total) /. int.to_float(adds) }` | gap: the call into `gleam/int` (C12). Its signature (`Int`, `Int`, `Float`) is accepted | sink, contract | `mean/2 is a gap: it uses a construct outside the minimal printer, or its last clause does not match everything` | medium |
| G8 | `expect/2`, line 87: `Result(a, Nil) -> a`, `panic as what` | gap at the signature (`dynamic`, `t_var`; C5); the body would stop at `fail` (C2) and the tuple patterns (C10) | sink | T4001, signature text | high |
| G9 | `handle/2`, `start_counter/1`, `start_supervisor/1`, `auditor_loop/3`, `start_auditor/0`, `add/3`, `ask/1`, `show/2` | gaps at the signature (`dynamic` or `t_named`, C5, C4); the bodies hold C2, C3, C10 | sink | T4001, signature text, eight times | high |
| G10 | `main/0`, line 197 | gap. Its signature (`-> Nil`) is accepted; the body is refused (C3 at its first `let`, then C2) | sink | `main/0 is a gap: it uses a construct outside the minimal printer, …` | high |
| G11 | the result | `failed`, with 1 file that holds 21 comments and no function (C17). The exit status of the sender is 1 | sink | `result: failed (units 1, gaps 21, rejected 0, files 1)` | medium |
| G12 | Gleam's `case` on a `Bool` or on several subjects | Not in the application's printed part, found by probe: `case n < 10 { True -> … False -> … }` is a gap (C10), and so is `let` (C3). With these two, almost no Gleam function body can be printed | sink | Gleam probe `p_case_bool/1`, `p_let/1` | high |
| G13 | `io.println`, `int.to_string`, `float.to_string` | as E8: calls to modules outside the session | sender, contract | `{call,_,<<"gleam/io">>,<<"println">>,[_]}` | medium |
| G14 | running the application | It needs `gleam_erlang` and `gleam_otp`, added as development dependencies of the sender's project, and a copy in `test/` to be compiled and run (`gleam run -m actors`) | sender | `gleam.toml`, `test/actors.gleam` | low |
| G15 | release | as E11: the Gleam command line cannot release | sender | | medium |

## Summary

- **Transpiler side, what stops an application**: no process node is printed (C2), no local variable (C3), no
  record or declared type (C4), no actor, union, tagged or dynamic type in a signature (C5), no function without a
  hint (C6), no entry point (C7). Of 37 functions in the three applications, 3 were printed. A gap function is
  dropped while its callers stay (C8), and float division on integers is printed as written (C9), so a unit can
  fail to compile; the Elixir application's does.
- **Transpiler side, the process itself**: a release connection ends the transpiler with a memory fault, on the new
  build the 9th in a fresh process and sooner after transpile sessions (C1). It is in Silica's runtime (`silica_rt_message_copy`)
  and is most likely a Silica defect that the transpiler's release path reaches, not a fault of its logic; it is
  reported here, not narrowed.
- **Transpiler side, diagnostics**: no place (C14), no construct named (C15), the sender's own gap reasons lost
  (C16).
- **Sender and contract side**: no node for trapping exits, so a hand-written supervisor is a linked spawn and
  nothing more (E6, X8); a call to a module outside the session has no meaning (E8, X12, G13); no sender can send a
  release (E11); Elixir's alias pattern and pin are gaps (X13, X9); the Gleam sender cannot represent a `gleam_otp`
  actor or supervisor (G1, G2), and its new mapping of `process.receive` loses the subject's selectivity (G3).

## Update 2026-11-14: Erlang `demo.erl`

`shout/1` (inter-node), `lookup/1` (`maps:is_key`, a call outside the session) and `untyped/1` with `uses_untyped/1`
(no `-spec`) were removed from `erlang-to-silica-poc/examples/demo.erl` at the user's direction. The rows above that
name them as Erlang examples are historical: `demo.erl` no longer holds a deliberate gap, and its sender test
now requires that it sends none. The Erlang sender suite passes offline (121 tests). The transpile and run figures
for `demo.erl` earlier in this file predate the removal. **Re-run later that day**, with the static supervisor
in place of `supervise/1`: the first section of this file.
