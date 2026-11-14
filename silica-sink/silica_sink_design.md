# The to-silica transpiler: a Silica application from TCP transport to Silica source

**Status: design, 2026-11-13. Phases P0, P1 and most of P2 are built, with a first printer that also writes
processes as Silica actors (§5.5, §9; what exists and what was measured is in [STATUS.md](STATUS.md)). Paragraphs headed "As built" say where the build differs.** This document controls the transpiler: the Silica application that
receives a language's Silica data over TCP, keeps it in local storage, and writes Silica source and the BEES files from
it. What a sender puts on the wire is fixed by [the TCP transport contract](../contract/tcp-transport-v1.md) (cited as
"contract T5.1", "contract H23" and so on); this document says what the transpiler does with it.

**Related.** The Silica transport design, `../silica/compiler/design_documents/transport_serialization_design.md`
(cited as "transport §6.2"): the transpiler is built from its pieces, the `(:tcp)` carrier, `wireframe`, the derived
`encode`/`decode` and the `(:store)` storage carrier. The BEES target contract,
`../project-bees/contract/so-you-want-to-write-a-compiler.md` (cited as "BEES A3.3"): the transpiler's output must
meet it, and the transpiler together with a language's sender is one BEES language-to-Silica compiler.

---

## 0. Summary

```
 sender (language-owned)        transpiler (this design)
 ═══ TCP, contract frames ═══►  listener (:tcp) ─► session actor ─► decode + validate ─► encode (canonical)
                                                        │                                     │
                                                        │  credit, stored, rejected            ▼
                                                        ◄────────────────── store owner ─► (:store) (:backing, ….sildat)
                                                                                                │ replay
                                                                                                ▼
                                                                  transpile actor: resolve ─► hints ─► lower
                                                                      ─► BEES mechanics ─► print ─► output records
                                                                                                │ into the same region
 driver (outside Silica) ◄══ reads the .sildat, exports files ══════════════════════════════════╛
        ══ TCP (:release, session) ══► the region is trimmed and freed
```

Six decisions shape it:

1. **Language decisions are the sender's, mechanical work is the transpiler's** (contract §1). The transpiler never
   chooses a lowering a sender did not choose; it applies the session's choices and overrides (contract §7).
2. **A layered vocabulary** (contract §9.4, §9.5). High-level nodes are lowered by a library of lowerings, one per BEES
   choice; low-level nodes are already Silica-shaped and pass through the same mechanical passes.
3. **Session defaults with per-node overrides**, for choices (contract §7.2, §7.3) and for hint policy (contract §8.3,
   §8.4).
4. **Type hints are optional and never stop a translation** (contract §8). Each hint has a strength and a policy;
   a hint that cannot be honoured falls back to an untyped representation with a note.
5. **Storage between receiving and transpiling.** Everything a sender sends is validated, then made durable in a
   Silica store before it is transpiled. A sender can resume after a dropped connection, a transpiler that restarts
   finds its work again, and memory use stays bounded however large the program is.
6. **Local persistence is the transpiler's only way to keep or produce data** (decided 2026-11-12). The transpiler
   uses none of Silica's file builtins. Its output (Silica units, manifests, the lowering-choices file) is written as
   records into the session's store region; the driver, outside Silica, exports them as files (§6.6). The only
   conversion between Silica's transport and ordinary files is at that edge, where the Silica compiler needs files.
   Senders are checked over TCP in check mode (contract §6.5), so no sender writes Silica's storage format either.

---

## 1. Requirements

1. Accept the contract's sessions on 127.0.0.1, any number in sequence and a bounded number at once.
2. Treat every received byte as untrusted. The derived `decode` with declared limits is the only path from the wire to
   a value (transport §4.5), and the contract's own checks (indices, units, choices) run on the decoded value.
3. Make each accepted frame durable before acknowledging it (contract T6.4), and resume sessions (contract T6.5).
4. Keep memory bounded by the largest unit, not by the size of the session.
5. Produce, for each session, Silica units, the BEES manifests, the lowering-choices file and the platform's choice
   record, kept durably in local storage until released, such that once exported the result builds with the Silica
   compiler and BEES and meets the BEES contract.
6. Be deterministic: the same stored session always produces the same files, byte for byte.
7. Report every rejection, gap, fallback and failure to the sender with a location in the sender's source.

## 2. Principles

1. **The transpiler is a Silica program built only from Silica's transport.** Receiving is the `(:tcp)` carrier
   contract of transport §6.2, framing is `wireframe`, validation is `decode`, storage is the `(:store)` carrier of
   transport §6.8, and output is storage too. The transpiler adds sessions and transpiling on top; it does not add a
   transport of its own, and it reads and writes no file directly.
2. **One validation point.** A frame becomes a value only through `decode` inside a `sequence … produces pure … end`
   block (BEES A8.2, B1b), and is checked against the contract before anything acts on it.
3. **What is stored is canonical.** The transpiler stores `encode((:etf), value)` of the decoded value, never the
   received bytes, so the store holds no external-danger-touched byte (transport §6.8.10) and two equal sessions store
   equal records.
4. **Lowerings are a library, chosen by data.** Every high-level node is lowered by the lowering its effective choice
   names. Adding a choice is adding a lowering; nothing else changes.
5. **Mechanical rules are applied once, to everything.** The BEES rules of contract §1 run after lowering, on
   lowered high-level code and on low-level code alike.
6. **Fail the unit, not the session.** A rejected frame, a gap or an unimplemented choice affects the forms it touches;
   the rest of the session is still written (`status` `:partial`, contract T6.8).

---

## 3. Actors and supervision

The application's root unit is named `dangerous_to_silica`: it starts `(:tcp)` carriers and `(:backing)` store carriers,
both dangerous actors, so it carries the prefix (transport §6.8.10; Silica E4021). Every actor runs under a supervisor
(BEES A4.1 is not binding on the transpiler, which is not BEES output, but it follows the same discipline).

```
root supervisor
├── listener owner          owns the (:tcp) listener, "listen:<port>" (127.0.0.1)
├── session supervisor      one child per live connection
│   └── session actor       owns one connection carrier (contract §6)
├── store pool supervisor   one child per declared store region
│   └── store owner         owns one (:store) (:backing, …) carrier; leased to one session at a time
└── transpile supervisor    one child per session being transpiled
    └── transpile actor     replays a session from its region and appends the output to it
```

**As built (2026-11-13).** Every actor is a supervised, static, `:permanent` child addressed by its child id:

```
main ── reporter, warden (the supervisors' report sink); neither can be supervised
 └─ :ts_root, one_for_one
     ├─ :ts_port_sup       :ts_port_<r>       owns region r's store carrier (see §3.3)
     ├─ :ts_store_sup      :ts_store_<r>      store owner
     ├─ :ts_transpile_sup  :ts_transpile_<r>  transpile actor, one per region, idle between sessions
     ├─ :ts_session_sup    :ts_session_<i>    a pool of session actors, idle between connections
     └─ :ts_listener_sup   :ts_listener       listener owner
```

- **Pools, not one child per connection.** A child id is an atom literal and a duplicate id ends whoever adds it, so
  the session actors are a fixed pool (default 8): the listener owner hands an accepted connection to one, a busy
  one passes it on, and a connection none can take is closed. The transpile actors are one per region.
- **Restarts.** A restarted actor does nothing until a message reaches it, so the warden sends each restarted child
  `(:boot, 0)`. What each then does is in STATUS.md ("The actors as built"). A child supervisor that ends, a port
  that is restarted, and a listener that cannot bind end the transpiler; a `(:backing)` region is recovered at the
  next start (§4.3).
- **Messages** are casts by name and are listed at the head of `src/dangerous_to_silica.silica.in`.

### 3.1 Listener owner

Opens the `(:tcp)` carrier with `"listen:<port>"`, which binds 127.0.0.1 only (transport §6.3). For each
`(:accepted, conn, info)` it starts a session actor and hands it `conn`; the session actor adopts the connection with
`(:open, self, "")` (transport §6.2, listeners). The port is a literal in the transpiler's configuration unit
(**provisional** 7411, contract T3.1).

### 3.2 Session actor

One per connection. It owns the connection carrier and speaks the contract.

- **Receiving.** Each `(:rx, segment)` goes through `wireframe@unframe` with `max_frame` (transport §5). Each whole frame
  is decoded by the schema unit's own `tcp_transport_v1@decode_to_transpiler` (`contract/tcp_transport_v1.silica`),
  in a `sequence … produces pure` block. The transpiler uses the schema unit as it is, so what it accepts is exactly
  what the contract defines. Its limits are compile-time literals, `{ max_bytes: 1048576, max_depth: 16,
  max_length: 65536 }`; a session granted a smaller `max_frame` is held to it by `wireframe@unframe`. Node tables are
  flat (contract T9.1), so the depth limit is small and fixed. Compiling the schema unit takes about three minutes on
  the Apple Silicon compiler (measured 2026-11-12), almost all of it the derived decoder for forms.
  **As built:** the compiler runs out of memory (at about 4 GB) when the schema unit and the transpiler's own units
  are compiled in one process, so `silica-sink/build.sh` compiles the schema unit in a run of its own and the other
  units against an interface-only copy of it, and links the real one (§10, question 12). The decoded value is taken
  apart in one unit only (`ts_intake`, which reduces a frame to a small digest), because every spelling of the frame
  type costs compiler memory; the session logic (`ts_session`) works on digests.
- **Checking.** The decoded value is checked against the contract: sequence (T5.1), unit order (T5.3), unit names
  (T5.2), indices below their parent (T9.2), choices and overrides (§7), profile (§7.4), low-level rules (T9.8), hints
  (§8.4). The first failure gives `(:rejected, { seq, reason, where })`.
- **Storing.** An accepted frame is re-encoded (§2.3), wrapped by `wireframe@record((:etf), <contract version>, frame)`
  (transport §6.8.3) and sent to the session's store owner. A rejected frame is stored too, as a rejection record
  `(:rejected_frame, { seq, reason, where })`, so the transpile actor and a resumed session see the same history.
- **Credit.** The session actor gives the sender credit (contract R3) only as its store owner reports `:tx_credit`, and
  gives the TCP carrier receive credit (transport §6.2) only for frames it can store. Memory held per session is
  therefore the store's write-behind buffer plus one frame.
- **Durability.** When the store owner reports `(:synced, next)`, the session actor converts the store's record number
  to the session's `seq` (§4.2) and sends `(:stored, next)` (contract T6.4). It asks for a `:sync` after every 64
  records, when the sender's credit runs out, and on `(:end)`. **As built:** a sync each half window (32 frames) and
  on `(:end)`; the session actor names the `seq` in its request, and the half window of credit is granted only with
  the owner's answer (contract T6.3).
- **End.** After `(:end)` is stored, it starts a transpile actor for the session, relays its progress, diagnostics and
  result to the sender (contract R6 to R8), and stops. **As built:** the store owner starts the region's transpile
  actor and relays; the session actor becomes idle when its connection closes; `(:progress, …)` is not sent.
- **Check mode** (contract §6.5). A hello with `options.run.mode` `:check` gets no store lease: the session actor
  decodes and checks every frame as above, answers credit and rejections, stores nothing, and after `(:end)` sends the
  check result (contract T6.11). Its credit is a fixed window (**provisional** 64), since no store paces it.
- **Release** (contract §6.6). A connection whose first frame is `(:release, { session })` is handled by the session
  actor without a hello: if the session is finished (its region ends with `(:transpiled, …)`), it asks the region's
  store owner to trim the whole session, answers `(:released, { session, freed: true })` once the trim is durable
  (the store's `:log`), and closes; otherwise it answers `freed: false`.
- **Link failure.** On `(:link_down, reason)` the session actor sends nothing more to that carrier (a cast to an ended
  carrier ends the sender, transport §6.2, "the hazard"), returns its store lease, and stops. The session stays
  resumable in the store.

### 3.3 Store owners and regions

A store region is declared at compile time, one declaration per region, and a region has one owner at a time
(transport §6.8.1, §6.8.2). The transpiler therefore declares a **fixed pool of regions**, and the number of sessions
it serves at once is the pool's size:

```silica
carried_on intake_0: (:store) (:backing, "/var/lib/to-silica/intake_0.sildat", 268435456, :trim);
carried_on intake_1: (:store) (:backing, "/var/lib/to-silica/intake_1.sildat", 268435456, :trim);
// … one line per region; the pool size and paths are the configuration unit's (provisional: 4 regions of 256 MiB)
```

- **`:trim` retention** makes each region a durable queue (transport §6.8.5): a session's records, input and output
  alike, are released with `(:trim, upto)` when the session is released (contract §6.6) or aborted.
- **One region holds a whole session**: its intake records, then its output records (§4.1). Capacity must cover both;
  a session that fills its region fails with T5001 and `status` `:failed`. **Provisional:** 256 MiB per region.
- A new session takes a free region (one whose `:log` reports `oldest == next` once trimmed). With none free the hello
  is refused `:busy` (contract T5.6).
- A region holds records of one session at a time. **Open:** whether to interleave several sessions in one region,
  which would need a session tag in every record and a trim that waits for the slowest session.
- The paths are literals: changing where the transpiler keeps its data is a rebuild (**open**, §10).
- The store owners keep their carriers until told to `:close`, as store carriers require today (transport §6.2,
  as built).

**As built.** The pool is spelled out by `tools/expand.py` (`TS_STORE` `memory` or `backing`, `TS_REGIONS` default 4,
`TS_CAPACITY` default 8 MiB for memory and 64 MiB for backing, `TS_STORE_DIR`). A new session asks owner 0 and a busy
owner passes the request on. Each region has a **port** actor that owns the carrier and carries the owner's commands
and the carrier's events: a `(:backing)` carrier's reference may appear only in a `dangerous_` unit, whose functions
no other unit may call (Silica E4026, E4042), so the owner's logic lives in plain units and never holds the
reference. A restarted owner has its port close the carrier and open a new one. A replay gives the store a window
of receive credit (32 for recovery, 8 when another actor is fed).

### 3.4 Transpile actor

One per finished session. It replays the session's region with `(:read, from)` under receive credit (transport §6.8.2),
**one unit at a time**: it reads a unit's records, transpiles the unit (§6), appends its output records to the same
region, and only then reads the next unit. Its memory is the largest unit's forms plus the session-wide tables of
§6.1. One actor both replays and appends: the store allows appending during a replay, and a replay ends at the `next`
that held when it began (transport §6.8.2), so the output it appends is never replayed into itself. Output records
are written to the store owner, which owns the carrier.

A transpile actor that fails is restarted by its supervisor and starts again from the session's first record. Output
records from the failed attempt stay in the region; each attempt begins with an `(:output_begin, { attempt })` record,
and the exporter takes only the last complete attempt (§6.6).

**As built.** The store owner replays to the transpile actor (it owns the region) and appends what the actor hands
back. After 3 attempts the session ends `failed` with T5002. The pass over `:type` and `:entry` forms before the
first unit (§6.1) is not built.

---

## 4. Local storage

### 4.1 Records

Every record in a region is one `wireframe@record((:etf), 1, encode((:etf), value))`, where `value` is one of:

| Record | Written when |
| --- | --- |
| `(:session, { id, hello, started_at })` | the first record of a session: its id and the accepted hello |
| `(:frame, { seq, message })` | an accepted M2 to M5 (contract §5.1), decoded and re-encoded |
| `(:rejected_frame, { seq, reason, where })` | a rejected frame (contract R5) |
| `(:aborted, { reason })` | an `(:abort)` (contract M6) |
| `(:output_begin, { attempt })` | a transpile attempt starts writing output (§3.4) |
| `(:output_file, { path, content })` | one output file: `path` relative to the session's output directory, `content` its bytes (§6.5) |
| `(:transpiled, { result })` | the output is complete and synced; the result as sent to the sender (contract R8). The exporter exports only up to this record |

A value larger than the store's record size (4064 bytes, transport §6.8.9) is cut into records by `wireframe`'s
`:storage` mode and put back on replay (transport §6.8.3); the transpiler does not see the cut.

**As built.** A stored contract frame is the re-encoded frame itself under `wireframe@record` schema number 1; the
transpiler's own records carry schema number 101, so a replay tells them apart without decoding twice. There is no
`(:frame, …)` wrapper; `(:session, { id, started_at })` holds the id (`started_at` is 0) and the hello follows as a
frame, stored with an empty `session` field so that a resuming hello compares equal (contract T5.4). Two records
were added: `(:ended, { rejected, frames, miscounts })` when the `(:end)` is stored, and `(:released, { id })` before
a release's trim, so that recovery can tell every state of a region from its records alone.

### 4.2 Session ids and numbering

- The session id is the region's name and the store sequence number of the session's `(:session, …)` record, as text
  (`"intake_2:1873"`): unique for as long as the region exists, and found again after a restart by scanning the region.
- The session's `seq` for each record is kept beside the store's own record number. A `(:synced, next)` from the store
  becomes the sender's `(:stored, n)` with `n` the `seq` after the last durable frame record.

### 4.3 Recovery

On start, every store owner opens its region, and its `:log` says what is there. A region whose last record is
`(:transpiled, …)` holds a finished session waiting to be exported and released (contract §6.6); it stays leased to
that session. One ending in `(:aborted, …)` is trimmed. Any other holds an unfinished session: it is kept for a resume
(contract T6.5) or, if its `(:end)` is stored, handed to a transpile actor, which starts a new attempt (§3.4).
**Open:** how long an unfinished session is kept (contract T6.6).

**As built.** After the open's `:log` the owner replays the region from `oldest` and follows its own records: the last
`(:session, …)` not followed by `(:aborted, …)` or `(:released, …)` is the region's session; `(:ended, …)` without
`(:transpiled, …)` starts a new transpile attempt; a free region with records left by the block-wise trim is trimmed
again. A resume replays the session's records to the session actor, which rebuilds the session's state by stepping
through them (stored rejections included), so resume works alike after a dropped connection and after a restart.
Tried on `(:backing)` with a kill and a restart (STATUS.md). An unfinished session is kept until it is resumed.

---

## 5. Lowering

### 5.1 Effective choice

For each high-level node, and for each BEES requirement its construct uses (contract §9.4, column **R**), the effective
choice is the form's override for that node and requirement if there is one, otherwise the session default
(contract §7.2, §7.3). The transpile actor computes it once per node and keeps it in the unit's table.

### 5.2 The lowering library

One Silica module per requirement, one function per choice, each turning a high-level node and its children into
low-level nodes. **Provisional** first release:

| Requirement | Choices implemented first | Later |
| --- | --- | --- |
| A3.2 stack reserve | `lowered`, `default` | |
| A3.3 suspension points | `phase_field` (BEES reference lowering of C01, C02) | `continuation_table` |
| A3.4 yield points | `back_edge`, `none` | `budget_counter` |
| A4.2 child ids | `single_pool`, `pool_tree` (from `bees_config` pools) | |
| A4.3 supervisor shape | `uniform_shape` | `one_per_shape` |
| A4.4 restart and strategy | `chosen` | |
| A5.1 recoverable errors | `result_values`, `rejected` | `result_variants`, `mixed` |
| A5.4 send to a dead recipient | `accept_sender_death`, `proxy` | `liveness_check` |
| A5.5 links and exit requests | `supervisor_request`, `not_supported` | `silica_link` |
| A6.8 byte and bit operations | `lookup_tables` | |
| A7.1 dynamic dispatch | `module_table` (BEES `bees_modules`) | `own_dispatch` |

The BEES reference lowerings (BEES `trials/s09_reference_lowerings`, `trials/a02_ring`, `trials/a02_exit_listener`) are
the starting point for each, so that C01 to C08 pass from the first release (BEES A10). A choice not yet implemented
gives T2001 and turns each node that uses it into a gap (contract T7.5).

**As built (2026-11-13): there is no lowering library yet. The printer writes processes in one way, §5.5**, which
is the first-release column for A3.3 (`phase_field`, for a receive in tail position), A4.2 (`single_pool`), A4.3
(`uniform_shape`), A4.4 (`chosen`), A5.4 (`accept_sender_death`) and, for exit requests, A5.5
(`supervisor_request`; a link is not written under either choice). A3.4 writes no yield point, and A3.2 reaches
only the runtime's own actors. A session whose hello chooses otherwise
gets one T2001 diagnostic for each unit with processes that names the choices not followed (contract T7.5).

### 5.3 Phases of a lowering

Some lowerings change the shape of a whole function, not just a node: A3.3 splits a function at each `receive` into
phase functions; A3.4 adds yield points; A5.1 threads a result value through every caller. The library therefore works
on whole functions, in this order: A5.1 (results change signatures), A3.3 (splits), A3.4 (yields inside the splits),
then the node-local lowerings (A5.4, A5.5, A6.8, A7.1, A3.2, A4.x).

### 5.4 Low-level nodes

Low-level nodes (contract §9.5) pass through lowering unchanged. The units and builtins L1 may name are an allow-list
in the transpiler: the BEES units of BEES Part B and the Silica builtins `send_after`, `cancel_timer`,
`monotonic_time`, `current_time`, `fail_self`, `stop_self` (through L4) and the list operations. A name outside the list
is `:low_level` at receipt (contract T9.8). No `dangerous_` unit is on it (contract T9.9).

**As built (2026-11-13, contract T9.16):** the printer writes one low-level node, `(:sl_call)` of a Silica builtin
that prints, with an empty `unit`: `print`, `println`, `print_int64`, `print_float64`, `print_boolean`, and
`atom_name` (a symbol's name as text, so that a symbol can be printed). The call's type and its argument's are the
builtin's own (`ts_print@builtin_result`, `builtin_param`); an argument with no stated type is `T3101`, one of
another type `T3103`. A print builtin needs the `device_io` effect, so the call is written as
`to_silica_b_<name>(argument)`, a helper function `unit_rest` writes into the unit once (`helpers_for`), and may
stand wherever an expression may. This is what a sender lowers its language's output to (the Erlang sender sends
`io:format` with a literal format as these calls). Every other name, a BEES unit, and L2 to L7 are `T4002`. The
`:low_level` check at receipt is not built.

### 5.5 Processes, as built (2026-11-13)

What `ts_print` writes for the process nodes (contract H20 to H26, §9.4a). It uses no BEES unit: values are typed
Silica values, as everywhere in the first printer. The Silica is in `silica-sink/src/process_runtime.silica.tmpl`
(the runtime written at the end of every unit that has processes) and in what the printer writes for each form;
`silica-sink/trials/p4_processes` has one function for each case, and the generated unit is compiled and run.

**What this section does not hold, by decision (2026-11-13): any source language's semantics.** The printer has one
shape for a receive (tail position) and prints it; splitting a function at a receive, deciding what a waiting
process keeps, lowering a link or a trapped exit, formatting output: the sender does these before it sends
(contract §1 "What you own", T9.13a, T9.16), as it decides every type (contract §8.6). When the printer cannot
print a node it says which construct, where, and what the sender must send instead.

**One actor shape for a unit.** Every process of a unit is a Silica actor with the one behaviour
`to_silica_actor(msg: M, state: S) -> (:no_reply, S)` (BEES A3.1 cast-only, A4.3 uniform shape):

- `M` is the sum of every message the unit's processes send or receive: one tagged tuple for each tag
  (`(:ping, actor_ref, int64)`), `(:to_silica_sym, atom)` for a message that is a bare symbol (a supervisor's
  child list refuses a message type that holds a bare atom beside tuples: limitation observed), and the
  runtime's own `(:to_silica_go, …)` (start), `(:to_silica_timeout, wait number)` and
  `(:to_silica_result_<type>, value)`.
- `S` is `{ ph: P, k: { wait: int64, up: actor_ref } }`. `P` is the sum of the unit's **phases** (BEES A3.3
  `phase_field`): `(:to_silica_s_<f>_<n>, arguments)` for a process that is to start in `f/n`,
  `(:to_silica_w_<f>_<n>_<node>, live variables)` for a process waiting in the receive at that node of `f/n`, and
  the fixed `done`, `failed`, `nomatch`, `unstarted`. `k.wait` numbers the process's timed waits; `k.up` is the
  actor its result is reported to (none for a process the program spawned).

**A process function** (a function with a `(:receive)`) is printed in *tail mode*: every expression in tail
position gives the next `S` instead of a value.

| Source | Silica |
| --- | --- |
| the body up to the first receive | `to_silica_e_<f>_<n>(p0, …, k) -> S` |
| a receive in tail position | the function ends with the waiting phase, holding every variable that is live; its clauses are `to_silica_r_<f>_<n>_<node>(msg, a0, …, k) -> S`: one `case msg of` arm for each clause (a guard is a Silica `if` guard when it uses a variable of the message, otherwise it is tested inside the arm), an arm for the timeout, and a last arm that answers `nomatch` |
| a timeout `after T` | the waiting phase is entered with `k.wait + 1`, and `send_after(T, self(), (:to_silica_timeout, k.wait + 1))` (BEES A3.7); the timeout arm takes only the message that carries the current wait's number, so a stale timeout does nothing |
| a tail call of the function itself | `to_silica_e_<f>_<n>(arguments, k)`, in the same dispatch: the process is in its next receive when the dispatch ends |
| a tail call of another function of the unit | `to_silica_e_<g>_<m>(arguments, k)` when the unit has it (the function receives, or has a tail call of its own); otherwise the function is called and the process ends with its value. Which, is known only when the unit is complete, so the printer leaves a mark and `unit_rest` writes it |
| a value in tail position | the process ends: `to_silica_result_<type>(k.up, value)` when the value's type is `int64`, `float64`, `boolean`, `atom` or `string`, then the phase `done`; the behaviour then calls `stop_self(:normal)` (BEES A5.2: only a behaviour may) |
| `(:fail, symbol)` in tail position | the phase `(:to_silica_failed, :symbol)`; the behaviour calls `fail_self(symbol)`, so the reason is carried |
| `(:self)` | `to_silica_self()` |
| `(:send, to, message)` | `to_silica_send(to, message)`: Silica's `cast` (BEES A5.4 `accept_sender_death`: a send to a process that has ended ends the sender). A symbol is sent as `(:to_silica_sym, symbol)`, also a `(:symbol)` whose hint states a whole sum that has the symbol (a typed language's message type, contract T9.12; trial `p4_processes`, `blow/1`). A tuple whose hint states a sum is the alternative of its tag and size. **Not checked:** two types for one tag in a unit (contract T9.12) are written as two alternatives of `M`; the unit compiles, and a `case` over `M` then takes a wrong value or faults when such a message arrives (limitation observed, STATUS.md, "The examples, run") |
| `(:spawn, fun, args)` | `to_silica_spawn((:to_silica_s_<f>_<n>, arguments))`, a call of the unit's spawner |
| `(:register, name, (:spawn, fun, literal args))` | a **static child** (contract T9.14b, 2026-11-14): the marker line `//@to_silica static<TAB>name<TAB>restart<TAB>phase value`, from which `unit_rest` writes a row of the child list that the supervisor's `init` answers (`{ id: :name, …, initial_state: { ph: (:to_silica_s_<f>_<n>, args), k: … }, behavior: to_silica_actor, restart: :restart, … }`); where the node stands, `to_silica_static(:name)`, which casts the child its start message by its name and answers `true`. `restart` is the `a4_4` override on the `(:spawn)` node (the one override the printer reads), or else the session's |
| `(:send_named, name, message)` | `to_silica_send_named(:name, message)`: Silica's `cast_registered` (contract T9.14c). The message is printed as a `(:send)`'s is |
| `(:exit_signal, to, symbol)` | under `a5_5 supervisor_request`: nothing for the reason `normal`; otherwise `to_silica_exit(to)`, a call of the spawner, which finds the child id of the process (it asks the supervisor for each id of the pool in turn: walking the list that `:which_children` answers faulted, limitation observed) and has the supervisor remove the child, which ends it and frees its id. The reason is not carried (BEES A5.5, open) |

`to_silica_dispatch(msg, ph, k)` has one arm for each phase; `unit_rest` writes it from the marker lines the forms
leave (`//@to_silica …`, which stay in the output as comments).

**Supervision (BEES A4).** The processes of a unit are the children of one supervisor, `<unit>_sup`
(`impl <unit> for Supervisor`, strategy and restart policy from the hello's `a4_4`), added with `:add_child` by the
**spawner**, a call-only actor registered as `<unit>_spawner`, which is the one owner of the pool of child ids
`<unit>_p0 …` (`a4_2 single_pool`, the hello's `pool_size`, 1024 when none; BEES A4.2). A spawn is a
`call_registered` to it, so it answers with the new process, which has been cast its start message. An id is free
when no row holds it (`:get_child`); the supervisor's report sink (the **warden**) removes the row of a child that
ended and was not restarted, which frees the id. With every id held the spawner ends with `id_pool_exhausted`.
A child that ends with a failure is started again by the supervisor from its first phase (unless `temporary`); it
runs to its first receive when its first message arrives.

**Static children (contract T9.14b; decided 2026-11-14).** The unit's supervisor is also the supervisor of the
unit's static children: the rows `init` answers, so they exist from `spawn_registered_supervisor` on, with the
sender's name as child id (Silica registers a child under its id, and the name follows a restarted child). No
second supervisor is written for a source's own supervisor: a Silica unit is one `impl <unit> for Supervisor` (one
`init`), and the children of a second one, in another unit, could not exchange messages with the unit's
processes (one message sum for a unit). So the source supervisor's strategy can only be the unit's (an override
that states another gets a `// to-silica: CHOICE` line, which the unit's `T2001` carries), and its restart
intensity is not carried. A static child's row is not removed by the warden when the child has ended
(`to_silica_is_static`): the list stays as it was written. The printer knows nothing of any language's
supervisor: it prints a `(:register)` of a `(:spawn)` with literal arguments, and the sender decides which
source construct that is (the Erlang sender: `erlang-to-silica-poc/src/e2s_sup.erl`).

**The entry point and the outside.** With an `(:entry)` form `unit_rest` writes `main` (contract T9.6): a failure
reporter, `to_silica_boot()`, the entry function as the child `<unit>_entry`, `wait_for_exit()`; the warden casts
the exit when that child ends. For a unit that is a library the exports are, for each function `f` that can run as
a process, `f__spawn(args)` and `f__spawn_watched(args, up)` (the value the process ends with is sent to `up` as
`(:to_silica_result_<type>, value)`), and `to_silica_start()`, which a hand-written `main` calls once after it has
registered its failure reporter. A hand-written Silica actor talks to the unit's processes by casting tagged
tuples of `M` and taking `M` as its message type. **Limitation observed:** the units of a program agree on atom
numbers only when one unit, compiled first, names every atom (`silica-sink/tools/prelude.py` writes it); without
it a tagged tuple cast from one unit is not the same message in another.

**What is not Erlang's behaviour, or not written.**

| What | State |
| --- | --- |
| selective receive | **a message no clause of the waiting receive takes is dropped.** A save queue (BEES `bees_recv`, reference lowering 1) is not written: a list of `M` in the actor's state did not hold its elements in a first attempt (a helper that walked a `List[sum of tagged tuples]` answered garbage: limitation observed, not followed further). For a function with one receive that only loops or ends this is the same behaviour; otherwise the function gets the warning `T4004` |
| a receive that is not in tail position | not written (`T4002`), and **not to be built here: the sender splits the function** (contract T9.13a, decided 2026-11-13: what runs before and after a receive is the source language's business, as every type is). The diagnostic says so and names the receive's place. The sender sends the code after the receive as a function of its own and ends each clause with a tail call of it, which is the shape above: a tail call of another function of the unit, in the same dispatch. The Erlang sender does it (`erlang-to-silica-poc/src/e2s_split.erl`); `p4_processes` has the split form by hand (`mid2/0`, `mid2__k1/1`) |
| the state of a waiting process | every variable bound where the receive stands is kept in the waiting phase, used or not (the printer does no liveness analysis). A sender that wants less sends the receive as the whole body of a function whose parameters are the variables it uses (contract T9.13a). **Limitation observed (2026-11-13, not followed further):** the entry process of `actors.erl`, ending from a waiting phase of five kept values `(float64, int64, int64, (int64, int64, float64), actor_ref)` of which the receive used none, ended the program with a memory fault (`silica_rt_message_measure`, exit status 70) after it had printed everything; with only the used variables kept the same program ends with status 0 |
| an ordinary call of a process function | compiles (a failing stub stands under the function's name) and fails when it is reached; `unit_rest` reports it when the unit holds such a call. Not reported: a call that stands only in the ordinary version of a function that is not exported and that nothing calls as an ordinary function (`only_dead_calls`). Such a function is a piece of a split process (contract T9.13a): it has a tail call, so it is written twice, and only its tail-mode version is ever reached |
| a call of a function the unit does not have as an ordinary function (nothing of it was written; or a process function whose result type cannot be written, which has no stub) | the caller is made a failing stub when the unit is complete (`fix_missing`), with a `T4002` on the unit, so the unit compiles |
| a `(:register)` of a process that is running, a static child with a computed argument | not written (`T4002`, contract T9.14b): the child list is fixed when the supervisor starts, and Silica gives a supervised actor its name when it is added |
| a source supervisor as a process (its pid, stopping it, asking for its children) | nothing is written for it: its static children are the unit's supervisor's (contract T9.14b) |
| links, a linked spawn, trapping exits | not written (contract T9.15). An exit request is written (above), without its reason, and costs up to `pool_size` supervisor calls |
| restarts | Erlang does not restart a process that fails; here the hello's `a4_4` decides, and the senders choose `transient` |
| processes in different units of a session | each unit has its own `M`, `P`, supervisor and pool; messages between them are not understood (not checked) |
| the stack policy (A3.2) | a child's specification carries no stack policy (limitation observed): it reaches the supervisor, the spawner and the warden only |
| yield points (A3.4) | none: a function that loops without receiving runs in one dispatch |
| `:get_child` for an id no row holds | answers `:child_info` with a row of another id (limitation observed): the spawner compares the id |
| `:remove_child` | ends a live child and answers `removed` whether or not a row was there (measured): the warden uses it only for a child that has ended |

---

## 6. Transpiling a unit

### 6.1 Session-wide tables

Before the first unit the transpile actor reads the session's `:type` and `:entry` forms and the unit list (one pass
over the region, keeping only names and type tables), so a unit can refer to another unit's types and exports. It
keeps: the units and their Silica names, the exported functions and arities, the named types, and the symbol set
(every `(:symbol, …)` name and every atom the output needs), which becomes `bees_atoms` through the `.atoms` manifests
(BEES A1.2).

**As built (2026-11-13): the named types only, and in one pass.** There is no pass before the first unit. The
contract instead asks the sender to send a `(:type)` form before every form that names it (contract T8.14), so the
transpile actor keeps the declared types as it replays the session: each printed `(:type)` form adds an entry (its
name, its parameters, its Silica type with marks where the parameters stand), and every later form is printed with
the table. Silica has no type names, so a `(:t_named)` is written out at each use with its arguments in place of
the parameters; a type that names itself cannot be written out (`T4002`). The table lasts for the session, so a
later unit may name an earlier unit's type. The units' exported functions and the symbol set are not kept yet: a
call's result type is the sender's to state (contract T8.10 d), so the printer needs no signature table.

### 6.2 Passes

| Pass | What it does |
| --- | --- |
| 1. resolve | names to definitions: local and remote calls, variables to their binding, closures to what they capture (contract H36) |
| 2. hints | the effective policy of each hint; the representation of each value, typed or `bees_term`; the conversions where untyped and typed code meet (§6.3) |
| 3. lower | the lowering library (§5), whole functions first |
| 4. BEES mechanics | the rules of contract §1: prefix, no symbol literals, at most 256 `case` arms, at most 8 parameters, effects, state as a literal, exhaustive branches |
| 5. print | Silica text, deterministic (§6.5) |
| 6. store | the unit, its manifests and a source map, each as an `(:output_file, …)` record (§6.5) |

### 6.3 Hints

**The sender decides every type (contract §8.6; decided 2026-11-13).** The transpiler infers no type and converts
no value on its own. The hints of a form and its type table are the only source of types: a node's type is its hint,
or what contract T8.9 says the node or its place fixes (a literal, a variable's binding, an operator's result, the
function's result for a body). The hints pass is therefore a lookup and a consistency check, never an inference:

- where contract T8.10 requires a type and none is stated, the form is not written and gets `T3101`;
- where the two operands of an arithmetic or comparison operator have different stated types, `T3102`: a numeric
  conversion is an operator the sender writes (`to_float`, `trunc`, `round`, contract T8.12), printed as a call to
  a helper function the printer writes into the unit, because Silica has no builtin for them (limitation observed);
- where the stated typing contradicts itself, `T3103`; a `(:t_named)` with no earlier `(:type)` form, `T3104`.

Division by zero, overflow and equality between kinds are the sender's language's business (contract T8.15): the
transpiler writes the operator the sender sent and nothing around it.

**As built (`ts_print`):** the printer is called with one form and the session's declared types so far (§6.1). It
answers a T31xx code with the construct, the node and the node's place in the sender's source; the transpile
actor sends it as a diagnostic of severity `:error` and writes a failing stub when the signature can be written.
The trial `silica-sink/trials/p3_types` holds one function for each rule.

- **Representation.** A value whose hint is in force (policy `:trust` or `:check`) is emitted in its Silica type
  (contract §8.5); every other value is a `bees_term` in `:bees`, and in `:silica` an untyped value is an error found
  at receipt (contract T7.10).
- **Conversions.** Where untyped code calls a function with a hinted signature, and where a receive clause with a
  hinted message type takes a message, the transpiler emits a conversion from `bees_term` to the type. Under `:check`
  it validates and fails the actor on a mismatch, with reason `bad_hint` and the source location. Under `:trust` it
  converts without the checks. Conversions are emitted only at function entry and message receipt (contract T8.6).
- **Messages.** A message type that is fully typed is listed in a `.wire` manifest as a `message` line (BEES B1, N1) so
  that it travels between nodes through Silica's `encode`/`decode((:etf), …)`.
- **Fallbacks.** The fixed fallbacks of contract T8.7, each with a T3xxx note.

### 6.4 Source maps

Each written unit gets a `<unit>.srcmap`: for each line of the Silica unit, the sender's file, line and column it came
from (from the node's `at`, contract T9.3). A tool can then translate a Silica compiler error into a location in the
sender's source (§6.6).

### 6.5 Printing and writing

- **As built:** the provisional printer `ts_print` prints a form straight from its node table, with no resolve,
  hints, lowering or mechanics pass before it (§6.2 is not built). What needs the whole unit (the types of its
  messages and phases, its process runtime, `main`) is written by `ts_print@unit_rest` when the unit ends (§5.5). A function it cannot print whose signature it can
  is written as a **failing stub** (same name and types; its body divides by zero through a helper, then gives a
  default value), so its callers compile; a function, `case` or `cond` that does not match everything gets a
  failing last branch. A form with no printable signature is a comment. Each has a T4001 (the sender's gap) or
  T4002 (the printer's limit) diagnostic with construct, file and line. A unit of which nothing was written gives no
  file (T4003). With `ts_config@debug_output()` true the store owner also prints each stored output file to
  standard output, which is what `tools/export_debug_output.py` reads.
- **Determinism.** Functions are printed in the order the sender's forms name them within the unit, generated helpers
  after them in name order, names are generated from a counter per unit, and no time or address appears in the output.
- **Numbers.** Silica has no integer-to-text or float-to-text builtin (Silica specification §22, implementation status
  2026-10-16), so the printer writes integers with its own digit conversion over `div`, `rem` and a ten-way lookup.
  Floats arrive as text (contract H2) and are checked against Silica's float literal grammar before they are printed.
- **Output as records.** Each output file becomes one `(:output_file, { path, content })` record appended to the
  session's region (§4.1); a file larger than one store record is cut and rejoined by `wireframe`'s `:storage` mode
  (transport §6.8.3). After the last file the transpile actor sends `:sync`, and on `(:synced, …)` appends
  `(:transpiled, { result })`, syncs again, and only then sends the result (contract T6.8). The transpiler uses no
  file builtin. (Silica's file builtins are also incomplete today: no `write_file`, no directory creation, Silica
  specification §5.2; and a program using `read_lines` did not link outside the compiler's own build, 2026-11-12.)
- **Paths.** `path` is built only from `silica_unit`, which the session actor has checked is an identifier with the
  session's prefix (contract T5.2), and from the fixed names of §6.7. No path from the wire is used as a path.

### 6.6 Building and the driver

The Silica compiler and BEES's tools read ordinary files, and Silica provides no way for a program to run another
program (`exec_command` is not implemented, Silica specification §5.4). So a small **driver** outside the transpiler
turns a finished session's stored output into a directory, builds it and checks it:

```
tools/to_silica_driver   (provisional; a script)
  export <session> <dir>   read the session's region, write its last complete attempt's files into <dir> as a BEES leaf
  release <session>        send (:release, { session }) to the transpiler (contract §6.6)
  build <dir>              make -C <dir> build        (bees_config generate, unit order, compile, link)
  check <dir>              BEES tools/conformance.py and tools/check_lowering_choices.py on the leaf
  explain <dir>            map Silica compiler errors through the .srcmap files to the sender's source
```

**The exporter** reads the region's backing file directly: it is the one place outside Silica that understands the
store's on-medium form. It needs:

- the block and record layout of transport §6.8.9 (4096-byte blocks with a 16-byte header; records with a 16-byte
  envelope of length, sequence number and CRC-32C; big-endian; the read rule at write-unit boundaries), stopping at
  the first record that is not good, exactly as the store's own recovery does;
- `wireframe`'s `:storage` segment headers, to rejoin records into frames, dropping orphaned segments
  (transport §6.8.3);
- `wireframe@record`'s 3-byte header (format id 1 for ETF, the schema version) and a small ETF decoder for the record
  values of §4.1.

Silica's own `make_backings.py` (trials of transport §6.8.10) writes this form independently in Python, which shows the
form is implementable outside Silica from its documentation. The exporter takes the records after the last
`(:output_begin, …)` that is followed by `(:transpiled, …)`, and writes nothing for a session without one.

**Reading while the transpiler runs.** The store holds an exclusive `flock` on an open backing (transport §6.8.2); the
exporter does not take that lock and reads only up to a synced `(:transpiled, …)` record, whose bytes are never
rewritten (transport §6.8.4, a sync pads). **Open:** whether to close and reopen the region around an export instead,
so the exporter can take the lock.

The exported directory is a **BEES leaf** (BEES conformance README: a two-line `Makefile` that includes BEES's
`tools/trial.mk`, the units, a `lib/` of links to the BEES units, and the manifests); the exporter writes the
`Makefile` and `lib/` links itself, since they depend on where BEES is on the machine running the driver.

The contract's result (contract R8) reports transpiling only (contract T6.9). **Open:** a dangerous worker over a Fifi
wrapper of `posix_spawn` that lets the transpiler run the build itself and report it over the connection.

### 6.7 What is stored for a session

Each row is one `(:output_file, …)` record; `path` is the file name shown.

| File | Content |
| --- | --- |
| `<silica_unit>.silica` | one per unit (BEES A1.1) |
| `<silica_unit>.atoms`, `.module`, `.pools`, `.wire` | the BEES manifests the unit needs (BEES A1.2, A1.3, A1.3a, B1) |
| `<silica_unit>.srcmap` | §6.4 |
| `<entry unit>.silica` | `main`: `bees_exit@start()`, the root supervisor, the entry function started under it (BEES A2.1, A2.2; contract T9.6) |
| `lowering-choices` | BEES A9.1, from the session's choices; overrides as comment lines (contract T7.8) |
| `to-silica.choices` | the platform's record: the hint policies, each override with its node and location, each fallback and gap |
| (not stored) `Makefile`, `lib/` | written by the exporter, which knows where BEES is (§6.6) |

---

## 7. Security

- **Loopback only, no authentication** (contract T3.1, T3.2). The transpiler must not be exposed beyond the machine;
  remote and authenticated transpiling waits for BEES TRUST.
- **Untrusted input.** Every frame passes `decode` with limits and the contract's checks before it is used (§3.2). No
  value from the wire becomes a path, a command, or code that runs in the transpiler.
- **No foreign code in the output** (contract T9.9). A generated program contains no `dangerous_` unit of the sender's
  making, so BEES's rule that a person reviews foreign code (BEES section 0) does not arise in version 1.
- **The store is untrusted on the way back** (transport §6.8.3, decision 8): replayed records are decoded again before
  use, though the transpiler wrote them.
- **The exporter writes only inside the directory it is given.** It rejects any `path` that is not a plain file name
  (no separator, no `..`), though the transpiler never writes one (§6.5).
- **Release is unauthenticated** like everything on the port (contract T3.2): anyone who can connect and knows a
  session id can free a finished session's output. Session ids are not secret.

## 8. Diagnostics

Codes the transpiler sends (contract R7). **Provisional** numbering.

| Range | Concern | Examples |
| --- | --- | --- |
| T1xxx | the contract | T1001 frame rejected (repeats R5 for the result), T1002 unit with fewer forms than its `unit_end` says |
| T2xxx | lowering | T2001 choice not implemented, T2002 a construct with no lowering under its choice |
| T3xxx | hints | T3001 integer of unbounded size narrowed to `int64`, T3002 union Silica cannot tell apart, T3003 hint ignored as advisory |
| T31xx | the sender's typing (contract T8.13; severity `:error`; the form is not written) | T3101 a type the contract requires is not stated, T3102 operands of different types and no conversion, T3103 inconsistent typing, T3104 a declared type no earlier `(:type)` form declares |
| T4xxx | gaps | T4001 the sender's gap (a failing stub where a signature is known), T4002 a construct the transpiler does not print yet (on a form, or on a unit for what is seen only when the unit is complete), T4003 a unit of which nothing was written (no file), T4004 a warning with no gap: a process function in which a message may be dropped where the source language keeps it (§5.5) |
| T5xxx | output | T5001 the session's region is full; the output could not be stored, T5002 transpiling was given up after its attempts |

## 9. Phases

| Phase | Delivers | Closes when | State, 2026-11-12 |
| --- | --- | --- | --- |
| P0 | the schema unit `contract/tcp_transport_v1.silica` (compiles today), the contract's goldens (contract §11), and check mode: listener and session actor with no store | a check-mode session of every golden answers each as the golden says | **built**: check mode passes `silica-sink/trials/p0_check_mode` and the 22 goldens; counts (T1002, contract T5.3b) are checked. Not built from §3.2: choice parameters and overrides (`:bad_choice`), low-level rules (`:low_level`), hint positions (T8.5): `DECISION_DATA_unbuilt_p0.md` |
| P1 | the `(:memory)` store; sessions stored and replayed | a session of goldens is stored, acknowledged and replayed on `(:memory)` | **built**: a pool of regions, supervised actors (§3), frames and rejections stored, replayed, output and `(:transpiled, …)` appended, release, two sessions at once. Passes `silica-sink/trials/p2_actors` |
| P2 | `(:backing)` regions, resume, recovery, release; the driver's `export` and `release` | a session resumed after a dropped connection and after a transpiler restart; a stored output exported, then released | **built except the driver**: `(:backing)` regions (`TS_STORE=backing`), resume, recovery after a kill, release, orderly end; tried by `run_trials.sh … all`. The exporter is still the provisional `tools/export_debug_output.py`, which reads the transpiler's debug output, not a store |
| P3 | transpiling in the `:silica` profile: functions, data, matching, calls, hints `:trust` | typed example programs transpile, build and run | **a larger slice**: the provisional printer `ts_print` (its header lists what it prints: typed functions over int, float, boolean, text, symbol, tuple, tagged, union and record types; local variables, tuple patterns, `case` on any expression, failing stubs and catch-alls, a `main` for an entry). It ignores the profile and the hint policy and prints no untyped function. **Process nodes (2026-11-13, later):** `self`, `spawn`, `send`, `receive` in tail position with guards and timeouts, `fail` with a reason and `exit_signal` are written as supervised Silica actors (§5.5); `link` is not; the Erlang `demo.erl` is converted, compiled and run, its processes included (STATUS.md). **2026-11-13:** it follows contract §8.6 (the sender decides every type, §6.3): types come from hints only, declared types are kept across forms (§6.1), lists and the conversion operators are printed, and missing or inconsistent typing is reported (T31xx) |
| P4 | the `:bees` profile and the lowering library of §5.2 | C01 to C08 sent by the test sender pass BEES's conformance kit | not built. What exists of it is the one lowering of processes of §5.5, in typed Silica with no BEES unit |
| P5 | `:check` conversions, typed `.wire` messages, fallbacks | hint trials, including wrong `:declared` hints failing where untyped and typed code meet | not built |
| P6 | the driver's `explain` and source maps | a Silica compile error reported at the sender's source line | not built |

`erlang-to-silica-poc`, `elixir-to-silica-poc` and `gleam-to-silica-poc` (the first language senders, each written in
its own language and owned by its language's people) exist as proofs of concept and are checked against P0's check
mode; they go further with each phase.

## 10. Open questions

1. How long an unfinished session is kept (contract T6.6), and whether sessions may share a region (§3.3).
2. Store paths and pool size are literals; whether Silica gains a way to configure a store's path without a rebuild.
3. Generic functions: specialising per use or falling back to `bees_term` (contract T8.7).
4. OTP behaviours as high-level constructs, after BEES publishes its BEAM supplement (contract §9.2).
5. Running the build from the transpiler (§6.6).
6. Contract minor versions (contract T10.2).
7. How BEES's lowering-choices format will carry per-node overrides (contract T7.8).
8. Term order across types for comparison operators (contract Appendix B).
9. Whether the exporter reads an open backing without its lock or the region is closed around an export (§6.6).
10. Whether finished sessions are released automatically after some time (contract T6.14).
12. **Compiler memory.** The Silica compiler (999919, Apple Silicon) compiles every unit of `silica.config` in one
    process, and that process ended with `out_of_memory` in its `type_surface_cache` actor, at 3.3 to 4.4 GB resident,
    whenever the schema unit (its derived decoder is 820 KB of derived source) and the transpiler's units were
    compiled together, in either order. `silica-sink/build.sh` works around it with two runs that share the
    directory's `silica.atoms` and `silica.shapes` tables. This is a work-around for a compiler limit, not a design:
    it goes away when the compiler's memory does, or when the schema's decoder is cheaper to derive.
    **2026-11-13:** the transpiler's own units pass the same limit; the build now has four runs, interface-only
    copies of the units an earlier run compiled, and a generated prelude unit that makes the runs' atom and shape
    numbers equal (`build.sh`, `tools/prelude.py`).
    **Later on 2026-11-13, compiler 999916:** one process now holds everything (343 s, at most 2.5 GB resident), and
    `build.sh` builds in one run. The prelude unit is still compiled first: without it the one-run program starts
    and its store owners end with `no case arm matched` (limitation observed, not understood; STATUS.md).
13. **A decoder fault that shaped the schema.** Silica's derived `decode((:etf), …)` faults (a memory fault in the
    running program, not a rejection) on a list whose element type mixes bare atoms with tagged tuples that hold
    lists, for example `List[(:a, int64) | :b | :c | (:l, List[int64, mem(normal)]), mem(normal)]` decoding
    `[b, {a, 5}, {l, [1, 2]}]` (measured 2026-11-12 in a program of that one decode). The contract's type table had
    exactly that shape (`:t_bool` and the other fieldless entries beside `(:t_tuple, List[…])`), so a sender could
    stop the transpiler with a valid frame. The schema now has no bare-atom entry: `(:t_basic, kind)` (contract §8.5).
    To report to Silica.
14. **Supervision.** (Built 2026-11-13, §3.) The actors of §3 were started unsupervised in the first build (from `main` and by the listener
    owner). A session actor that casts to a carrier that has just ended dies of `actor_not_found` (transport §6.2,
    "the hazard"); that is contained (it is that connection's actor) but it is not the orderly end §3.2 describes.
15. **Names the printer cannot use.** (Decided for function names 2026-11-13, contract T9.11: a reserved name is
    written with `__` appended; a name that is not an identifier is the sender's to mangle.) Still open: record
    field names that are reserved words, and a check that a mangled name does not meet a name the sender sent.
11. (Closed 2026-11-13.) A program with `(:backing)` carriers links the store sidecar (`libsilica_store.a`, built by
    `build.sh` from Silica's `compiler/stdlib/net/silica_store.c`) and runs: `TS_STORE=backing`.
16. **What the runtime leaves unrecoverable in place.** No reference survives an actor's restart and a cast to an
    ended actor ends the sender, so a restarted owner cannot take back its carrier: a failed session actor leaves
    its connection open and unanswered, and a restarted port or listener ends the transpiler (§3, as built). Each
    goes away with Silica's planned change to casts (transport §6.2, upgrade note).
17. **A session actor's fault is silent to the sender** (its connection stays open). Whether to give session actors
    a second, tiny actor that owns the connection and can close it.
18. **Replay speed** on `(:backing)`: about 30 ms a record (STATUS.md, limitation 11); a large session's recovery,
    resume and transpiling are slow in proportion.
19. (Closed 2026-11-13.) **Type tables across forms** (§6.1): declared types are kept across the forms and units
    of a session, under the ordering rule of contract T8.14.
20. **Who decides types** (closed 2026-11-13 by the user's decision): the sender, always (§6.3, contract §8.6).
    Still open beside it: how names are mangled (`DECISION_DATA_printer.md` §3), and whether check mode should
    also report the T31xx findings (today only a transpile session prints, so only it reports them).

## 11. Repository layout

```
to-silica/
  contract/
    tcp-transport-v1.md          the contract senders implement (behaviour)
    tcp_transport_v1.silica      the normative schema; the transpiler's decoders
    bindings/<language>/         derived, non-normative type bindings
    examples/                    worked examples
    goldens/                     golden sessions: .frames, .expect, goldens.erl
  silica-sink/
    silica_sink_design.md     this document
    STATUS.md                    what is built, what was run, what failed and why
    build.sh                     builds the application (four compiler runs, §10 question 12)
    src/                         the Silica application: *.silica.in are spelled out into the build directory;
                                 ts_text, ts_out, ts_config are plain units; stubs/ are interface-only copies;
                                 process_runtime.silica.tmpl and process_main.silica.tmpl are the Silica the
                                 printer writes into a unit with processes (§5.5)
    tools/expand.py              spells out the contract's types and the pools in the sources, and the two
                                 templates as string literals of the printer
    tools/prelude.py             the unit that makes the compiler runs agree on atoms and shapes; also used for
                                 a generated unit and its caller (§5.5)
    trials/                      run_trials.sh; p0_check_mode, p2_actors, p3_types, p4_processes
  tools/
    export_debug_output.py       provisional exporter of the P1 debug output
    to_silica_driver             export, release, build, check, explain (§6.6; not built)
  erlang-to-silica-poc/          proof-of-concept senders, each written in its own language and owned by that
  elixir-to-silica-poc/          language's people (repository rule: a proof of concept's name ends in -poc)
  gleam-to-silica-poc/
  erlang-to-silica/ …            placeholders for the released versions
```
