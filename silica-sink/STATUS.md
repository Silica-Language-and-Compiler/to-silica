# Transpiler status

What is built in `silica-sink/`, what was run and what it showed, what failed and why. Last update 2026-11-14,
last (the Elixir examples are transpiled with no gap: the sender's work, nothing of the sink changed; before it,
later that day: a supervisor with a static child list: contract T9.14b, printed as rows of the unit's supervisor's `init`;
the Erlang `demo.erl` has one and was run call by call. Earlier that day:
the Elixir and Gleam senders split their functions as the Erlang sender does; all four of their examples were
sent, compiled, linked and run again; nothing of the sink changed. 2026-11-13, late: the sender splits a function at a receive, the sink prints `(:sl_call)` of the print builtins, and
`actors.erl` runs as a program; night: every example converted, compiled, linked with a driver and run, call by
call against its own language; evening: the process nodes).

**The sink prints what it is told (decided 2026-11-13, late).** A source language's semantics (what runs before
and after a receive, what a waiting process keeps, links, output formatting) are lowered by that language's
sender before it sends, as its types are (contract §1 "What you own", §8.6, T9.13a, T9.16). The sink has one
shape for each thing it prints, and when it is sent another it answers with the construct, its place and what
the sender must send instead. It has no language-specific splitting and is not to get any.
The design is [silica_sink_design.md](silica_sink_design.md); the contract is
[../contract/tcp-transport-v1.md](../contract/tcp-transport-v1.md). Evidence for decisions is in
[DECISION_DATA_printer.md](DECISION_DATA_printer.md) (types: **decided 2026-11-13, the sender decides every type**,
its section 6; names: open) and [DECISION_DATA_unbuilt_p0.md](DECISION_DATA_unbuilt_p0.md) (open). The compiler is now
`silica-999916-macos-applesilicon`; what changed with it is in "Compiler 999916" below.

## Node declarations and compiler 999909 (2026-11-16)

The default compiler is now `silica-999909-macos-applesilicon` (BEES moved to it the same day); the sink builds with it in one run. New: the `(:node)` form (contract T9.17): `ts_check@node_check` (`:bad_node`), `ts_print@node_text` and `ts_actor_transpile@node_form`, which write `<unit>.wire` and `<unit>.bees.config` beside the unit. Silica limit met: a decoded record takes at most four fields, so the form is nested. Run: the three Erlang `examples/three_nodes` programs give `ok`, 0 gaps, 3 files each; BEES's `bees_config_beam.py generate` accepts the files; the printed units compile. The sink also writes `<unit>.atoms` for a node program (every atom literal of the unit; BEES A1.2). `tools/node_kit/build_node.sh` builds hub and edge_a with BEES and they ran against each other (see `tools/node_kit/README.md`). Not built: more than one link per node (BEES).

## What exists

| Piece | File | State |
| --- | --- | --- |
| Build | `build.sh <build-dir> [port]` | works; **one compiler run** by default since compiler 999916 (about six minutes); the four-run `TS_FAST=1` build was removed on 2026-11-17 (an application is one compilation unit); `TS_STORE=memory\|backing`, `TS_REGIONS`, `TS_SESSIONS`, `TS_CAPACITY`, `TS_TRIAL_FAULTS` |
| Type and pool spelling | `tools/expand.py` | writes the `*.silica` units from `src/*.silica.in`; fails if its types differ from the schema's; spells out the pools (regions, session actors) |
| Atom and shape prelude | `tools/prelude.py` | writes `ts_prelude.silica`, which names every atom and record shape in one order. Written to make four compiler runs agree; **still needed with one run** (limitation 1) |
| Configuration | `src/ts_config.silica` | port 7411, credit window 64, max frame 1 MiB, debug output on, 3 transpile attempts, trial hooks (empty) |
| Helpers | `src/ts_text.silica`, `ts_out.silica`, `ts_pool.silica.in` | text; output and exit; the pools' names and session ids |
| Replies R1..R9 | `src/ts_reply.silica.in` | welcome, refused, credit, stored, rejected, diagnostic (with place), result, released |
| Own records | `src/ts_records.silica.in` | the transpiler's records in a region (design §4.1) and their summary on replay |
| Checks | `src/ts_check.silica.in` | hello (T5.6, T7.1, T8.4), node and type tables (T9.2, T9.3), hints, profile (T7.10), gaps |
| Frame digest | `src/ts_intake.silica.in` | the one unit that takes a decoded frame apart; re-encodes it for storage; calls the printer |
| Session logic | `src/ts_session.silica.in` | a pure step function: check mode, transpile mode, credit that follows storage, counts (T5.3b), rebuilding on resume |
| Printer | `src/ts_print.silica.in` | PROVISIONAL (its header says exactly what it covers). **It follows contract §8.6: types come from the sender's hints only; it infers no type and converts no value.** Declared types across forms and units, lists, conversion operators, failing stubs; diagnostics with construct and place, T3101 to T3104 for missing or inconsistent typing. **Processes** (contract §9.4a, design §5.5): `self`, `spawn`, `send`, `receive` in tail position with guards and timeouts, `fail` with a reason, `exit_signal` with a symbol reason; record and alias patterns, `++`, reserved function names (`move__`, `main__`, contract T9.11); `unit_rest` writes what needs the whole unit (the message and phase types, the process runtime, `main`). **Low level (contract T9.16):** `(:sl_call)` of a Silica print builtin (`print`, `println`, `print_int64`, `print_float64`, `print_boolean`, `atom_name`), written as a call of a helper `to_silica_b_<name>` that declares `device_io`; nothing else of §9.5. A receive that is not in tail position is answered with "the sender must split the function at this receive (contract T9.13a)" |
| Process runtime | `src/process_runtime.silica.tmpl`, `src/process_main.silica.tmpl` | the Silica written at the end of every unit that has processes: the one actor behaviour, the dispatch over phases, the supervisor (its `init` lists the unit's static children, contract T9.14b), the spawner (owner of the child ids), the report sink; and `main` for an entry point. `tools/expand.py` turns them into string literals of the printer |
| Session actors | `src/dangerous_ts_session.silica.in` | a supervised pool, one connection each |
| Region ports | `src/dangerous_ts_port.silica.in` | one per region: owns the `(:store)` carrier |
| Store owners | `src/ts_region.silica.in`, `ts_actor_store.silica.in` | one per region: lease, storing, sync, replay, recovery, resume, release |
| Transpile actors | `src/ts_actor_transpile.silica.in` | one per region; keeps the session's declared types (`(:type)` forms) and hands them to the printer with each form |
| Root | `src/dangerous_to_silica.silica.in` | listener owner, root supervisor, warden (report sink), reporter, main, orderly end |
| Goldens | `../contract/goldens/` | 23 sessions as `.frames` and `.expect`, generator and player (`ok_types_stated` is new) |
| Trials | `trials/run_trials.sh <work-dir> <port> [all]` | builds, then `p0_check_mode` (20 cases), goldens (23), `p2_actors` (23 cases), `p1_export`, `p3_types` (32 cases, then the generated unit compiled, linked and run), `p4_processes` (36 cases, then two generated units compiled, linked and run: processes and a program with an entry point); with `all` `p2_actors` again on a `(:backing)` store, kill and restart, orderly end |
| Debug exporter | `../tools/export_debug_output.py` | PROVISIONAL: cuts output files out of the transpiler's debug output |

### The actors as built (design §3)

```
main ── reporter (FailureReporter), warden (the supervisors' report sink); neither can be supervised
 └─ :ts_root, one_for_one
     ├─ :ts_port_sup       :ts_port_<r>       owns region r's store carrier; carries commands and events
     ├─ :ts_store_sup      :ts_store_<r>      store owner of region r; leased to one session at a time
     ├─ :ts_transpile_sup  :ts_transpile_<r>  transpile actor of region r, idle between sessions
     ├─ :ts_session_sup    :ts_session_<i>    pool of session actors (default 8), idle between connections
     └─ :ts_listener_sup   :ts_listener       owns the (:tcp) listener
```

- Every child is static, `:permanent`, and addressed by its child id (a registered name), so a restart leaves no
  stale reference. The warden sends a restarted child `(:boot, 0)` (a restarted actor is otherwise passive).
- **Session actor fails:** restarted; it tells every store owner `(:detach, slot)`; the session stays in its region
  and can be resumed. Its connection is orphaned: it stays open, unanswered, until the sender closes it.
- **Transpile actor fails:** restarted; the owner stops the replay and starts a new attempt from the session's first
  record, with a new `(:output_begin, { attempt })` record; after 3 attempts the session ends `failed` (T5002).
- **Store owner fails:** restarted; its port closes the carrier (drain, flush) and opens a new one; the owner
  recovers the region by replay. On a `(:memory)` region the session is lost; on `(:backing)` it is found again.
  Not tried by a trial (no hook makes an owner fail).
- **Port or listener fails, or a child supervisor passes its restart limit:** the transpiler exits (status 1 or 70);
  the next start recovers `(:backing)` regions. Not tried by a trial.
- **Pool of regions:** a new session asks owner 0, a busy owner passes the request on; when all hold a session the
  hello is refused `busy`. A resume or a release goes to the owner the session id names (`intake_1:42`).
- **Pool of session actors:** the listener hands a connection to actor `n mod pool`; a busy one passes it on; a
  connection no actor can take is closed.

## What was run, and what it showed (2026-11-14, last, Apple Silicon, compiler 999916): the Elixir examples have no gap

**Nothing of the sink was changed in this step, and no contract rule was added** (the contract got an "as
built" note under H36 and names Elixir beside Erlang in T9.14b). The Elixir sender now reads Elixir's
`Supervisor` and sends its children as static children, as the Erlang sender does for OTP's (T9.14b, T9.14c),
and sends a `fn` that captures nothing as a function of the module; its example `demo.ex` lost its deliberate
gaps. The sink printed what it was told with the build of the step below (`build.sh`, default build; its
sources are unchanged since, so it was not built again and the trial suite was not run again).
`SENDER_GAPS_STATUS.md`, "the Elixir examples have no gap", has the decision for each gap.

### What the Elixir sender sends now, and what the sink prints of it

| Elixir | Sent as | Printed as |
| --- | --- | --- |
| `{:ok, _sup} = Supervisor.start_link(__MODULE__, [], name: Demo.Sup)`, with `init/1` (`children = [%{id: :tally, start: {__MODULE__, :start_tally, [0]}, restart: :transient}]`, `Supervisor.init(children, strategy: :one_for_one, …)`) and `start_tally/1` (`spawn_link(__MODULE__, :counter, [start])`, `Process.register(pid, :tally)`) | `(:register, "tally", (:spawn, (:fun_ref "Demo" "counter" 1), [(:int 0)], false))`, override `a4_4 chosen restart=transient strategy=one_for_one` on the `(:spawn)`; `init/1` and `start_tally/1` are not sent | the row `{ id: :tally, …, initial_state: { ph: (:to_silica_s_counter_1, 0), … }, restart: :transient, … }` of the unit's supervisor's `init`; `to_silica_static(:tally)` where the start stood |
| `send(:tally, {:add, n})` | `(:send_named, "tally", (:tuple …))` | `to_silica_send_named(:tally, (:add, p0))` |
| `twice(fn x -> add(x, 5) end, n)` | `(:call "twice" [(:fun_ref "" "add_ten__f1" 1), n])` and the function `add_ten__f1/1`, not exported, typed `(integer() -> integer())` from `twice/2`'s `@spec` | `twice(add_ten__f1, p0)` and `fn add_ten__f1(p0: int64) -> int64` |

### The two examples, run

Each was sent in transpile mode, exported, compiled with 999916 behind a prelude unit, linked with a driver
that calls every exported function and runs the processes (scratch `exzero/drv/ex_demo.body`,
`ex_actors.body`), and run; the same calls were run with `elixir` against the real modules (scratch
`exzero/native/ex_demo_calls.exs`, `ex_actors_calls.exs`) and compared line by line, floats as numbers (scratch
`exzero/compare2.py`).

| Program | Frames | Result | `counts.gaps` | Diagnostics | Calls | Match | Mismatch | Fail in both | Stub |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `demo.ex` | 35 | `ok` | 0 | 1 `T2001` | 55 | 53 | 0 | 2 | 0 |
| `actors.ex` | 28 | `ok` | 0 | 1 `T2001`, 4 `T4004` | 35 | 35 | 0 | 0 | 0 |

`demo.ex`: the 41 calls that matched before still match; newly matching are `add_ten(1)` `11`, the three
`area` calls (`9.0`, `10.0`, and `3.14159`, which Silica prints as `3.141589999999999`: below), `max_of(3, 9)` and `max_of(9, 3)`, and the supervised child:

| Call | Elixir | Silica | Match |
| --- | --- | --- | --- |
| `start_sup()` | `ok` | `ok` | yes |
| `tally_add(3)`, `tally_add(4)` | `ok`, `ok` | `ok`, `ok` | yes |
| `tally_total()`, run as a process | `7` | `7` | yes |
| the driver's own `send(:tally, {:get, self()})`: received `{:total, n}` | `7` | `7` | yes |
| `tally_stop()` | `ok` | `ok` | yes |
| `tally_total()` after the stop | the calling process ends: `ArgumentError` (`:badarg`) | the calling process ends: `(:explicit, :actor_not_found)` | fails in both |
| `ratio(7, 0)` | `ArithmeticError` (`:badarith`) | `:language_error`, the stub's failure of the sender's own guard | fails in both |

`actors.ex`: the 34 calls that matched still match, and the float `13.333333333333334`, which Silica prints as
`13.333333333333333`, is the same number to the 15 decimal places Silica prints (it was the one mismatch: the
comparison was of texts). `Actors.main/0`
run as the unit's own program prints Elixir's five lines (line 4 with that float) and ends with status 0.

Counted apart, by design (contract T9.13: a function with a receive runs only as a process): the drivers'
ordinary calls of `counter(10)` (`demo.ex`) and of `supervisor/1`, `withdraw_from/2`, `report/1`, `account/1`
and `main/0` (`actors.ex`) fail in Silica when they are reached; run as processes the same functions match.

A scratch copy of `demo.ex` whose counter has a `:crash -> exit(:boom)` clause, with a driver of its own: 7,
then 0 after the crash (the child is started again under its name; Elixir: a new pid, registered again), then 5
after `tally_add(5)`, in Elixir and in Silica (the failure report says `(:explicit, :boom)`). A second
`start_sup()` there answers `ok` in Silica and does nothing (the total stays 5); in Elixir it raises a
`MatchError` (`{:error, {:already_started, pid}}`) and the total stays 5 too.

The fixtures, sent in transpile mode: `test/fixtures/split_shapes.ex` 118 frames, `partial`, 1 gap (the `T4002`
note on the unit for functions only processes run, P15; 33 `T4004`), its `main` as a program prints Elixir's 16
lines; `test/fixtures/gaps.ex` (what left `demo.ex`) 15 frames, `partial`, 8 gaps (5 `T4001`, 3 `T4002`), as the
old `demo.ex`.

### Limitations observed in this step (compiler 999916; nothing reported or changed in Silica)

- **No shortest round-trip text of a float.** No builtin gives a float's text or takes a precision.
  `print_float64` writes the whole part and **at most 15 decimal places, cut, not rounded** (it stops earlier
  when nothing is left): `40.0 / 3.0` is written `13.333333333333333` (Elixir: `13.333333333333334`), `3.14159` is
  written `3.141589999999999`, `2.0 / 3.0` `0.666666666666666`, `0.1 + 0.2` `0.300000000000000`; `0.1`, `0.3`,
  `3.5`, `5.0` are written as Elixir writes them; a whole part beyond the 64-bit range is written as
  `9223372036854775807` (`1.0e22`). (Measured in this step with a ten-line program; the documents said "16
  significant digits" until then, and every place that did was corrected on 2026-11-14.) A sender has nothing else to send for `IO.inspect(float)`. (Whether the
  sink should write its own, over `float64_bits`, is open: it would be a library function of the runtime
  template, not language logic.)

### What was run, and what was only written

**Run:** the table above with the default build; the crash copy and the second start; the Elixir sender's
tests (96 tests offline, 0 failed, the 2 online ones skipped; 98 with `TO_SILICA_PORT`, 0 failed: check-mode sessions of `demo.ex` (0 gaps) and of the fixture `gaps.ex` (6 gaps), and of `actors.ex`, the check-mode sessions against the same build). **Not run again:**
the sink's trial suite and the Erlang and Gleam senders' suites (no source of the sink, the contract's schema,
its bindings or those senders changed). **Written, not run:** `permanent` and `temporary` static children,
`{Module, arg}` children and two children of one supervisor in a program (the sender's tests hold what is sent
for them); a message to the name before the start is reached; the restart limit.

## What was run, and what it showed (2026-11-14, later, Apple Silicon, compiler 999916): a static supervisor

User direction: the hand-written supervisor of the Erlang `demo.erl` (`supervise/1`: it trapped exits and linked
its child, and no driver could reach that child, so it was never run) is replaced by a supervisor **whose child
list is fixed when it starts**: OTP's `supervisor` behaviour, with the counter as its one child, registered as
`tally`. The contract got two numbered rules over nodes its schema already had (**T9.14b** a static child,
**T9.14c** a send to a name; **no schema change**: the schema unit and `contract/bindings/erlang` are as they
were), the sink prints them, the Erlang sender reads the supervisor and sends them. The decision and what was
considered instead: `../SENDER_GAPS_STATUS.md`, "a static supervisor". Nothing was changed in `../silica` or
`../project-bees`; nothing was committed.

### What the sender sends, and what the sink prints of it

| Erlang (`examples/demo.erl`) | Sent (by `e2s_sup` and `e2s_codex`) | Printed |
| --- | --- | --- |
| `{ok, _Sup} = supervisor:start_link({local, demo_sup}, ?MODULE, [])` in `start_sup/0`, with `init/1` (one child: `#{id => tally, start => {demo, start_tally, [0]}, restart => transient}`, flags `one_for_one`) and `start_tally/1` (`spawn_link(demo, counter, [Start])`, `register(tally, Pid)`, `{ok, Pid}`) | `(:register, "tally", (:spawn, (:fun_ref "demo" "counter" 1), [(:int 0)], false))` with the override `a4_4 chosen restart=transient strategy=one_for_one` on the `(:spawn)`; `init/1` and `start_tally/1` are not sent | a row of the list the unit's supervisor's `init` answers: `{ id: :tally, …, initial_state: { ph: (:to_silica_s_counter_1, 0), … }, behavior: to_silica_actor, restart: :transient, … }`; in `start_sup()`, `to_silica_static(:tally)` (the child is cast its start message by its name) |
| `tally ! {add, N}`, `tally ! {get, self()}`, `tally ! stop` | `(:send_named, "tally", message)` | `to_silica_send_named(:tally, message)`: `cast_registered` |

The sink reads nothing of Erlang or OTP: it prints a `(:register)` of a `(:spawn)` with literal arguments
(design §5.5). The session's own `a4_4` (the sender's `transient` for ordinary spawns) was not changed; the static
child's restart is its override's.

### The Erlang `demo.erl`, run

Built with the default build (`silica-sink/build.sh`, one compiler run). `demo.erl` was sent in transpile mode
(34 frames; result `ok`, 0 gaps, 0 rejected, 1 file; one `T2001` for the choices `a3_4` and `a3_2`, as before),
exported, compiled with 999916 behind a prelude unit, linked with a driver that calls every exported function
and runs the processes (scratch `statsup/drv/demo_driver.silica.in`), and run; the same calls were run in
Erlang against the module compiled by `erlc` (scratch `statsup/drv/demo_calls.erl`).

**43 calls compared: 43 match, 0 mismatch, 0 stubs.** 37 are the functions and processes of the earlier runs
(all match, as before; `lookup/1`, `untyped/1`, `uses_untyped/1` and `supervise/1` are no longer in the module).
The supervised child:

| Call | Erlang | Silica | Match |
| --- | --- | --- | --- |
| `start_sup()` | `ok` | `ok` | yes |
| `tally_add(3)` | `ok` | `ok` | yes |
| `tally_add(4)` | `ok` | `ok` | yes |
| `tally_total()` (as a process: it receives the child's answer) | `7` | `7` | yes |
| the driver itself: `tally ! {get, self()}`, received `{total, N}` | `7` | `7` | yes |
| `tally_stop()` | `ok` | `ok` | yes |
| then (250 ms later) `tally_total()` again: the child has ended normally, it is `transient`, nobody has the name | the calling process ends: `badarg` | the calling process ends: `(:explicit, :actor_not_found)` | the same thing happens; the reason's name differs (not in the 43) |

**A child that fails** (not in `demo.erl`, which has no edge cases: a scratch copy with one more clause in
`counter/1`, `crash -> exit(boom)`, and `tally_crash/0`; scratch `statsup/crash/demo.erl`,
`statsup/drv/crash_driver.silica.in`):

| Step | Erlang | Silica |
| --- | --- | --- |
| `start_sup()`, `tally_add(3)`, `tally_add(4)`, `tally_total()` | `7` | `7` |
| `tally_crash()`; 300 ms; `tally_total()` | `0`: the supervisor has started the child again (a new pid; `start_tally/1` registered it again) | `0`: the unit's supervisor has started the static child again, from its first state, and the name is the new child's. The failure report names the reason: `(:explicit, :boom)` |
| `tally_add(5)`, `tally_total()` | `5` | `5` |

### What differs from Erlang (each is in the sender's README, "A static supervisor")

- **The children exist from the program's start**, not from `supervisor:start_link`: the unit's supervisor
  starts with its list in `main` or `to_silica_start()`. A child has not run before `start_sup/0` is reached,
  but a message to its name before that starts it. A second `start_sup()` does nothing; in Erlang it fails.
  (Not run: neither is in the example.)
- **The source's supervisor is no process**: `demo_sup` is not a name of the output, and there is nothing to
  stop or to ask for its children. Its child is a child of the unit's one supervisor, beside the processes the
  module spawns.
- **Strategy and intensity.** The unit has one supervisor and one strategy, the session's (`one_for_one`); an
  override that states another is named in the unit's `T2001` (trial `p4_processes`, `keep2/0`). `intensity`
  and `period` are not carried: the unit's supervisor allows 100 restarts in 10 seconds (3 in 10 in the source).
- **A restarted child runs to its first receive when its next message arrives.** `counter/1` begins with its
  receive, so nothing shows.
- **A process that fails and was spawned by an ordinary `(:spawn)`** (the second `tally_total()` above) is
  started again under the session's `a4_4 transient`, as before; Erlang does not do that. Unchanged, and the
  sender's choice (APP_GAPS.md, open decisions).

### What was changed for it

- `src/ts_print.silica.in`: `register_ex` (a static child: the marker line `static`, `to_silica_static`),
  `send_named_ex` and a name in `send_ex`, `override_a4_4` and `param_of` (the printer's context now carries the
  form's overrides: `tools/expand.py`, `CTX`), `all_literals`, `static_rows`, `static_ids`, the header.
- `src/process_runtime.silica.tmpl`: `to_silica_send_named`, `to_silica_static`, the rows of `init`
  (`@STATIC@`), `to_silica_is_static` (`@STATIC_IDS@`): the warden leaves the row of a static child.
- `trials/p4_processes`: `keep/0` (a static child of `echo/0`, transient), `keep2/0` (one with a literal
  argument, never reached, whose override states `one_for_all`), `tell_keeper/1` and `blow_keeper/0` (sends to
  the name, a tuple and a symbol), `name/1` and `keep3/1` (a `(:register)` of a running process, a static child
  with a computed argument: `T4002` at their place). The caller reaches `keep()`, gets `{said, 6}` from the
  name, has the child fail with `kaboom`, and gets `{said, 9}` from the name again (the restarted child).
- The contract, the design (§5.5), the Erlang sender (`src/e2s_sup.erl`, `e2s_codex`, `examples/demo.erl`,
  tests, README), `HOWTO_language_creators.md`.

### Limitations observed in this step

- Silica gives a supervised actor its name when it is added (its child id): a process that is already running
  cannot be given a name, so a `(:register)` of anything but a `(:spawn)` is not written.
- One `impl <unit> for Supervisor` for a unit: a source supervisor cannot be a supervisor of its own in the
  same unit (design §5.5).
- A `cast_registered` to a name nobody holds ends the caster with `(:explicit, :actor_not_found)` (measured
  above), as a `cast` to an ended actor does.

### What was run, and what was only written

**Run:** the sink's trial suite once, `silica-sink/trials/run_trials.sh <work> 7495 all` (default build, memory and backing store): all trials passed, 172 `ok` lines, 0 `FAIL` (p0 20 cases, 23 goldens, p2 on both stores, p1, p3, p4 with the static children, the restart after `kill -9`, the orderly end); the Erlang sender's tests (137, of which 4 online in check mode against the default build: 0 failed); `demo.erl` and the crash copy as above,
with the default build; `actors.erl` sent again (23 frames, `ok`, 0 gaps): its unit differs from the one of
2026-11-13 only by the runtime's new functions. **Written, not run:** a static child with `permanent` or
`temporary` in a program (the trial has `temporary` in a child that is never reached); two static children of
one name; a message sent to the name before the `(:register)` is reached; a second `start_sup()`; a static child
whose function has code before its first receive; the restart limit; the Elixir and Gleam senders (not
changed: neither sends a `(:register)` or a `(:send_named)`; their examples were not sent again).

## What was run, and what it showed (2026-11-14, Apple Silicon, compiler 999916): the Elixir and Gleam senders split

**Nothing of the sink and nothing of the contract was changed in this step.** The Elixir and the Gleam sender
now do for their languages what the Erlang sender did the evening before (contract §1 "What you own", T9.13a,
T9.15, T9.16): they split a function at every receive, lower a trapped exit (Elixir) and a `gleam_otp` actor
(Gleam), and send their languages' output as `(:sl_call)` of Silica's print builtins. The sink printed what it
was told with the printer of the evening before (`src/ts_print.silica.in` of 2026-11-13 20:20, unchanged).

`silica-sink/trials/run_trials.sh <work-dir> 7495 all` from the sources as they stand (default build: one compiler
run for each store, 2 regions, trial hooks on), run alone on the machine once at the end of the step: **"all
trials passed"**, 165 passing lines, no failing line, exit status 0: the same 165 as the evening before, as the
sources are the same.

### What the two senders send now, and what the sink prints of it

| Source | The sender sends (contract nodes) | The sink prints |
| --- | --- | --- |
| Elixir: `account = receive do … end` followed by code; several receives; a receive inside a clause of `case`, `cond`, `if`, `receive` | the `(:receive)` in tail position, each clause ending in a tail `(:call)` of a continuation `f__k<n>(live variables, value)`; the code after it as that `(:function)`, `defp`, its signature hint `inferred` from the calls of it | as for Erlang: one waiting phase for each receive, the continuation a piece of the same actor |
| Elixir: `IO.inspect(withdraw_from(account, 100))`, `case get() do`, `a \|> wait_add() \|> add(1)`: a call of a function that receives, as an argument, a subject, a pipe stage | the call bound first (`e2s_h1`), then a tail `(:call)` of a copy `withdraw_from__c1` of the callee whose ends are tail calls of the continuation | pieces of one actor |
| Elixir: `Process.flag(:trap_exit, true)`, `spawn_link(fn -> "ada" \|> open() \|> account() end)`, `receive do {:EXIT, ^child, :normal} -> …` | the parent bound first, `(:spawn)` with `link` false of the copy `account__l(…, parent)`, which `(:send)`s `{:EXIT, self(), :normal}` before it ends; the receive's patterns hinted `(:t_tagged, EXIT, [actor, symbol])`; the pin as a guard test (as before) | an ordinary spawn, send and receive: the alternative `(:EXIT, actor_ref, atom)`, the guard `(v == a0)` |
| Elixir: `IO.puts(text)`, `IO.inspect({:balance, balance, :mean_move, mean})`, `IO.inspect(r)` with `r :: {:ok, integer()} \| {:refused, integer()}` | a `(:block)`: the value bound when it is not a variable or a literal, then `(:sl_call, "", "print" \| "println" \| "print_int64" \| "print_float64" \| "print_boolean" \| "atom_name", [x])` for each piece, chosen by the stated type; a tuple taken apart by a `(:case)` or a `(:match)`; a union by a `(:case)` over its alternatives; then `:ok` or the value | `{ _: atom <- case p1 of { (:ok, v4_: int64) -> { _: atom <- to_silica_b_print("{:ok, "); _: atom <- to_silica_b_print_int64(v4_); to_silica_b_print("}") }; … }; …; :ok }` |
| Elixir: `def boxes(%Box{n: 0})` | the field as a variable and the guard `e2s_p1 === 0` | a clause tested by its guard |
| Gleam: `let r = process.receive(reply, 1000)` followed by code, also in `case` branches; `case ask(counter) { … }` | the same split: `(:receive)` in tail position with a timeout, continuations `main__k1`, copies `ask__c1`, `summary__c1`; a receive that is an operand bound first | pieces of one actor |
| Gleam: a subject's message | a custom type with variants as it is (`(:add, 5)`, `stop`: one receive clause for each variant); any other type (a record, a tuple, an `Int`) as `(:subject__<type>, value)` with a `(:t_tagged)` hint: no `dynamic` | one alternative of the unit's message sum for each |
| Gleam: `actor.new(s) \|> actor.on_message(h) \|> actor.start` | an unlinked `(:spawn)` of `(:fun_ref gleam_otp_actor_loop__g<n>/1)` with `[state]`; the loop is a tail `(:receive)` that calls `h` by name and goes on in itself on `(continue, s)` | a process function |
| Gleam: `io.println("total " <> int.to_string(n) <> ", mean " <> float.to_string(f))` | a `(:block)` of `(:sl_call)` `print`, `print_int64`, `print_float64`, `println`, then `nil` | as for Erlang's `io:format` |

### The four examples, run

Each example was sent by its sender (a scratch copy of the repository's directory) in transpile mode to the
default build of the evening's trials (`<work-dir>/memory`, port 7492; the sink's sources have not changed
since), exported, compiled with compiler 999916, linked with a hand-written driver and run; the same calls were
run in the example's own language (`elixir`, `gleam run`; `demo.gleam` with a scratch `demo_ffi.erl`) and the
two outputs compared line by line (floats that stand alone as numbers, text as text). Each unit's own `main`
was also compiled and run as a program. No frame was rejected; no `T31xx`.

| Program | Frames | Sender's gaps | Result | `counts.gaps` | Diagnostics | Calls compared | Match | Mismatch | Fail in both | Stub in Silica | Not in the unit |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Elixir `actors.ex` | 28 (was 17) | **0** (was 2) | **`ok`** (was `partial`) | **0** (was 4) | 4 `T4004`, 1 `T2001` | 40 | **34** (was 20 of 37) | **1** (the 17th digit of a printed float) | 0 | 5 | 0 |
| Elixir `demo.ex` | 37 (was 36) | 6 (was 8) | `partial` | 8 (was 10) | 5 `T4001`, 3 `T4002`, 1 `T2001` | 56 | 41 | 0 | 1 | 6 | 8 |
| Gleam `actors.gleam` | 30 (was 26) | 3 | `partial` | 4 (was 10) | 3 `T4001`, 1 `T4002`, 2 `T4004`, 1 `T2001` | 18 | 14 | 0 | 0 | 4 | 0 |
| Gleam `demo.gleam` | 44 (was 41) | 3 (was 7) | `partial` | 8 (was 14) | 3 `T4001`, 5 `T4002`, 1 `T2001` | 52 | 44 (was 37 of 47) | 0 | 1 | 6 | 1 |
| scratch: Elixir `test/fixtures/split_shapes.ex` (every shape the Elixir split cuts) | 118 | 0 | `partial` | 1 | 33 `T4004`, 1 `T4002`, 1 `T2001` | its `main` only | 16 of 16 lines | 0 | | | |
| scratch: Gleam `plain.gleam` (`actors.gleam` without the name and the supervisor) | 29 | 0 | `partial` | 1 | 2 `T4004`, 1 `T4002`, 1 `T2001` | 18 | 17 | 0 | 0 | 1 | 0 |

**Each unit's own `main`, run as the program:**

| Program | The language prints | The Silica program prints | Exit status |
| --- | --- | --- | --- |
| Elixir `Actors.main/0` | `{:refused, 30}`, `{:ok, 40}`, `ada: low`, `{:balance, 40, :mean_move, 13.333333333333334}`, `account closed` | **the same five lines, but for the float's last digit** (`13.333333333333333`: `print_float64` writes at most 15 decimal places, cut and not rounded) | 0 |
| Elixir `Shapes.main/0` (the fixture) | `{:a, 1, 2}`, `9`, `6`, `50`, `40`, `5`, `7`, `16`, `111`, `:one`, `{:total, 111}`, `{:got, -1}`, `107`, `3000`, `0`, `closed` | **the same 16 lines** | 0 |
| Gleam `actors.main` | `counter: total 9, adds 3, small`, `mean 3.0`, `auditor: notes 3, sum 9` | **nothing**: the entry process ends in the stub of `start_audit()` (`process.new_name`, a named actor and a static supervisor are the sender's gaps) | 0 |
| Gleam `plain.main` (scratch) | the same three lines | **the same three lines** | 0 |
| Elixir `demo.ex`, Gleam `demo.gleam` | (no `main`) | | |

Elixir `actors.ex`, by function (40 rows; the pure functions' 16 rows are those of the night's table and match):

| Function | Calls | Elixir | Silica | Match |
| --- | --- | --- | --- | --- |
| `open`, `deposit`, `withdraw`, `level`, `mean_move`, `label` | the 16 calls of the night's table | | the same values | yes |
| (process) | `a = spawn(account(open("ada"))); {:deposit, 40}; {:deposit, 30}; {:deposit, -5}; {:withdraw, 100, self()}: received {:refused, n}, n` | `30` | `30` | yes (was a memory fault: three types for the tag `reply`) |
| (process) | `then {:withdraw, 30, self()}: received {:withdrawn, n}, n` | `40` | `40` | yes |
| (process) | `then {:report, self()}: received {:summary, text, balance, mean}`: text, balance, mean | `ada: low`, `40`, `13.333333333333334` | `ada: low`, `40`, `13.333333333333333` | yes (the float as a number) |
| (process) | `then :stop: the value the process ends with` | `ok` | `ok` | yes |
| (process) | `s = spawn(supervisor(self())): received {:account, c}; send(c, {:deposit, 40}); send(c, {:withdraw, 30, self()}): received {:withdrawn, n}, n` | `10` | `10` | yes (new: the supervisor started the account's linked copy) |
| (process) | `then send(c, :stop): received` | `account_closed` | `account_closed` | yes (new: the linked copy told the supervisor, the supervisor its parent) |
| (process) | `a2 = spawn(account(…)); {:deposit, 40}; withdraw_from(a2, 30) as a process; then {:report, self()} to a2: received {:summary, …}`: text, balance, mean | `ada: low`, `10`, `5.0` | `ada: low`, `10`, `5.0` | yes (was a stub) |
| `main() run as the program` | the 5 lines it prints | above | above | 4 yes, **1 no** (line 4: the float's 17th digit, as text) |
| `supervisor`, `withdraw_from`, `report`, `account`, `main` | each called as an ordinary function from the driver | `DOES NOT RETURN`, `refused`, `ada: empty`, `DOES NOT RETURN`, `ok` | `ends its actor (integer division by zero)` | stub, by design (T9.13: a process function runs only as a process) |

`actors.ex` is written as 23 functions (11 of the source, 12 the sender made: `account__l`, `main__k1` to
`main__k5`, `withdraw_from__c1`, `withdraw_from__c1__k1`, `withdraw_from__c2`, `withdraw_from__c2__k1`,
`report__c1`, `report__c1__k1`). The four `T4004` warn that a
message no clause takes is dropped (`main/0` and the three waiting pieces). **The example was changed**: each
answer of the account has a tag of its own (`{:withdrawn, n}`, `{:refused, n}`, `{:summary, text, balance,
mean}`) where it had three types under the tag `reply` (contract T9.12), and `await_reply/0`, whose result
was `term()`, is gone: `withdraw_from/2` and `report/1` each hold their receive.

Elixir `demo.ex`: the 41 matching calls of the night's table still match, `ratio(7, 0)` fails in both;
`supervise/1` is now written (it was the sender's gap: `Process.flag`), and called as an ordinary function it is
a stub by design, as `counter(10)` is. The other stubs and the 8 calls with nothing to call are those of the
night's table: `add_ten/1` a closure, `stop_counter/1` `Process.link` (**sink**, T9.15); `boxed/1`, `area/1`,
`max_of/2`, `sum_list/1` a type the sender cannot state (**sender**, on purpose); `name_or/2` a union with `nil`
(**sink**, from a Silica limitation observed); `shout/1` inter-node (by rule).

Gleam `demo.gleam`: newly matching `limit`, `under_limit` (2 calls), `sum_pair`, `sum_list` (2), `first_of`
(constants with a literal value, list values and patterns: the sender's). Stubs: `add_four`, `pipeline`
closures (**sink**); `ping_pong`, `pong_loop` the example's foreign `receive_message` (**by rule**, T9.9);
`count` `list.length`, a call into another module (**contract** T9.9); `second` a tuple index (**sender**).
Not written: `start_linked`, a linked spawn (**sink**, T9.15). (`demo.gleam` gained `under_limit`, `sum_pair`,
`one_two_three`, `second`.) Gleam `actors.gleam`: the 14 calls of the pure functions match; the 4 stubs are
the three lines of `main` and `main()` called as an ordinary function. Everything of it but the three
functions that need a name or the supervisor is written: `handle_counter`, `handle_auditor`, `start_counter`,
`add`, the actor loop `gleam_otp_actor_loop__g1/1`, and `main`, `main__k1`, `main__k1__k1`, `ask__c1`,
`ask__c1__k1`, `summary__c1`, `summary__c1__k1`.

**Differences from the languages that remain** (none changed a compared value except the float's last digit):
a process function called as an ordinary function fails; selective receive is not kept (`T4004`; Gleam: a
subject does not select its messages either); a trapped exit is delivered only for an end the source writes; a
`gleam_otp` actor is not linked to its starter, and under `a4_4 transient` the unit's supervisor would start a
failed one again, which neither language does; `print_float64` writes at most 15 decimal places, cut and not rounded; `IO.inspect` does not escape
a string. Each is in its sender's README.

Also run against the same build: the Elixir sender's suite, `TO_SILICA_PORT=7492 mix test` from a scratch
copy: 90 tests, 0 failed (88 offline; the two check-mode sessions: `demo.ex` `ok` with 6 gaps, `actors.ex` `ok` with 0); the Gleam sender's suite, `test/run_test.sh 7492` from a scratch copy: 58 passed, 0 failed
(the two check-mode sessions among them: `demo` and `actors` each `ok` with 3 gaps).

### What was changed for it

- **Elixir sender**: `lib/e2s/split.ex` (new: the cut at a receive, binding a waiting argument first, copies of
  callees, the linked copy, live variables by Elixir's scoping, literals in struct patterns),
  `lib/e2s/codex.ex` (`made_sigs/2`: the signatures of the functions the split made, from the calls of them; N6
  names in `fname/3`; `io/4`: `IO.puts/1`, `IO.inspect/1`), `lib/e2s/codex/types.ex` (`merge/2`; `show/1` of a
  tagged tuple raised), the command line's `--split`, tests ("the split", 10 cases, and
  `test/fixtures/split_shapes.ex`), README, `examples/actors.ex` (one tag for each answer),
  the comments of `examples/demo.ex`.
- **Gleam sender**: `src/gleam_to_silica_poc/split.gleam` (new), `codex.gleam` (`settle_made`: the made
  functions' types; messages of a subject; the actor loop; `io.println`; lists, constants, aliases), tests (6
  new, 12 updated), README, `examples/demo.gleam` (four functions added).
- **Sink, contract, the Erlang sender**: nothing.

### Limitations observed in this step (compiler 999916; nothing reported or changed in Silica)

- **A discarded binding whose type is a sum is not accepted.** `_: (:ok, int64) | (:refused, int64) <- p1`
  does not parse (E1069 "function … has no parsable body"; with a name, `x: (:ok, int64) | (:refused, int64)
  <- p1`, it parses; with the type in parentheses E2006). The sink writes a statement whose value is dropped
  that way (`{ _: T <- e; … }`), and the value a process function ends with (`ending`: E2005 "invalid or
  unsupported case pattern" was the answer there). Met by `IO.inspect(r)` of a union as a statement (the Elixir
  sender now ends the lowered statement with `:ok`) and by a Gleam process function ending in a `Result` (the
  Gleam sender writes the receive's value where it is used). **Not avoided:** a statement of a union type whose
  value is dropped (`withdraw(state, 1)` on a line of its own), and a public function that receives and ends
  with a union-typed variable: their units would not compile. **Sink, open** (printing: not changed in this
  step, no sender needs it for the examples).
- **A message alternative whose element is itself a sum** (`(:subject__counter_message, (:add, int64) |
  (:get, actor_ref))`) compiled, and the program ended with a memory fault in the handler the value was passed
  to. The Gleam sender sends a custom type with variants as it is instead.
- **A call of a function that was sent as a gap form is written as a call of an unknown function** (E2007), so
  the unit does not compile: a `(:gap)` form has no signature to write a stub from. Met while the Elixir
  sender's made functions were not yet all typed (fixed in the sender; a made function without a type now makes
  each call of it a gap node too). **Sink, open:** not reported at transpile time.

Not run: anything on Linux; the examples on the `(:backing)` store; a message that arrives while a split
process waits in another receive (it is dropped: `T4004`); a linked child that ends by `exit(atom)` or by a
failure of the runtime; `supervise/1` of `demo.ex` as a process (its child cannot be reached from outside);
the Gleam actors through a driver (they are private; reached through `plain.main`); `stop_abnormal`; the
Erlang examples again (neither the sink nor the Erlang sender changed).

## What was run, and what it showed (2026-11-13, late, Apple Silicon, compiler 999916): the split, run

`silica-sink/trials/run_trials.sh <work-dir> 7492 all` from the sources as they stand (default build: one compiler
run for each store, 2 regions, trial hooks on), run alone on the machine: **"all trials passed"**, 165 passing
lines, no failing line, exit status 0, 13 min 51 s. `p0_check_mode` 20 of 20, goldens 23 of 23, `p2_actors` 23 of
23 on both stores, `p1_export`, `p3_types` 32 of 32 and its generated unit, `p4_processes` 36 of 36 and its two
generated units, the kill and restart, the orderly end. (A first run of the suite in this step was started while
an example was being compiled on the same machine and was stopped: below, "Limitations observed in this step".)

`p4_processes` has eight cases more (36): `mid2/0` and `mid2__k1/1`, the function `mid/0` as contract T9.13a
asks a sender to send it (the receive in tail position, its clause going on in the continuation: written, with
the `T4004` warning, and run: it takes `{said, 41}` and ends with 42); `pre/0`, a function that is not exported
and goes on in `mid2/0` (no note about an ordinary call of a process function: contract T9.13); `say/1`,
`(:sl_call)` of `print`, `print_int64` and `println` (run: it prints `say: n = 7`); `bad_print/1`, a float given
to `print_int64` (`T3103` at the argument); `bad_builtin/0`, a builtin that is not on the list (`T4002`); and
two checks of messages: the unsplit `mid/0` is told `THE SENDER MUST SPLIT THE FUNCTION AT THIS RECEIVE
(contract T9.13a)`, and no note names `mid2/0`.

### What the Erlang sender sends now, and what the sink prints of it

| Erlang | The sender sends (contract nodes) | The sink prints |
| --- | --- | --- |
| code before a receive | the statements, then the `(:receive)` in tail position | `to_silica_e_<f>_<n>`: run when the process gets its start message |
| a receive with code after it | the `(:receive)` in tail position, each clause ending in a tail `(:call)` of a continuation `f__k<n>(live variables, value)`; the code after it as that `(:function)` | the clause's arm calls `to_silica_e_f__k<n>_<m>(…, k)` in the same dispatch; the continuation is one more piece of the same actor |
| several receives | one continuation each | one waiting phase each |
| a call of a function that receives, with code after it | a tail `(:call)` of a copy `g__c<n>` of the callee, whose ends are tail calls of the continuation | the same: pieces of one actor |
| what a waiting process keeps | in a function it made: the receive as the whole body of `f__k<n>`, whose parameters are the variables the receive uses | the waiting phase holds exactly those parameters |
| `process_flag(trap_exit, true)`, `spawn_link(fun() -> g(…) end)`, `receive {'EXIT', Pid, R}` | the parent bound first (`(:match)` of a variable with `(:self)`), then `(:spawn)` with `link` false of the copy `g__l(…, parent)`, which `(:send)`s `{'EXIT', self(), normal}` before it ends; the receive's pattern hinted `(:t_tagged, EXIT, [actor, symbol])`, a bound pid compared in the guard with `=:=` | an ordinary spawn, send and receive: the message alternative `(:EXIT, actor_ref, atom)`, the guard `(v == a0)` |
| `io:format("total ~p…~n", [Total, …])` | a `(:block)`: the arguments that are calls bound first, then `(:sl_call, "", "print", [(:text)])`, `(:sl_call, "", "print_int64", [v])`, `print_float64`, `print` of `(:sl_call, "", "atom_name", [v])`, …, then `(:symbol, ok)` | `{ _: atom <- to_silica_b_print("total "); _: atom <- to_silica_b_print_int64(v3_); …; :ok }` and the helper functions once in the unit |
| `average(#tally{adds = 0}) -> 0.0` | the field as a variable and the guard `E2s_p1 =:= 0` | a clause tested by its guard |

### The Erlang examples, run again

`examples/actors.erl` and `examples/demo.erl`, sent by the Erlang sender (the repository's sources) in
transpile mode to that default build (`<work-dir>/memory`), exported, compiled with compiler 999916, linked with
the drivers of the night's run (the `actors` driver extended by the supervisor as a process) and run; the same
calls run in Erlang (`erlc`, `erl`) against the real modules; compared line by line (floats as numbers). No
frame was rejected; no `T31xx`.

| Program | Frames | Result | `counts.gaps` | Diagnostics | Calls compared | Match | Mismatch | Stub in Silica | Not in the unit |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Erlang `actors.erl` | 23 (was 14) | **`ok`** (was `partial`) | **0** (was 4) | 3 `T4004`, 1 `T2001` | 22 | **19** (was 6 of 18) | 0 | 3 | 0 |
| Erlang `demo.erl` | 36 (was 35) | `partial` | 5 (was 7) | 3 `T4001`, 1 `T4002`, 1 `T2001` | 40 | 37 | 0 | 2 | 1 |

| Function | Calls | Erlang | Silica | Match |
| --- | --- | --- | --- | --- |
| `new_tally`, `bump`, `describe` | the six calls of the night's table | `0`, `0`, `5`, `1`, `small`, `large` | the same | yes |
| (process) | `C = spawn(counter(new_tally())), C ! {add, 2}, C ! {add, 5}, C ! {get, self()}: received {tally, Total, Adds, Mean}`: Total, Adds, Mean | `7`, `2`, `3.5` | `7`, `2`, `3.5` | yes (was a stub) |
| (process) | `then C ! stop: the value the process ends with` | `ok` | `ok` | yes (was a stub) |
| (process) | `S = spawn(supervisor(self(), 0)): received {child, C}; C ! {add, 4}, C ! {get, self()}: received {tally, Total, Adds, Mean}`: Total, Adds, Mean | `4`, `1`, `4.0` | `4`, `1`, `4.0` | yes (new) |
| (process) | `then C ! stop: received {supervisor_done, Restarts}, Restarts` | `0` | `0` | yes (new: the linked copy told the supervisor) |
| `average` | `average(#tally{total = 7, adds = 2})`, `average(new_tally())` | `3.5`, `0.0` | `3.5`, `0.0` | yes (was a stub) |
| `main() run as the program` | the 3 lines it prints | `total 7 after 2 adds, mean 3.5: small`, `total 36 after 3 adds, mean 12.0: large`, `the counter stopped; restarts: 0` | **the same three lines; exit status 0** | **yes** (was a stub) |
| `supervisor` | `supervisor(self(), 0)` called as an ordinary function | `DOES NOT RETURN in 1500 ms` | `ends its actor (integer division by zero)` | stub, by design (T9.13) |
| (process) | `counter(new_tally())` called as an ordinary function | `DOES NOT RETURN in 1500 ms` | `ends its actor (integer division by zero)` | stub, by design |
| `main` | `main()` called as an ordinary function from the driver | `0` (after printing) | `ends its actor (integer division by zero)` | stub, by design: started as the entry process it matches (row above) |

`actors.erl` is written as 17 functions (8 of the source, 9 the sender made: `counter__l`, `main__k1` to
`main__k4`, `ask__c1`, `ask__c1__k1`, `ask__c2`, `ask__c2__k1`), 8 of them process functions. The three `T4004`
warn that a message no clause takes is dropped (`main/0`, `ask__c1__k1`, `ask__c2__k1`). `demo.erl`: the 37
matching calls of the evening's table still match; `supervise/1` is now written (it was the sender's gap);
`lookup/1`, `uses_untyped/1` are stubs and `untyped/1` is not written, as before.

**Differences from Erlang that remain** (none changed a compared value): a process function called as an
ordinary function fails (3 rows); selective receive is not kept; a trapped exit is delivered only for an end the
source writes; the value `main/0` ends with (`{restarts, 0}`) goes to nobody.

Also run against the same build: the Erlang sender's suite, `test/run_test.sh 7492` from a scratch copy: 125
tests, 0 failed (121 offline; one of them compiles the split forms of `actors.erl` as Erlang and requires what
the module prints and returns); and, to see that the sink's changes moved nothing for them, the Elixir and Gleam
examples sent by their unchanged senders: `demo.ex` `partial` 10, `actors.ex` `partial` 4, `demo.gleam`
`partial` 14, `actors.gleam` `partial` 10, `sendnil.gleam` `ok` 0, as in the night's table (`Actors.main/0` now
gets the diagnostic that says the sender must split). Their units were not compiled or run again.

### What was changed for it

- **Erlang sender**: `src/e2s_split.erl` (new: the cut at a receive, copies of callees, the linked copy, live
  variables, literals in record patterns), `src/e2s_codex.erl` (`gen_sigs/2`, `fsig/2`: the signatures of the
  functions the split made, from the calls of them; N7 names in `fname/4`; `io_format/4`), tests (`split/0`, 19
  cases), README ("Processes: what this sender splits", "Change what is split"), the comment of `supervise/1` in
  `examples/demo.erl`.
- **Sink, printer** (`src/ts_print.silica.in`): `sl_call_ex`, `builtin_result`, `builtin_param`,
  `builtin_helper` (contract T9.16); the diagnostic of a receive that is not in tail position; `only_dead_calls`
  (an ordinary call of a process function is not reported when it stands only in the ordinary version of a
  function that is not exported and that nothing calls: contract T9.13). Nothing that splits, and nothing that
  knows a language.
- **Contract**: §1 "What you own" (a language's semantics are its sender's); **T9.13a** (new: you split a
  function at a receive); T9.13 (the sentence about an unsplit receive, the note about dead ordinary calls);
  **T9.16** (new: L1 as built, the print builtins); T9.15 (a sender may lower a trapped exit itself); H23 and L1
  rows. Design: §5.4 (as built), §5.5 (what the section does not hold; the rows on the unsplit receive, the kept
  state, the ordinary call).
- The Elixir and Gleam senders were not changed (`../SENDER_GAPS_STATUS.md` lists what each would need).

### Limitations observed in this step (compiler 999916; nothing reported or changed in Silica)

- **A program ended with a memory fault after its entry process had printed everything**
  (`fault … in silica_rt_message_measure`, exit status 70): `actors.erl`, when the sender still sent the last
  receive of `main/0` in the function that also bound `Total2`, `Adds2`, `Mean2` and the tuple they came from,
  so that the waiting phase kept `(float64, int64, int64, (int64, int64, float64), actor_ref)` and the receive
  used none of them. Measured with variants of the exported unit: with the entry process not ending, no fault;
  with that phase keeping only the process reference, no fault (status 0); with constants in place of the kept
  float and tuple, the fault stayed; with the two timed waits removed, it stayed; with the supervisor process
  not ending, it stayed; a smaller program whose entry process ended from a waiting phase that kept `(float64, int64,
  (int64, float64), actor_ref)`, three of them unused (`b3` in the scratch directory), ended with status 0. Not understood further. The Erlang
  sender now sends a receive with only the variables it uses (contract T9.13a), and the program ends with 0.
- A parameter may not be named `unit` (E1040, "expected ';'": the name is reserved, as the list above says).
- A freshly built transpiler was not listening 2 seconds after its start when other compilers were running on
  the machine: the first run of the trial suite in this step was started while an example was being compiled,
  its first 27 connections were refused (`econnrefused`: every case of `p0_check_mode` and the first 8 goldens),
  and it was stopped. The suite was then run alone (above).

Not run: anything on Linux; the Elixir and Gleam examples against this build (their senders were not changed);
`supervise/1` of `demo.erl` as a process (its child cannot be reached from outside, so there is nothing to
compare; it is written with no diagnostic); a linked child that ends by `exit(Atom)` (the second receive clause
of `supervisor/2`: written, not reached by the example or the driver); a child that fails in the runtime under
a trapping parent; a message that arrives while a split process waits in another receive (it is dropped:
`T4004`); the examples on the `(:backing)` store; an `(:sl_call)` in check mode (accepted, whatever it names).

## What was run, and what it showed (2026-11-13, night, Apple Silicon, compiler 999916): the examples, run

`silica-sink/trials/run_trials.sh <work-dir> 7472 all` from the sources as they stand (default build: one compiler
run for each store, 2 regions, trial hooks on): **"all trials passed"**, 157 passing lines, no failing line, exit
status 0, 13 min 49 s. `p4_processes` has one case more (28): `blow/1`, a symbol message whose hint states the
whole message type; the generated unit's run now sends `boom` through it.

Then every example of the three senders was sent by its sender (from a scratch copy of its directory) in
transpile mode to that default build (`<work-dir>/memory`), exported, and **linked with a hand-written driver and
run**; the same calls were run in the example's own language (`elixir`, `gleam run`, `erlc` and `erl`) and the
two outputs compared line by line (floats as numbers). No frame was rejected; no `T31xx`.

| Program | Frames | Result | `counts.gaps` | Calls compared | Match | **Mismatch** | Fail in both | Stub in Silica | Not in the unit |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Erlang `demo.erl` (run again, the driver of the evening) | 35 | `partial` | 7 | 40 | 37 | 0 | 0 | 2 | 1 |
| Erlang `actors.erl` | 14 | `partial` | 4 | 18 | 6 | 0 | 0 | 12 | 0 |
| Elixir `demo.ex` | 36 | `partial` | 10 | 56 | 41 | 0 | 1 | 6 | 8 |
| Elixir `actors.ex` | 17 | `partial` | 4 | 37 | 20 | **5** | 0 | 12 | 0 |
| Gleam `demo.gleam` | 41 | `partial` | 14 | 47 | 37 | 0 | 1 | 7 | 2 |
| Gleam `actors.gleam` | 26 | `partial` | 10 (was 11) | 18 | 14 | 0 | 0 | 4 | 0 |
| scratch `sendnil.gleam` (`add/3` of `actors.gleam`, public) | 10 | `ok` | 0 | 10 | 10 | 0 | 0 | 0 | 0 |

How each was run:

- **The driver** (one for each unit, Silica, hand-written) is compiled with the exported unit, Silica's
  `Supervisor` unit and a prelude unit by compiler 999916, linked and run. Its `main` calls every ordinary
  function the unit exports and prints one line for each value. An actor of the driver then starts each process
  function with `<f>__spawn_watched(arguments, self())`, casts it the messages and prints what comes back and
  the value the process ends with. **Every failing stub is called too**, each in an actor of its own (a stub
  ends the actor that calls it, not the program), and the failure report is printed.
- **The unit's own `main`** (the three `actors` units have an entry point): the unit alone, compiled and linked
  as a program and run. The driver is linked with a copy of the unit without that `main` (two `main`s do not
  link).
- **Not callable from a driver**: a function that is private in the source is not exported by the unit
  (Gleam `add/3`, `ask/1`, `summary/1`, `negate/1`; Erlang `actors:ask/1`). They are reached only through
  `main`. `add/3` was run in the scratch unit `sendnil.gleam`, where it is public.
- The native Gleam run of `demo.gleam` needed a scratch `demo_ffi.erl` (`receive M -> M end`): the example
  binds `receive_message` to that module and the repository has no such file.

**Result in one line: of 186 calls of the five newly run programs and the scratch unit, 128 give the language's
value, 2 fail in both, 5 do not match (one cause), 41 end in a failing stub and 10 have nothing to call. No call
that returned a value returned a wrong one.**

### Elixir `demo.ex`

| Function | Calls | Elixir | Silica | Match |
| --- | --- | --- | --- | --- |
| `add` | `add(2, 3)` | `5` | `5` | yes |
| `scale` | `scale(2.5, 4)` | `15.0` | `15.0` | yes |
| `halves` | `halves(7) element 1`, `halves(7) element 2`, `halves(-7) element 1`, `halves(-7) element 2` | `3`, `1`, `-3`, `-1` | `3`, `1`, `-3`, `-1` | yes |
| `ratio` | `ratio(7, 2)`, `ratio(7, 0)` | `3.5`, `fails (badarith)` | `3.5`, `ends its actor (integer division by zero)` | yes (both fail) |
| `percent` | `percent(1, 3.0)`, `percent(1, 8.0)`, `percent(-1, 8.0)`, `percent(5, -2.5)` | `33`, `13`, `-13`, `-2` | `33`, `13`, `-13`, `-2` | yes |
| `differ` | `differ(1, 2)`, `differ(3, 3)` | `true`, `false` | `true`, `false` | yes |
| `greet` | `greet("ada")` | `hello, ada` | `hello, ada` | yes |
| `swap` | `swap({7, true}) element 1`, `swap({7, true}) element 2` | `true`, `7` | `true`, `7` | yes |
| `origin` | `origin() x`, `origin() y` | `0`, `0` | `0`, `0` | yes |
| (process) | `move(%Point{x: 1, y: 2}, 3, 4) x` | `4` | `4` | yes |
| (process) | `move(%Point{x: 1, y: 2}, 3, 4) y` | `6` | `6` | yes |
| (process) | `x_of(%Point{x: 9, y: 1})` | `9` | `9` | yes |
| (process) | `shift(%Point{x: 1, y: 2}, 5) x` | `6` | `6` | yes |
| (process) | `shift(%Point{x: 1, y: 2}, 5) y` | `2` | `2` | yes |
| `doubled_sum` | `doubled_sum(3, 4)` | `14` | `14` | yes |
| `classify` | `classify(-5)`, `classify(0)`, `classify(3)` | `negative`, `zero`, `positive` | `negative`, `zero`, `positive` | yes |
| `describe` | `describe(0)`, `describe(5)` | `zero`, `not zero` | `zero`, `not zero` | yes |
| `sign` | `sign(-9)`, `sign(0)`, `sign(4)` | `-1`, `0`, `1` | `-1`, `0`, `1` | yes |
| `twice` | `twice(&inc/1, 5)` | `7` | `7` | yes |
| `add_three` | `add_three(1)` | `4` | `4` | yes |
| `adder` | `adder().(2, 3)` | `5` | `5` | yes |
| (process) | `c = start_counter(); send(c, {:add, 5}); send(c, {:add, 37}); send(c, {:get, self()}): received {:total, n}, n` | `42` | `42` | yes |
| (process) | `p = spawn(pong_loop); send(p, {:ping, self(), 41}): received {:pong, n}, n` | `42` | `42` | yes |
| (process) | `p = spawn(pong_loop); send(p, {:ping, self(), 41}): received: the value the process ends with` | `ok` | `ok` | yes |
| (process) | `ping_pong(41): the value the process ends with` | `42` | `42` | yes |
| (process) | `counter(10) after {:add, 1}, {:add, 2} and :stop: the value the process ends with` | `13` | `13` | yes |
| (process) | `add_three(1) as a process: the value the process ends with` | `4` | `4` | yes |
| `add_ten` | `add_ten(1)` | `11` | `ends its actor (integer division by zero)` | stub |
| `boxed` | `boxed(1)` | `6` | `ends its actor (integer division by zero)` | stub |
| `stop_counter` | `stop_counter(start_counter())` | `true` | `ends its actor (integer division by zero)` | stub |
| `supervise` | `supervise(0)` | `DOES NOT RETURN in 1500 ms` | `ends its actor (integer division by zero)` | stub |
| `shout` | `shout("x")` | `NOT CALLED (inter-node)` | `ends its actor (integer division by zero)` | stub |
| (process) | `counter(10) called as an ordinary function` | `DOES NOT RETURN in 1500 ms` | `ends its actor (integer division by zero)` | stub |
| `name_or` | `name_or(nil, "x")`, `name_or("ada", "x")` | `x`, `ada` | `(not in the unit)` | not written |
| `area` | `area({:square, 3})`, `area({:rectangle, 2, 5})`, `area({:circle, 1.0})` | `9`, `10`, `3.14159` | `(not in the unit)` | not written |
| `max_of` | `max_of(3, 9)`, `max_of(9, 3)` | `9`, `9` | `(not in the unit)` | not written |
| `sum_list` | `sum_list([1, 2, 3])` | `6` | `(not in the unit)` | not written |

Stubs and missing functions, by cause: `add_ten/1` a closure (**sink**); `boxed/1` a fn parameter with no type
(**sender**, deliberate); `stop_counter/1` `Process.link` (**sink**, contract T9.15); `supervise/1`
`Process.flag` (**sender / contract**: no node for trapping exits); `shout/1` inter-node (by rule);
`counter(10)` called as an ordinary function: by design (contract T9.13: a process function runs only as a
process; started with `counter__spawn_watched` it matches); `name_or/2` a union with `nil` (**sink**, from a
Silica limitation observed); `area/1` `number()`, `max_of/2` no `@spec`, `sum_list/1` a list type (**sender**).
`add_three/1` has a process entry point because its body is a tail call; run as a process it ends with 4.

### Elixir `actors.ex`

| Function | Calls | Elixir | Silica | Match |
| --- | --- | --- | --- | --- |
| `open` | `open("ada") owner`, `open("ada") balance`, `open("ada") moves` | `ada`, `0`, `0` | `ada`, `0`, `0` | yes |
| `deposit` | `deposit(open("ada"), 40) owner`, `deposit(open("ada"), 40) balance`, `deposit(open("ada"), 40) moves` | `ada`, `40`, `1` | `ada`, `40`, `1` | yes |
| `withdraw` | `withdraw(deposit(open("ada"), 40), 100) tag`, `withdraw(deposit(open("ada"), 40), 100) short`, `withdraw(deposit(open("ada"), 40), 30) tag`, `withdraw(deposit(open("ada"), 40), 30) balance`, `withdraw(deposit(open("ada"), 40), 30) moves` | `refused`, `60`, `ok`, `10`, `2` | `refused`, `60`, `ok`, `10`, `2` | yes |
| `level` | `level(0)`, `level(49)`, `level(50)` | `empty`, `low`, `healthy` | `empty`, `low`, `healthy` | yes |
| `mean_move` | `mean_move(40, 3)`, `mean_move(5, 0)` | `13.333333333333334`, `0.0` | `13.333333333333333`, `0.0` | yes |
| `label` | `label(open("ada"))`, `label(deposit(open("ada"), 40))`, `label(deposit(deposit(open("ada"), 40), 40))` | `ada: empty`, `ada: low`, `ada: healthy` | `ada: empty`, `ada: low`, `ada: healthy` | yes |
| (process) | `a = spawn(account(open("ada"))); {:deposit, 40}; {:deposit, 30}; {:deposit, -5}; {:withdraw, 100, self()}: received {:reply, {:refused, n}}, n` | `30` | `MEMORY FAULT in the receiving actor (variant run with the reply arms; three alternatives with the tag reply)` | **NO** |
| (process) | `then {:withdraw, 30, self()}: received {:reply, {:ok, n}}, n` | `40` | `not reached (the variant run ended at the first reply)` | **NO** |
| (process) | `then {:report, self()}: received {:reply, {text, balance, mean}}, text` | `ada: low` | `not reached (the variant run ended at the first reply)` | **NO** |
| (process) | `then {:report, self()}: received {:reply, {text, balance, mean}}, balance` | `40` | `not reached (the variant run ended at the first reply)` | **NO** |
| (process) | `then {:report, self()}: received {:reply, {text, balance, mean}}, mean` | `13.333333333333334` | `not reached (the variant run ended at the first reply)` | **NO** |
| (process) | `then :stop: the value the process ends with` | `ok` | `ok` | yes |
| (process) | `withdraw_from(a2, 30) as a process: the value the process ends with` | `{:ok, 10}` | `ends its actor (integer division by zero)` | stub |
| (process) | `report(a2) as a process: the value the process ends with` | `{"ada: low", 10, 5.0}` | `FAILS: (:explicit, :actor_not_found)` | stub |
| `supervisor` | `supervisor(self())` | `DOES NOT RETURN in 1500 ms` | `ends its actor (integer division by zero)` | stub |
| (process) | `withdraw_from(a, 30) called as an ordinary function` | `refused` | `ends its actor (integer division by zero)` | stub |
| (process) | `report(a) called as an ordinary function` | `ada: empty` | `ends its actor (integer division by zero)` | stub |
| (process) | `account(open("ada")) called as an ordinary function` | `DOES NOT RETURN in 1500 ms` | `ends its actor (integer division by zero)` | stub |
| `main() run as the program` | the 5 lines it prints | `{:refused, 30}`, `{:ok, 40}`, `ada: low`, `{:balance, 40, :mean_move, 13.333333333333334}`, `account closed` | `ends its actor (integer division by zero) (the entry process ended)` | stub |
| `main` | `main()` | `ok` | `ends its actor (integer division by zero)` | stub |

- **The mismatch (5 rows, one cause).** The account answers `{:reply, {:refused, n}}`, `{:reply, {:ok, n}}` and
  `{:reply, {text, balance, mean}}`: three types for the tag `reply`, which contract T9.12 forbids (**the
  example and its sender**), which the **sink** does not check, and which Silica accepts: the unit's message sum
  has three alternatives `(:reply, …)`, the unit compiles, and the driver's actor ended the program with a
  memory fault (`fault … in drv_ex_actors_probe`, exit status 70) when the first reply arrived, with one
  `(:reply, (:refused, n: int64))` arm as with all three. A program of one function over the same sum printed
  `1`, `1002` and `6089159424` for the three alternatives (**limitation observed**). The table's other rows are
  from the driver without the reply arms. Whether the account sent the right values could therefore not be
  seen.
- Stubs: `withdraw_from/2` and `report/1` go on in `await_reply/0`, which is the **sender's** gap (`term()`);
  as processes they send their request and end in the stub. The account then answered a process that had
  ended and ended itself with `actor_not_found` (the hello's `a5_4 accept_sender_death`; in Elixir the send
  does nothing), which is why `report(a2)` shows that reason. `supervisor/1`: `Process.flag` (**sender /
  contract**). `main/0`: a receive that is not in tail position (**sink**), so the unit's own program starts,
  its entry process ends in the stub, nothing is printed and the exit status is 0.

### Gleam `demo.gleam`

| Function | Calls | Gleam | Silica | Match |
| --- | --- | --- | --- | --- |
| `add` | `add(2, 3)` | `5` | `5` | yes |
| `scale` | `scale(2.5, 4.0)` | `15.0` | `15.0` | yes |
| `split` | `split(7, 2)`, `split(-7, 2)`, `split(7, 0)` | `4`, `-4`, `0` | `4`, `-4`, `0` | yes |
| `average` | `average(7, 2)`, `average(-7, 2)`, `average(1, 0)` | `4`, `-4`, `0` | `4`, `-4`, `0` | yes |
| `whole` | `whole(5.0)`, `whole(-5.0)` | `2`, `-2` | `2`, `-2` | yes |
| `greet` | `greet("ada")` | `hello, ada` | `hello, ada` | yes |
| `flip` | `flip(True)` | `false` | `false` | yes |
| `swap` | `swap(#(7, True)) element 1`, `swap(#(7, True)) element 2` | `true`, `7` | `true`, `7` | yes |
| `origin` | `origin() x`, `origin() y` | `0`, `0` | `0`, `0` | yes |
| `move` | `move(Point(1, 2), 3, 4) x`, `move(Point(1, 2), 3, 4) y` | `4`, `6` | `4`, `6` | yes |
| `x_of` | `x_of(Point(9, 1))` | `9` | `9` | yes |
| `classify` | `classify(-5)`, `classify(0)`, `classify(3)` | `negative`, `zero`, `positive` | `negative`, `zero`, `positive` | yes |
| `area` | `area(Square(3))`, `area(Rectangle(2, 5))`, `area(Rectangle(-2, 5))`, `area(Circle(1.0))` | `9.0`, `10.0`, `0.0`, `3.14159` | `9.0`, `10.0`, `0.0`, `3.141589999999999` | yes |
| `describe` | `describe(0)`, `describe(5)`, `describe(-5)` | `zero`, `not zero`, `not zero` | `zero`, `not zero`, `not zero` | yes |
| `max_of` | `max_of(3, 9)`, `max_of(9, 3)` | `9`, `9` | `9`, `9` | yes |
| `order` | `order(1, 2)`, `order(2, 2)`, `order(3, 2)` | `negative`, `zero`, `positive` | `negative`, `zero`, `positive` | yes |
| `twice` | `twice(fn(x) { x + 1 }, 5)` | `7` | `7` | yes |
| `adder` | `adder()(2, 3)` | `5` | `5` | yes |
| `positive` | `positive(5)`, `positive(-1)` | `5`, `fails (panic)` | `5`, `ends its actor (integer division by zero)` | yes (both fail) |
| `add_four` | `add_four(1)` | `5` | `ends its actor (integer division by zero)` | stub |
| `pipeline` | `pipeline(1)` | `-8` | `ends its actor (integer division by zero)` | stub |
| `ping_pong` | `ping_pong(41)` | `42` | `ends its actor (integer division by zero)` | stub |
| `pong_loop` | `pong_loop()` | `DOES NOT RETURN in 1500 ms` | `ends its actor (integer division by zero)` | stub |
| `sum_list` | `sum_list([1, 2, 3])` | `6` | `ends its actor (integer division by zero)` | stub |
| `first_of` | `first_of([1, 2, 3])` | `1` | `ends its actor (integer division by zero)` | stub |
| `count` | `count([1, 2, 3])` | `4` | `ends its actor (integer division by zero)` | stub |
| `limit` | `limit` | `10` | `(not in the unit)` | not written |
| `stop` | `stop(start_linked())` | `true` | `(not in the unit)` | not written |

Gleam's own arithmetic is kept: `split(-7, 2)` (`/` and `%` toward zero), `split(7, 0)` and `average(1, 0)`
(a zero divisor gives 0), `average(-7, 2)` (`float.round`, a half away from zero), `whole(-5.0)`. Stubs:
`add_four/1`, `pipeline/1` closures (**sink**); `ping_pong/1`, `pong_loop/0` the type `dynamic` of an external
`Pid`'s messages (**sink**: no untyped representation; **contract**: nothing else to send);
`sum_list/1`, `first_of/1` list patterns, `count/1` `list.length`, `limit` a constant (**sender**);
`start_linked/0`, `stop/1` `dynamic` in the signature (**sink / contract**). `negate/1` is private.

### Gleam `actors.gleam`

| Function | Calls | Gleam | Silica | Match |
| --- | --- | --- | --- | --- |
| `new_tally` | `new_tally() label`, `new_tally() total`, `new_tally() adds` | `counter`, `0`, `0` | `counter`, `0`, `0` | yes |
| `bump` | `bump(new_tally(), 5) label`, `bump(new_tally(), 5) total`, `bump(new_tally(), 5) adds` | `counter`, `5`, `1` | `counter`, `5`, `1` | yes |
| `describe` | `describe(-1)`, `describe(5)`, `describe(10)` | `negative`, `small`, `large` | `negative`, `small`, `large` | yes |
| `size_name` | `size_name(Negative)`, `size_name(Small)`, `size_name(Large)` | `negative`, `small`, `large` | `negative`, `small`, `large` | yes |
| `mean` | `mean(12, 2)`, `mean(5, 0)` | `6.0`, `0.0` | `6.0`, `0.0` | yes |
| `main() run as the program` | the 3 lines it prints | `counter: total 9, adds 3, small`, `mean 3.0`, `auditor: notes 3, sum 9` | `ends its actor (integer division by zero) (the entry process ended)` | stub |
| `main` | `main()` | `nil` | `ends its actor (integer division by zero)` | stub |

`main/0` and everything of the two `gleam_otp` actors need the type `dynamic` (**sink / contract**), so the
unit's own program prints nothing. `add/3` is now written (the sender's change, below) and is private; the
scratch unit `sendnil.gleam` has it public, with three more shapes of a send whose value is `Nil`:

| Function | Calls | Gleam | Silica | Match |
| --- | --- | --- | --- | --- |
| `add` | `add(c, a, 5)` | `nil` | `nil` | yes |
| (process) | `add(c, a, 5): c received Add(n), n` | `5` | `5` | yes |
| (process) | `add(c, a, 5): a received Note(n), n` | `5` | `5` | yes |
| `tell` | `tell(c, 7)` | `nil` | `nil` | yes |
| (process) | `tell(c, 7): c received Add(n), n` | `7` | `7` | yes |
| `tell_then` | `tell_then(c, 8)` | `9` | `9` | yes |
| (process) | `tell_then(c, 8): c received Add(n), n` | `8` | `8` | yes |
| `maybe` | `maybe(c, 0)`, `maybe(c, 3)` | `nil`, `nil` | `nil`, `nil` | yes |
| (process) | `maybe(c, 0): c received` | `reset` | `reset` | yes |

### Erlang `actors.erl`

| Function | Calls | Erlang | Silica | Match |
| --- | --- | --- | --- | --- |
| `new_tally` | `new_tally() total`, `new_tally() adds` | `0`, `0` | `0`, `0` | yes |
| `bump` | `bump(new_tally(), 5) total`, `bump(new_tally(), 5) adds` | `5`, `1` | `5`, `1` | yes |
| `describe` | `describe(9)`, `describe(10)` | `small`, `large` | `small`, `large` | yes |
| (process) | `C = spawn(counter(new_tally())), C ! {add, 2}, C ! {add, 5}, C ! {get, self()}: received {tally, Total, Adds, Mean}, Total` | `7` | `ends its actor (integer division by zero)` | stub |
| (process) | `C = spawn(counter(new_tally())), C ! {add, 2}, C ! {add, 5}, C ! {get, self()}: received {tally, Total, Adds, Mean}, Adds` | `2` | `nothing is received: the counter ends in average/1, a failing stub, before it answers` | stub |
| (process) | `C = spawn(counter(new_tally())), C ! {add, 2}, C ! {add, 5}, C ! {get, self()}: received {tally, Total, Adds, Mean}, Mean` | `3.5` | `nothing is received: the counter ends in average/1, a failing stub, before it answers` | stub |
| (process) | `then C ! stop: the value the process ends with` | `ok` | `nothing comes back` | stub |
| `average` | `average(#tally{total = 7, adds = 2})`, `average(new_tally())` | `3.5`, `0.0` | `ends its actor (integer division by zero)` | stub |
| `supervisor` | `supervisor(self(), 0)` | `DOES NOT RETURN in 1500 ms` | `ends its actor (integer division by zero)` | stub |
| (process) | `counter(new_tally()) called as an ordinary function` | `DOES NOT RETURN in 1500 ms` | `ends its actor (integer division by zero)` | stub |
| `main() run as the program` | the 3 lines it prints | `total 7 after 2 adds, mean 3.5: small`, `total 36 after 3 adds, mean 12.0: large`, `the counter stopped; restarts: 0` | `ends its actor (integer division by zero) (the entry process ended)` | stub |
| `main` | `main()` | `0` | `ends its actor (integer division by zero)` | stub |

One **sink** gap decides this unit: `average/1` has the clause `average(#tally{adds = 0})`, a record pattern
with a literal field, which is not written. `counter/1` calls it, so the counter takes `{add, N}` and ends in the
stub when it is asked `{get, From}`: nothing is received, and the `stop` that follows reaches nobody.
`supervisor/2`: `process_flag` (**sender / contract**). `main/0`: a receive that is not in tail position
(**sink**). `ask/1` is not exported. Erlang `demo.erl`, run again with the evening's driver against this build:
37 of 40 calls give Erlang's value, as before (`lookup/1` and `uses_untyped/1` are stubs, `untyped/1` is not
written).

### What was changed for it

- **Sink, printer** (`src/ts_print.silica.in`, `message_ex`, `symbol_alt`): a `(:symbol)` message whose hint
  states a whole sum that has the symbol (a typed language's message type: Gleam's `Reset` of
  `Add(Int) | Reset`) was refused with `T4002`; it is now sent as every symbol is. Contract T9.12 says so now;
  trial `p4_processes`, `blow/1`; run in `sendnil.gleam` (`maybe/2`).
- **Gleam sender**: `process.send` is the contract's send, hinted with the message's type, followed by `nil` in
  a block where its value is used (contract H22). `actors.add/3` no longer gets `T3103`.
- **Elixir sender**: a type test in a guard that only states its variable's type is not sent (contract T8.16);
  the receive arms lost their `case (true and true) of`.
- **Erlang sender**: one test added, no change.
- The senders' suites against this build (from scratch copies): Erlang `test/run_test.sh 7472` 104 tests, 0
  failed; Elixir `TO_SILICA_PORT=7472 mix test` 80 passed; Gleam `test/run_test.sh 7472` 52 passed.

Not run: anything on Linux; the examples on the `(:backing)` store; a process that fails and is started again
by the unit's supervisor (after a counter had ended in a stub its reference was dead: a cast to it ended the
caster; whether it was started again was not looked at); the Erlang `demo.erl` stubs `supervise/1` and
`shout/1`, and every function that is not exported. The floats `13.333333333333334` and `3.14159` are printed by
Silica as `13.333333333333333` and `3.141589999999999` (`print_float64` writes at most 15 decimal places, cut and not rounded); they were compared as
numbers to 12 digits, not bit by bit.

## What was run, and what it showed (2026-11-13 evening, Apple Silicon, compiler 999916): the process nodes

`silica-sink/trials/run_trials.sh <work-dir> 7462 all` from the sources as they stand (default build: one compiler
run for each store, 2 regions, trial hooks on): **"all trials passed"**, 156 passing lines, no failing line, exit
status 0, 13 min 33 s in all. `p0_check_mode` 20 of 20, goldens 23 of 23, `p2_actors` 23 of 23 on both stores, `p1_export`,
`p3_types` 32 of 32 and its generated unit, the kill and restart, the orderly end: as in the section below.

- **`p4_processes` (new): 27 of 27, then two generated units run.** Hand-built frames (no sender), a hello with a
  pool of 8 child ids.
  - Session 1, the unit `erl_procs`, 21 forms. Written with no diagnostic: a process function with a loop, tuple
    and symbol messages, a guard, a send and a failure with a reason (`echo/0`); a spawn by `(:fun_ref)` with the
    unit's own module and by `(:lambda)`; `self`; a receive with a timeout from a literal (`ask/1`, whose result
    type `integer | timeout` the printer cannot write and need not) and from a variable (`wait/1`); a message
    built from variables; a function that does not receive, spawned (`twice/1`, `add/2`); a send whose value is
    used; an exit request with the reasons `kill` and `normal`. Written with the warning `T4004`: a process function that goes on in another one (`relay/1`). Not
    written, each a failing stub with its diagnostic at the node's line and column: a linked spawn, a `(:link)`,
    an `(:exit_signal)` whose reason is not a symbol, a receive that is not in tail position, a receive clause
    that takes any message, a message that is not a symbol or tagged tuple (`T4002`), a message pattern with no
    stated type (`T3101`, severity `error`), a send whose value is stated as another type than the message
    (`T3103`, severity `error`: contract H22). An ordinary function that calls a process function under whose name
    no stub stands (`use_ask/1`) is made a failing stub when the unit is complete: one `T4002` on the unit. One
    `T2001` names the choices not followed. Result `partial`, one file, `counts.gaps` 9.
  - The exported `erl_procs.silica`, compiled with `trials/p4_processes/call_procs.silica.in` (a hand-written
    actor that starts the processes, casts them messages and prints what comes back), linked and run, printed
    what `trials/p4_processes/expected.txt` says: the echo answers `{said, 6}` and `{said, 0}`; `ask(41)` ends
    with 42; `wait(100)` ends with `late`; `twice(21)` as a process ends with 42; `relay` goes on in `forward`,
    which passes the message on; **ten more processes one after the other in a pool of 8 ids** (the ids are used
    again); `notify(E)` answers `stop`; `kill(W)` ends a `wait(300)` before its timeout (no value comes back),
    and `spare(V)`, the reason `normal`, leaves another one alone (it ends with `late`); and the echo that is told
    to fail ends with `(:explicit, :kaboom)` in the failure report.
  - Session 2, the unit `erl_entry`: `server/0`, an entry function named `main` that spawns it, asks it and
    receives `{res, 42}`, and the `(:entry)` form. Result `ok`, no gap. The exported unit, compiled alone, is a
    program: it ends by itself with status 0 (it would wait for ever without the answer).

### The Erlang demo, run

`erlang-to-silica-poc/examples/demo.erl`, sent by the Erlang sender (from the repository) in transpile mode to the
default build of the trials (`<work-dir>/memory`): 35 frames, none rejected, result `partial`, `counts.gaps` 7,
diagnostics 4 `T4001`, 1 `T4002`, 1 `T2001`. The exported `erl_demo.silica` (about 80 KB in 1589 lines, of which the 1024 child
ids are 32 KB) was compiled with compiler 999916 together with a hand-written driver (a `main` that calls every
ordinary function and prints, and an actor that starts the process functions, casts them messages and prints what
comes back), Silica's `Supervisor` unit and a prelude unit, linked and run. The same calls were run in Erlang
(`erlc`, `erl`) against the real `demo.erl`. Floats are compared as numbers.

| Function | Call | Erlang | Silica | Match |
| --- | --- | --- | --- | --- |
| `add/2` | `add(2, 3)` | `5` | `5` | yes |
| `scale/2` | `scale(2.5, 4)` | `15.0` | `15.0` | yes |
| `ratio/2` | `ratio(7, 2)` | `3.5` | `3.5` | yes |
| `half/1` | `half(5.0)` | `2.5` | `2.5` | yes |
| `whole/1` | `whole(2.6)` | `7` | `7` | yes |
| `same/2` | `same(1, 1.0)`, `same(1, 2.5)` | `true`, `false` | `true`, `false` | yes |
| `swap/1` | `swap({7, true})` | `{true, 7}` | `(true, 7)` | yes |
| `origin/0` | `origin()` | `#point{x = 0, y = 0}` | `{ x: 0, y: 0 }` | yes |
| `move/3` (written as `move__`) | `move(#point{x = 1, y = 2}, 3, 4)` | x 4, y 6 | x 4, y 6 | yes |
| `x_of/1` | `x_of(#point{x = 9, y = 1})` | `9` | `9` | yes |
| `classify/1` | `classify(-5)`, `classify(0)`, `classify(3)` | `negative`, `zero`, `positive` | the same | yes |
| `area/1` | `{square, 3.0}`, `{rectangle, 2.0, 5.0}`, `{circle, 1.0}` | `9.0`, `10.0`, `3.14159` | `9.0`, `10.0`, `3.141589999999999` | yes (the same float64; `print_float64` writes at most 15 decimal places, cut and not rounded: limitation observed) |
| `describe/1` | `describe(0)`, `describe(5)` | `zero`, `not zero` | the same | yes |
| `max_of/2` | `max_of(3, 9)`, `max_of(9, 3)` | `9`, `9` | `9`, `9` | yes |
| `sum_list/1` | `sum_list([1, 2, 3])` | `6` | `6` | yes |
| `total/1`, `total/2` (`total__1`, `total__2`) | `total([1, 2, 3])`, `total([1, 2, 3], 10)` | `6`, `16` | `6`, `16` | yes |
| `greeting/0` | `greeting()` | `"hello, world"` (104 101 108 108 111 44 32 119 111 114 108 100) | the same twelve codes | yes |
| `first_x/1` | `first_x(#point{x = 3, y = 4})` | `{3, #point{x = 3, y = 4}}` | `(3, { x: 3, y: 4 })` | yes |
| `apply_twice/2` | `apply_twice(fun(X) -> X + 1 end, 5)` | `7` | `7` (with a Silica function `inc`) | yes |
| `start_counter/0`, `counter/1` | `C = start_counter(), C ! {add, 5}, C ! {add, 37}, C ! {get, self()}` | receives `{total, 42}` | receives `(:total, 42)` | yes |
| `pong_loop/0` | `P = spawn(pong_loop), P ! {ping, self(), 41}`, then `P ! stop` | receives `{pong, 42}`; the process ends with `ok` | receives `(:pong, 42)`; the process ends with `ok` | yes |
| `ping_pong/1` | `ping_pong(41)` | `42` | the process ends with `42` (`ping_pong__spawn_watched(41, self())`) | yes |
| `counter/1` | `counter(10)`, then `{add, 1}`, `{add, 2}`, `stop` | `13` | the process ends with `13` | yes |
| `supervise/1` | not called | (traps exits) | **failing stub**: the sender's gap (`process_flag/2` has no node; with it the receive of `{'EXIT', …}` has no type) | sender / contract |
| `shout/1` | not called | (calls another node) | **failing stub**: the sender's gap (inter-node, outside the proofs of concept) | by rule |
| `lookup/1` | `lookup(a)` | `false` | **failing stub** (`T4002`): a call to `maps:is_key/2`, a module outside the session | contract (T9.9) |
| `untyped/1` | `untyped(1)` | `2` | **not written**: no `-spec`, so no signature | sender (deliberate example) |
| `uses_untyped/1` | `uses_untyped(1)` | `4` | **failing stub**: it binds the result of `untyped/1`, which has no type. Called from a second driver, the program ended there with `badarith`, exit status 1 | sender (deliberate example) |

37 calls of 24 functions give the Erlang value; 5 functions are stubs or not written, none of them for a reason
in the sink's printing of processes. What differs from Erlang in **how** the process functions are called: a
process function cannot be called as an ordinary function from Silica (`erl_demo@ping_pong(41)` does not exist;
`pong_loop()` and `counter(10)` are failing stubs), because only an actor can receive. The driver starts each as a
process with `<name>__spawn_watched(arguments, self())` and gets the value the process ends with as a message. In
Erlang the caller's own process runs the function. Inside the unit the Erlang shape is kept: `ping_pong/1` spawns
`pong_loop/0`, sends it `{ping, self(), N}`, waits for `{pong, M}` with the 1000 ms timeout and sends `stop`.

The other examples, sent by their own senders (from scratch copies of the repository's directories) to the same
build, each unit compiled alone (not linked, not run):

| Source | Result | `counts.gaps` (before) | Ordinary functions in full / process functions / failing stubs | Compiles? |
| --- | --- | --- | --- | --- |
| Erlang `demo.erl` | `partial` | 7 (15) | 21 / 3 / 4 | yes, and runs (above) |
| Erlang `actors.erl` | `partial` | 4 (8) | 3 / 2 / 3 | yes |
| Elixir `demo.ex` | `partial` | 10 (17) | 20 / 3 / 5 | yes |
| Elixir `actors.ex` | `partial` | 4 (10) | 6 / 1 / 4 | yes |
| Gleam `demo.gleam` | `partial` | 14 (16) | 20 / 0 / 7 | yes |
| Gleam `actors.gleam` | `partial` | 11 (12) | 5 / 0 / 4 | yes |

Diagnostics: no `T31xx` for five of them; Gleam `actors.gleam` got one `T3103` (`add/3`: its `(:send)` stood
where `Nil` is the function's value, and contract H22 says a send's value is the message). **Fixed in the Gleam
sender the same night** (the section above): `counts.gaps` 10, no `T31xx`.
`../APP_GAPS.md`, "Status after the process nodes", has every remaining gap with its side. The Erlang sender's
own suite against the same build: `test/run_test.sh 7462` (from a scratch copy of its directory): 103 tests, 0 failed. The Elixir and Gleam senders were not changed; their suites
against the same build: Elixir `TO_SILICA_PORT=7462 mix test` 78 passed, Gleam `test/run_test.sh 7462` 51 passed.

Not run: anything on Linux; the five other example units as linked programs (**run the same night**: the
section above); a process that fails and is
restarted by the unit's supervisor (the `kaboom` echo is restarted lazily and never gets a message again); a pool
that runs out of ids; an exit request in a pool of 1024 ids (it asks the supervisor for each id); two units with processes in one session; a session in the `:silica` profile with process
nodes (the printer ignores the profile); `p4_processes` on the `(:backing)` store.

## What was run, and what it showed (2026-11-13, Apple Silicon, compiler 999916): the types decision

`silica-sink/trials/run_trials.sh <work-dir> 7442 all`, which builds both stores itself (one compiler run each,
2 regions, trial hooks on), from the sources as they stand: **"all trials passed"**, 127 passing lines, no failing
line, exit status 0, 12 min 57 s in all.

- **`p0_check_mode`: 20 of 20. Goldens: 23 of 23** (with the new `ok_types_stated`).
- **`p2_actors`, `(:memory)` store: 23 of 23**, as described under "Earlier" below, the two transpile-actor
  cases included (they failed with 999916 until the replay window was made one record: "Compiler 999916").
- **`p1_export`.** The exported `erl_demo.silica` compiles with a caller, links and prints `5` for `add(2, 3)`.
- **`p3_types` (new): 32 of 32, then the generated unit runs.** One session of 28 forms (contract §8.6):
  - written with no diagnostic: `to_float` on each operand of `/`; a binding whose `(:var)` is hinted; a call hinted
    as an operand; a declared record type and a declared type with an argument (`(:type)` forms sent first); a
    list taken apart by `[]` and `[H | T]` and a list built from elements; `round`, `trunc`; the sender's own guard
    on a float division with `(:fail)`; a `t_actor` parameter; a comparison with `to_float` on the integer side;
  - not written, each with its diagnostic at the node's file, line and column: float times integer and integer
    less than float with no conversion (`T3102`); a binding and a call operand with no stated type, and a function
    with no signature hint (`T3101`); `/` on integers, an integer literal where a float is stated, `to_float` on a
    float (`T3103`); a declared type nobody declared, one declared later in the unit, one with the wrong number of
    arguments (`T3104`); a declared type that names itself (`T4002`);
  - the result is `partial`, one file, `counts.gaps` 12; the T31xx diagnostics have severity `error`;
  - the exported `erl_types.silica`, compiled with `trials/p3_types/call_types.silica`, linked and run, printed
    what `trials/p3_types/expected.txt` says (`mean(7, 2)` `3.5`, `sum(three())` `6`, `rnd(2.5)` `3`,
    `tr(-3.99)` `-3`, `safe_div(7.0, 2.0)` `3.5`, …).
- **`p2_actors`, `(:backing)` store: 23 of 23**, then **kill -9 and a new start on the same backing files**: both
  regions recovered (one finished session, one unfinished), resumed and released. **Orderly end:** exit status 0.
- **The three applications' examples**, sent by their own senders (from the repository) in transpile mode to a
  build of these sources (four-run build, 4 regions; made before the last change, which reworded one diagnostic),
  exported, each unit compiled alone with compiler 999916:

| Source | Result | `counts.gaps` | T31xx | Functions written in full / as stubs | Compiles? |
| --- | --- | --- | --- | --- | --- |
| Erlang `demo.erl` | `partial` | 15 | 0 | 16 / 9 | yes |
| Erlang `actors.erl` | `partial` | 8 | 0 | 2 / 5 | yes |
| Elixir `demo.ex` | `partial` | 17 | 0 | 16 / 9 | yes (was no: E2003) |
| Elixir `actors.ex` | `partial` | 10 | 0 | 3 / 7 | yes (was no: E2003) |
| Gleam `demo.gleam` | `partial` | 16 | 0 | 18 / 8 | yes (was no: E2005) |
| Gleam `actors.gleam` | `partial` | 12 | 0 | 5 / 3 | yes |

  No frame was rejected and no sender was told of a missing or inconsistent type. `erl_demo.silica` was linked with
  a hand-written caller and run: ten calls printed the values Erlang gives (`scale(2.5, 4)` `15.0`, `ratio(7, 2)`
  `3.5`, `total__1([1, 2, 3])` `6`, …) and `ratio(7, 0)` ended the program with `badarith`, as the sender's guard
  asks. Every remaining gap, with the side it belongs to, is in `../APP_GAPS.md`, "Status after the types
  decision". The senders' own suites against the same build: Erlang 101 tests, 0 failed; Elixir 78 passed; Gleam
  51 passed.

Not run: anything on Linux; a store owner, port or listener made to fail; a region filled up (T5001); a frame near
`max_frame` on `(:backing)`; more than 2 regions or more sessions at once than 2 in the trials; long runs; the five
other example units as linked programs; `p3_types` on the `(:backing)` store; the T31xx checks in check mode (a
check session prints nothing, so it reports none: open, DECISION_DATA_printer.md §6).

### Earlier (2026-11-13, compiler 999919, before the types decision)

`silica-sink/trials/run_trials.sh <work-dir> 7442 all`, which builds both stores itself (2 regions, trial hooks on):

- **Build.** About 100 s with the schema unit cached (the schema unit alone: about 190 s more).
- **`p0_check_mode`: 20 of 20.** As before (the contract's worked example, gaps, every rejection reason built, the
  refusals, credit, framing).
- **Goldens: 22 of 22.**
- **`p2_actors`, `(:memory)` store: 23 of 23.** The worked example transpiles (`(:stored, 4)`, `ok`, one file);
  with both regions held a third session is refused `busy`; release frees a region; **two sessions at once** with
  interleaved frames, in different regions, both end `ok`; a second release and an id that names no region answer
  `freed` false; **40 release connections in a row** (APP_GAPS C1); a differing resume hello is `session_mismatch`,
  an unknown id `unknown_session`; **a dropped session is resumed** (`resume_from` 2, a resent frame is dropped
  silently, `ok`); a finished session resumed answers its result again; **a session actor made to fail** is
  restarted by its supervisor, a check session right after ends `ok`, and its session is resumed and ends `ok`;
  **a transpile actor made to fail once** is restarted and the session ends `ok`; made to fail always, the session
  ends `failed` with T5002 and no file; wrong counts give two T1002 and `partial`; an abort frees its region; 200
  frames under credit give `(:stored, n)` at every half window up to 200, then `ok`.
- **`p1_export`.** The exported `erl_demo.silica` compiles with a caller, links and prints `5` for `add(2, 3)`.
- **`p2_actors`, `(:backing)` store: 23 of 23**, then **kill -9 and a new start on the same backing files**: both
  regions are recovered (one finished session, one unfinished with 40 frames sent); the finished one is resumed and
  answers its result; the unfinished one is resumed with `resume_from` at least the last `(:stored, n)` its sender
  had seen, sent to its end, and ends `ok`; both are released. (The first run of this trial failed: recovery of 217
  records takes 8 s and the trial asked after 2; a resume during recovery is refused `busy`. The trial now waits
  for the two "recovered" lines.)
- **Orderly end:** `exit` on standard input closes every region and the exit status is 0.
- **The three applications' examples**, sent by their own senders in transpile mode to this build, exported, each
  unit compiled alone with the Silica compiler (senders run from scratch copies of their directories):

| Source | Result | Gaps | Functions written | Compiles? |
| --- | --- | --- | --- | --- |
| Erlang `actors.erl` | `partial` | 9 | 1 | yes |
| Erlang `demo.erl` | `partial` | 17 | 4 | no: E2003 line 16 (`scale/2`, float times integer; decision 4) |
| Elixir `actors.ex` | `partial` | 12 | 2 | no: E2003 line 20 (`mean_move/2`, `/` on integers; decision 4) |
| Elixir `demo.ex` | `partial` | 23 | 8 | no: E2003 line 20 (same kind) |
| Gleam `actors.gleam` | `partial` | 28 | 2 (1 a failing stub) | yes |
| Gleam `demo.gleam` | `partial` | 24 | 17 (6 with a failing branch or stub) | no: E2005 line 71, "cannot infer type of case scrutinee" (not looked into) |

  No frame was rejected. Every gap has a diagnostic with the construct, the sender's file and line, and code T4001
  (the sender's gap) or T4002 (the transpiler's). Almost every function of the three `actors` examples is a gap for
  one of: a declared type in its signature (`t_named`), a process reference (`t_actor`), no hint, or the name `main`.

The whole suite as described ended "all trials passed" (93 passing lines, exit status 0) in its last run. The
application examples in the table above were sent to a build made one change earlier (before replays were given a
credit window); they were not sent again.

Not run: anything on Linux; a store owner, port or listener made to fail; a region filled up (T5001); a frame near
`max_frame` on `(:backing)`; more than 2 regions or more sessions at once than 2; long runs (minutes only); the
senders' own test suites against this build.

## APP_GAPS.md, id by id

| Id | State |
| --- | --- |
| C1 release ends the transpiler | **not seen any more**: 40 releases in a row, and every release of the trials. The cause was not found in the old build; the old release path no longer exists. See limitation 7, which may have been the cause |
| C2 process nodes | **(late: a receive with code of the same function after it is the sender's to split, contract T9.13a; the Erlang sender does)** **done for what contract §9.4a lists** (2026-11-13 evening; night: a symbol message hinted with a whole message type): `self`, `spawn` of a function of the unit, `send`, `receive` in tail position with guards and a timeout, `fail` with a reason, `exit_signal` with a symbol reason (the reason is not carried), as supervised actors (design §5.5). Not done: `link`, a linked spawn, a receive with code of the same function after it, selective receive (a message no clause takes is dropped; `T4004` where that can differ from the source), a `register` of a process that is running. **2026-11-14, later:** a static child (`register` of a `spawn` with literal arguments) and `send_named` are written (contract T9.14b, T9.14c) |
| C3 match, block | done. The compromise is gone (2026-11-13): a binding whose type the sender did not state is `T3101`, never printed by repeating its value |
| C4 records, declared types | done for types (2026-11-13): `(:type)` forms are kept across forms and units and `t_named` is written out at each use, with arguments for parameters (contract T8.14). Not done: a declared type that names itself (Silica has no type names: limitation observed). Record patterns and alias patterns (`(:match)` as a pattern): **done** (evening) where they are matched with a whole parameter, case subject or match value and their parts are variables or `_`; a record pattern with a literal field (`#tally{adds = 0}`) is not (late: the Erlang sender sends such a field as a variable and a guard) |
| C5 signature types | mostly (2026-11-13): also `t_list`, `t_actor` (as `actor_ref`), `t_named`, `bytes` (as `string`). Not: `char`, `dynamic` (no untyped representation), a `t_var` in a signature, a union with an alternative that is not a symbol, a tagged tuple or a record (limitation observed) |
| C6 no hint | decided (2026-11-13): a function with no signature hint is the sender's fault, `T3101` (contract T8.10 a); the three senders now send such a function as their own gap with the reason. The untyped representation is still P4 |
| C7 entry | done for an entry function written in the same unit with no parameters, also one named `main` (written as `main__`) and one that is a process function: `main` then starts it as the first process (trial `p4_processes`, session 2). The three applications' `main/0` were gaps themselves (a receive with code after it). **Late: Erlang `actors:main/0` is sent split by its sender, is written, and the program prints what Erlang prints.** Elixir and Gleam: unchanged |
| C8 gap functions as failing stubs | done when the signature can be printed; otherwise still a comment. A function of the unit that calls a function the unit does not have (nothing of it was written, or it is a process function with no stub) is now made a failing stub itself when the unit is complete, with a `T4002` on the unit (Elixir `withdraw_from/2`, `report/1`), so the unit compiles |
| C9 numeric mixing | **done by decision** (2026-11-13, DECISION_DATA_printer.md §6): the sender sends every conversion (`to_float`, `trunc`, `round`); the printer prints them as helper functions and reports mixed operands as `T3102`, never converting. None of the six example units fails to compile any more |
| C10 tuple patterns, case on any expression | done (record patterns not) |
| C11 failing catch-all | done |
| C12 lambda, apply, fun_ref, module calls | partly, as before: a call through a function-typed parameter and a local `fun_ref` print; lambdas and module calls do not. Late: output needs no module call any more: a sender lowers its language's printing to `(:sl_call)` of the print builtins (contract T9.16), which is printed |
| C13 `<>` | done |
| C14 place in diagnostics | done |
| C15 diagnostics name the construct | done |
| C16 the sender's gap reason | done (T4001 with its construct and note) |
| C17 `failed` with a file | done: a unit of which nothing was written gives no file (T4003); `failed` means `files` 0 |
| C18 gaps counted two ways | done: contract T6.8a; transpile gaps minus the number of T4002 diagnostics is the check session's number |
| C19 session ids | done: `<region>:<store record number>` (design §4.2). The debug exporter still keys on the id alone, and a `(:memory)` store starts its numbers again at each start, so ids repeat across restarts there |
| C20 float exponent, C21 int64 extremes, C23 control characters in text | done |
| C22 keyword-named functions | **done** (evening, contract T9.11): a function named like a Silica reserved word or builtin, or `main`, is written with `__` appended, in its definition, calls and references (`move__/3` in the three demos, `main__/0`). The senders' own rule is injective and safe for several arities (`total__1`, `total__2`) and never ends a name in a bare `__` |
| C24 nothing said at the end | partly: a region, the listener or a supervisor going down writes a line to standard error before the exit; a fault of the runtime itself still writes only the runtime's line |

## Compiler 999916 (2026-11-13)

Everything is now built and tried with `../silica/binaries/silica-999916-macos-applesilicon` (`build.sh`,
`run_trials.sh`, the examples). What changed against 999919, measured:

| Question | Result |
| --- | --- |
| Do the schema unit and the transpiler's own units compile in **one** compiler run? | **Yes.** One process, exit 0: 343 s, 2.5 GB resident at most (with `ts_prelude`; 347 s and 2.2 GB without). With 999919 the same run ended with `out_of_memory`. `build.sh` now does one run by default |
| Is `ts_prelude` still needed? | **Yes** (limitation observed). Compiled in one run **without** it, the program links and starts, and each store owner then ends at its first message with `language_error: no case arm matched`, so the trials fail (19 of 20 `p0` cases). With it, the same sources pass. Not understood further; it was built to make four runs agree on atom and shape numbers |
| Are the interface-only copies (`src/stubs`) still needed? | No. They were removed on 2026-11-17 together with `TS_FAST=1`: an application is one compilation unit, and no build compiles parts apart and links their objects |
| Schema unit compile time | unchanged: about 200 s of the build (a four-run build took 5 min 38 s without the cache and 2 min 12 s with it) |
| The limits below, re-tested one by one with both compilers (scratch `w3_limits/`) | **None changed.** Same messages and same output for items 2, 4, 5 (4 fields), 6, 8, 9, 10, 12 and for DECISION_DATA_printer.md §1.1 to §1.4, §3.2 (ten words), §3.4. Not re-tested: 3, 11 |
| Item 5, "8 elements in a decoded tuple" | did not reproduce with either compiler: tuples of 9 to 16 elements compiled, and 9- and 10-element tuples decoded and printed |
| Item 7, the helper that returns `(:no_reply, state)` | the `out_of_memory` did not reproduce with either compiler in eight new variants. What was observed instead, with both: after such a helper the next dispatch reads a wrong state (a counter printed `6094827408`); with the tuple written in the behaviour the state is right. The rule the sources follow is unchanged |
| A transpile actor that fails | **changed in effect.** With 999919 the trials "a transpile actor that fails once / always" passed; with 999916 the same sources failed them: the store owner ended with `actor_not_found` and the transpiler with it. Cause: the owner replayed a window of records, and a cast to the failed (ended) actor ends the caster (limitation 10); which side won was timing. Fixed in `ts_region` (`window`): one record of a replay is on its way at a time. Both trials pass again |

New limitations observed while printing (both compilers):

- **A list pattern inside a tuple pattern compiles and takes the wrong arm.** `case (l, n) of { ([]: L, _: int64) -> …; ([h: int64, t: L], _: int64) -> … }` took the `[]` arm for a list of three (scratch `w3/x3`: printed `0`, the same function matching the list alone printed `6`). The printer therefore narrows a multi-subject case to the subjects some clause takes apart (so `total([H | T], Acc)` is a case on the list alone) and refuses a list pattern beside another pattern (T4002).
- A `sequence … end` cannot be a case arm (E1057); in a block it can. Every list expression is printed as a sequence in a block.
- Integer `+`, `-`, `*` past `int64` wrap with no failure (`9223372036854775807 * 4` printed `-4`); `checked_int64_add` and `checked_int64_mul` exist and answer `(false, 0)` on overflow. The printer does not use them: overflow is the sender's language's business (contract T8.15).
- An argument of a call into another unit that is an arithmetic expression of float literals, or a record literal, is taken as `float32` (E2003 against a `float64` parameter); bound to a typed name first it is accepted. Met in the trials' hand-written callers only.
- The exit status of a program is the value `main` returns (a `main` that returns an atom exits with 2).

## Limitations observed while printing processes (compiler 999916, 2026-11-13 evening)

Scratch programs, each one question. None of this was reported or changed in Silica.

- **The units of a program do not agree on atom numbers by themselves.** A tagged tuple written in one unit and
  matched in another took the wrong `case` arm or none (`case_clause`), depending on the order in which each unit
  first names its atoms; the same program behind a unit that names every atom first (`tools/prelude.py`) is right.
  This is limitation 1's "the prelude is still needed with one run", met again in a program of two units. So a
  generated unit and a hand-written caller are compiled behind a prelude unit (the trials and the demo do).
  `prelude.py` itself missed record shapes in a unit whose string literals hold `//`; fixed.
- A call into another unit with a tuple literal as argument where a sum is expected is refused (E2003, the
  argument is taken as `(atom, int64)`); and the alternatives of a sum must be written in the callee's order.
- `send_after` takes `uint64` milliseconds; `to_uint64` converts.
- `call_supervisor` needs no effect: a sequence that declares `concurrency` for it alone is refused (E3010).
- Walking the list that `:which_children` answers (`case rows of { []: … ; [r: {…}, t: …] -> … }`) faulted in
  the spawner (a memory fault in the running program). An exit request therefore finds a process's child id by
  asking `:get_child` for each id of the pool.
- `:get_child` for an id that no row holds answers `:child_info` with a row whose id is another atom (index 0),
  not `:error`. `:remove_child` ends a live child, and answers `removed` whether or not a row was there. A
  `:transient` child that ended normally keeps its row (and its id) until the row is removed.
- A `{ sequence … }` block that stands directly as an argument of a call compiles and faults when the program
  runs (`greeting/0`: `to_silica_append_int64({ sequence … }, { sequence … })`); bound to a name first it is right.
  The printer binds list arguments and the operands of `++`.
- A helper that walks a `List[sum of tagged tuples, mem(normal)]` with an accumulator answered a garbage number
  for the empty list, and a list of messages kept in an actor's state came back empty at the next message. Not
  followed further; it is why no save queue for selective receive is written (design §5.5).
- A binding or a parameter may not be named `link`, `unit` or `rec` (reserved); `head` is accepted.
- `print_float64` writes the whole part and at most 15 decimal places, cut and not rounded (corrected 2026-11-14: this line said "16
  significant digits"): the float64 nearest 3.14159 prints as `3.141589999999999`.
- The exit report of a child that called `fail_self(reason)` carries `(:explicit, reason)`; a child spec has no
  stack policy, so BEES A3.2 cannot be followed for a supervised child.
- (night) **A sum with two alternatives of one tag** (`(:reply, (:ok, int64)) | (:reply, (:refused, int64)) |
  (:reply, (string, int64, float64))`) is accepted by the compiler. A `case` over it in a program of one function
  took the first two alternatives rightly and bound a wrong value in the third (`6089159424` for `3`); in an
  actor whose message type is such a sum the arrival of a `(:reply, …)` message ended the program with a memory
  fault. Contract T9.12 asks for one type for a tag; nothing checks it.
- (night) `(:restarts, k: int64) <- r` (a binding that takes a one-alternative tagged tuple apart) is refused
  (E2005, "case pattern does not match scrutinee type"); a `case r of { (:restarts, k: int64) -> k }` is
  accepted. Met in a hand-written driver only.
- (night) A cast to a process of a generated unit that has ended ends the caster (item 10 below, met again in a
  driver); `send_after(0, ref, message)` to it does nothing.

## Silica limits met (measured, compiler 999919, Apple Silicon; re-tested with 999916, see above)

1. **Compiler memory (999919; gone with 999916, see above).** One compiler process compiles every unit of `silica.config` and ended with
   `(:explicit, :out_of_memory)` in its `type_surface_cache` actor when the schema unit and the transpiler's units
   were compiled together (2026-11-12), and again with the transpiler's own units alone once the actors were
   written (2026-11-13: a root unit of 151 KB of spelled-out source; then any run holding the printer, the checks
   and the actors). `build.sh` compiles in four runs against interface-only copies; `tools/prelude.py` makes the
   runs' atom and shape tables equal, and the script fails if they are not. Measured on the way: atoms and shapes
   are numbered per run in order of first meeting, atoms in expressions before atoms in types; the derived
   decoders and the supervisor runtime bring atoms no source names (listed by hand in `prelude.py`).
2. **Decoder fault** (2026-11-12): a list mixing bare atoms and tagged tuples that hold lists; the schema has
   `(:t_basic, kind)` because of it.
3. **An unexplained `case_clause`** in a program of three large literals (2026-11-12); not met again.
4. `export` cannot be a binding or field name; `==` between a sum of tagged tuples and an atom fails in the
   assembler. A function may not be named like a builtin and called unqualified (`poke`: E2020).
5. At most 4 fields in a decoded record and 8 elements in a decoded tuple; no type aliases; no integer-to-text
   builtin; effects are per sequence; no null `dangerous_actor_ref` (an idle actor holds an empty list of them).
6. **Supervisors.** A supervisor's child list refuses a behaviour whose message type holds a bare atom beside
   tuples (E2003), so every message is a tagged tuple. A child list has one type, so the root's four kinds of
   child supervisor are added with `:add_child`. A child supervisor in another unit must be that unit's own
   `impl <unit name> for Supervisor` (otherwise the link fails on `_silica_supervisor_start_<unit>`). `monitor`
   delivers nothing (Silica's own open trial), so exits are learned from the report sink.
7. **A helper that returns the behaviour's `(:no_reply, state)`.** When a helper function built and returned that
   tuple and the behaviour passed it on, the actor ended with `(:explicit, :out_of_memory)` at the end of a
   dispatch whose new state held new strings, supervised or not, under every stack policy tried. With the tuple
   written in the behaviour and the helper returning only the state, it does not. Found by trying eight variants
   in one build; not understood further. The old build's session actor had this shape in two places, which may be
   what APP_GAPS C1 was.
8. **Dangerous units.** `dangerous_actor_ref` may appear only in a unit named `dangerous_` (E4026), and no function
   of such a unit may be called from another unit (E4042); its functions can be named as behaviours. Hence the
   region port: the store carrier's reference stays in one small unit and the owner's logic needs no dangerous type.
9. `spawn_dangerous_carrier` is not parsed as a `case` arm (E1069): one function per region.
10. **A cast to an ended actor ends the sender.** `send_after(0, ref, message)` does not (tried): the warden uses it.
    A restarted owner of a carrier cannot get the old carrier back (no reference survives a restart), which is why
    the port, the listener and a session's connection are handled as described above.
11. **Replay speed on `(:backing)`:** about 30 ms a record (217 records recovered in 8 s), with a credit window of
    32 as with one credit a record. On `(:memory)` a 200-frame session takes about 25 s to transpile.
12. The runtime prints `[silica] root actor exited (no supervisor)` each time a connection's carrier ends; noise.

## Decisions taken while building that the design or contract did not make

- Counts: contract T5.3b (a wrong count is a T1002 diagnostic, not a rejection; rejected forms count).
- `counts.gaps` in transpile mode: contract T6.8a. Diagnostic codes T4001 (sender's gap), T4002 (transpiler's),
  T4003 (a unit with no file), T5002 (transpiling gave up).
- Credit in transpile mode: `(:stored, n)` then `(:credit, 32)` each half window, after the store's sync (T6.3).
- Resume: T6.5a, T6.5b. A resume while the region is still recovering after a start is refused `busy`.
- An unfinished session whose sender never returns holds its region for ever (contract T6.6 is still open).
- The transpiler's own records carry schema number 101, stored frames 1; there is no `(:frame, …)` wrapper and the
  `(:session, …)` record holds the id only (the hello follows as a frame); `started_at` is 0 (no clock is read).
  Added records: `(:ended, …)`, `(:released, …)`.
- Session actors and transpile actors are fixed pools of permanent children, not one child per connection or session.
- One more actor per region than the design has (the port), for limitation 8.
- **Processes (2026-11-13 evening; design §5.5, contract §9.4a, T7.5, T8.16, T9.11 to T9.15).** One lowering,
  whatever the profile and with no BEES unit: one actor shape and one supervisor for a unit; the spawner as the
  one owner of the child ids; a process's result reported to a watcher (`<f>__spawn_watched`), which is how a
  Silica caller gets what an Erlang caller gets as the function's value; restart limits of 100 in 10 seconds for
  the unit's supervisor (the contract's choices have no parameter for it); the entry process ends the program
  with status 0 whatever its reason. Diagnostic codes `T4004` (written, with a warning) and `T2001` (a choice not
  followed); a `T4002` on a unit counts one gap however many functions it names. A function that calls a
  function of which nothing was written becomes a failing stub at the end of the unit. Function names that
  Silica reserves get `__` appended (a variant of S1 of DECISION_DATA_printer.md §3.6).
- **A static supervisor (2026-11-14, by the user's direction; contract T9.14b, T9.14c, design §5.5).** Taken
  while building it: the static children of a unit are rows of the one supervisor the unit has (no second
  supervisor); a static child's name is its child id; the `(:register)` node, where it is reached, casts the
  child its start message and has the value `true`; the row of a static child that has ended stays; of the
  overrides only `a4_4` on that `(:spawn)` is read, its `restart` followed, its `strategy` reported when it is
  not the session's; literal arguments are integers, floats, symbols and booleans.
- **Language semantics (2026-11-13, late, by the user's direction): the sender lowers them, the sink prints.**
  Contract §1, T9.13a, T9.16. Taken while building it: the type of an `(:sl_call)` of a builtin and of its
  argument is the builtin's own (no hint needed); the call is written through a helper so that it can stand in
  any expression; the unit of a builtin is the empty binary; an ordinary call of a process function that only
  dead code makes is not reported (a `T4002` on the unit counted as a gap, so a fully working split program
  came back `partial`); the print builtins are the whole allow-list (no `send_after`, no BEES unit).
- **Types (2026-11-13, by the user's decision): the sender decides every type** (contract §8.6, T8.8 to T8.15).
  Diagnostic codes T3101 to T3104. `(:type)` forms must precede their use (T8.14), which is what lets the
  transpile actor keep the declared types in one pass. A `(:fail)` is printed as the failing expression and its
  reason is not carried. A byte string is printed as a Silica string. A replay hands on one record at a time.

## Commands

```sh
silica-sink/build.sh /path/to/build 7411                    # (:memory) store, 4 regions, 8 session actors; one compiler run, about 6 minutes
TS_STORE=backing TS_STORE_DIR=/var/lib/to-silica silica-sink/build.sh /path/to/build 7411
/path/to/build/dangerous_to_silica < /dev/null              # listens on 127.0.0.1:7411 until killed
silica-sink/trials/run_trials.sh /path/to/work 7442 all     # builds and runs everything; about 25 minutes
# a generated unit with processes and its caller: Silica's Supervisor unit, and a prelude unit first
python3 silica-sink/tools/prelude.py --all ts_prelude.silica Supervisor.silica erl_demo.silica caller.silica
printf 'ts_prelude.silica\nSupervisor.silica\nerl_demo.silica\ncaller.silica\n' > silica.config
python3 tools/export_debug_output.py <transpiler stdout log> <session id> <directory>
```
