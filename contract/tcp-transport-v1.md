# The to-silica TCP transport contract, version 1

**Status: draft, 2026-11-13. Built so far: the schema, check mode (§6.5), transpile mode with storage, resume and
release (§6.3, §6.6) and a first printer that follows §8.6 (the sender decides every type) and prints processes
as §9.4a says, in `silica-sink/` (see `silica-sink/STATUS.md`); the golden sessions (§11); three proof-of-concept
senders pass check mode; the Erlang one splits a function at a receive itself (T9.13a) and its example
application runs as a Silica program; a supervisor with a static child list is sent as static children (T9.14b,
2026-11-14: a rule over nodes the schema already had, no schema change; the Erlang and the Elixir sender send
theirs this way, and both senders' example programs are transpiled with no gap).** A
step-by-step guide for a language's owner is [HOWTO_language_creators.md](../HOWTO_language_creators.md). This is the contract a language creator implements to
have their language transpiled to Silica. It says what a **sender** must put on a TCP connection, and what the
**transpiler** (the Silica application in `silica-sink/`, designed in
[silica_sink_design.md](../silica-sink/silica_sink_design.md)) sends back. Match this contract and the rest is
automatic: the transpiler stores what you send, lowers it, writes the Silica source and the BEES manifests, and
reports the result.

Words used: **must** is a requirement. **may** is your choice. **open** means not decided yet: rely on neither answer.
**provisional** means it is expected to change before version 1 is final.

**Related.** The BEES target contract, `../project-bees/contract/so-you-want-to-write-a-compiler.md` (cited as
"BEES A3.3" and so on): a transpiler in this repository **is** a BEES language-to-Silica compiler, split in two at this
contract. The Silica transport design, `../silica/compiler/design_documents/transport_serialization_design.md` (cited as
"transport §6.2" and so on): the transpiler receives on Silica's `(:tcp)` carrier and validates every frame with
Silica's derived `decode`.

---

## 0. Reading order and authority (written for LLMs)

This contract is written to be consumed by an LLM that generates a sender. Human readability is secondary.

**The contract is these files, in this order of authority:**

| # | File | Authority over |
| --- | --- | --- |
| 1 | `contract/tcp_transport_v1.silica` | the **shape** of every frame: every message, record key, node, type entry and atom. Written in Silica, the one language every participant targets, so it favours no source language. It is a real Silica unit: its functions are the transpiler's decoders, so the schema and the implementation cannot differ. Its header says how each Silica type appears in ETF |
| 2 | `contract/tcp-transport-v1.md` (this file) | **behaviour**: ordering, credit, durability, resume, validation, choices, hint policy, gaps. Rules have ids (T*, H*, L*, M*, R*) |
| 3 | `contract/examples/add_example.erl` | a complete session for a small program, frame by frame (§12). Erlang only because the example program is Erlang |
| 4 | a running transpiler, in **check mode** (§6.5) | the executable check: connect, send your frames exactly as in production, and read the `(:rejected, …)` answers. The transpiler validates with file 1's own decoders |
| guide | `HOWTO_language_creators.md` (repository root) | nothing: a step-by-step guide to writing a sender, derived from files 1 and 2. Where it and this contract differ, this contract is right |
| none | `contract/bindings/<language>/` | **derived, non-normative** translations of file 1 into other languages' type notations, all on equal footing. `bindings/erlang/` has one, with a term checker. A binding that disagrees with file 1 is wrong |

If file 1 and file 2 disagree on a shape, file 1 wins. The tables of this document repeat shapes for explanation;
the schema is normative.

**Generation loop.** Give the generator files 1 to 3 (and the binding for your language, if one exists), generate
the sender, then run it against a transpiler in check mode (§6.5): every frame is validated and answered, nothing
is stored or transpiled. A binding's checker may be used offline as a quicker first pass. Accept the sender only
when a check-mode session ends `:ok` and a transpile-mode session is accepted (§11).

**Silica's limits on shapes** (measured 2026-11-12 on the Apple Silicon compiler; they are why some records nest):
a record decodes only with **at most 4 fields**, and a tuple with **at most 8 elements**. A record field may not be
named `unit` (a Silica type name). The elements of a list must not mix bare atoms with tagged tuples that hold lists
(the derived decoder faults on such a list; this is why the type table has `:t_basic`, §8.5). Any extension of the
schema must keep to these.

- Give the generator this whole document, the schema, the example, the BEES contract, and the golden frames (§11).
- Every requirement has an identifier (**T3.2**, **H23**, **L4** and so on). Generated code and tests should cite them.
- **Do not invent.** A message, node kind, choice or type that this document does not list does not exist. Where a
  requirement says **open**, stop and report it by identifier.
- **The transpiler is the authority on what is valid.** Its rejections (§5.4) name the frame and the reason. When it
  rejects a frame, fix the sender, not the test.
- **Be deterministic.** The same source and the same options must produce the same frames, byte for byte.

## 1. The split

```
 your side (language-owned)                      │ the transpiler (Silica app, this repository)
 ────────────────────────────────────────────────│───────────────────────────────────────────────────────
 your parser / compiler   (it is the gate:       │
   nothing is sent unless it succeeded)          │
 your inbound codex       (source → Silica data, │
   every lowering decision is yours, §7, §8)     │
 your sender              (this contract) ══ TCP ═══► decode and validate ─► local storage (.sildat)
                                                 │      ─► lowering ─► Silica source + BEES manifests,
                                                 │         written as records into the same local storage
                                                 │      ─► result back to you (§6.4)
 the driver (any tool; app design §6.6)          │
   exports the session's files from storage ◄════╡  (reads the .sildat after the result)
   then (:release, …) ════════════ TCP ══════════►  the session's storage is freed (§6.6)
```

**Every byte the transpiler handles moves through Silica's transport**: the TCP carrier in, the store carrier for
everything it keeps, including the files it produces. Turning stored output into ordinary files, which the Silica
compiler and BEES's tools read, happens outside the transpiler, in the driver.

**What you own.** Your language's syntax, parsing, macro expansion, type checking, and every decision the BEES contract
leaves to a compiler: which lowering each construct gets (§7), which types you claim (§8), and what you refuse to
translate (gaps, §9.6). **You also own your language's semantics wherever a node of §9 does not carry them whole**
(decided 2026-11-13, the same principle as §8.6): what runs before and after a receive, what state a waiting process
keeps, what a link or a trapped exit does, what a format string prints. You lower those to the nodes of §9 before you
send (T9.13a, T9.16); the transpiler prints what it is told and gains no language-specific lowering.

**What the transpiler owns.** Silica's syntax and all of BEES's mechanical rules: the unit prefix (BEES A1.1), the
`.atoms`, `.module` and `.pools` manifests (A1.2, A1.3, A1.3a), no symbol literals outside `bees_atoms` (A6.3), no `case`
over 256 arms (A6.5), packing of more than 8 parameters (A6.11), effects (A6.12), state built as a literal so its release
is proven (A3.8), exhaustive branches (A5.3), the lowering-choices file (A9.1), and deterministic output.

## 2. Terms

| Term | Meaning |
| --- | --- |
| Sender | Your program: it connects to the transpiler and sends one session. |
| Session | One connection's worth of work: a hello, any number of units, an end. It may be resumed on a new connection (§6.3). |
| Unit | One module of your language. It becomes one Silica unit. |
| Form | One top-level declaration of a unit: a function, a type, an entry point or a gap. **One form is one frame.** |
| Frame | One ETF term with a 4-byte length in front (§4). |
| Node table | A form's code, written as a flat list of nodes that refer to each other by index (§9.1). |
| Construct | One node kind. **High-level** constructs (H-ids) are lowered by the transpiler using a choice; **low-level** constructs (L-ids) are already Silica-shaped. |
| Choice | A lowering named by the BEES lowering-choices table (BEES A9.1), declared for the session and optionally overridden per node (§7). |
| Hint | A type you claim for a node or a function, with a strength (§8). |

---

## 3. Connection

- **T3.1** The transpiler listens on **127.0.0.1 only** (Silica's `"listen:<port>"`, transport §6.3). The port is set in
  the transpiler's configuration; **provisional** default **7411**. Connect to it with plain TCP.
- **T3.2** The connection has **no authentication and no encryption** (transport §6.3, security note). Do not run the
  transpiler where untrusted local users can connect. Remote and authenticated transpiling waits for BEES's TRUST mode
  and is **open**.
- **T3.3** One session per connection. A connection ends a session only when the transpiler sends `(:result, …)` or
  `(:refused, …)`; a connection that drops before then leaves the session resumable (§6.3).
- **T3.4** Close your end after you have read `(:result, …)` or `(:refused, …)`. The transpiler stops sending on that
  connection after either.
- **T3.5** Do not wait for ever. If the part of the transpiler that serves your connection fails, the connection
  stays open and nothing more is sent on it (as built, 2026-11-13). When no reply has come for longer than you
  will wait, close the connection and resume the session on a new one (§6.3); nothing stored is lost.

## 4. Frames

- **T4.1** Every message in both directions is a **frame**: a 4-byte unsigned big-endian length, then that many bytes.
  This is Silica's `:stream` framing (transport §5) and Erlang's `{packet, 4}`.
- **T4.2** The bytes of a frame are **one ETF term**, starting with the version byte 131, as `term_to_binary/1` writes
  it with no options. No compression, no atom cache, no distribution header. Appendix A lists the ETF tags a sender needs.
- **T4.2a** **Planned:** ETF is Erlang's term format, chosen because it is Silica's first wire protocol. When Silica
  gains its planned CBOR format (format id 2 is reserved), the contract is to accept CBOR as well, so that no sender
  is tied to a BEAM format. The hello cannot negotiate its own encoding, so the first byte of a connection is to name
  it. **Open:** the exact byte and the CBOR spelling of each Silica type.
- **T4.3** A frame is at most the `max_frame` the transpiler grants in `(:welcome, …)` (§6.1). **Provisional** default
  1 MiB (1048576 bytes), which is the default `max_bytes` of Silica's `decode` (transport §4.1). A form too large for one
  frame must be split by you into several forms (for example, a long function into helper functions); there is no
  continuation frame. A length prefix above `max_frame` cannot be skipped, so the stream cannot be followed any
  further: the transpiler answers `(:rejected, …, :too_large)` with the next expected `seq` (before the welcome:
  `(:refused, …, :bad_hello)` with `detail` `too_large`) and closes the connection. The session is not finished.
- **T4.4** **Identifiers are binaries, never atoms.** Module names, function names, variable names, field names, symbol
  literals of your language: all are ETF binaries (`BINARY_EXT`, tag 109). Silica's `decode` only accepts atoms its
  program already knows (`:unknown_atom`, transport §4.3), so atoms appear on the wire **only** where this document
  writes an atom: message tags, node tags, record keys of the contract's own records, and the atom values listed in
  §6, §7 and §8.
- **T4.5** **Records are ETF maps with atom keys** (`MAP_EXT`, tag 116; transport §4.7). Every field this document lists
  must be present exactly once, and no other key may appear (`:missing_field`, `:duplicate_field`, `:unknown_field`).
  There are no optional fields: where a value may be absent the field's type says how (`-1`, an empty binary, an empty
  list, or the atom `none`).
- **T4.6** **Tagged tuples** are ETF tuples whose first element is the tag atom, `(:form, …)` written `{form, …}` in
  Erlang. Integers are signed 64-bit unless stated; a value outside the range is `:out_of_range`. Booleans are the atoms
  `true` and `false`.

---

## 5. Messages

Shapes below are written in Silica's notation for explanation only; the normative shapes are the types of the same
names in `tcp_transport_v1.silica` (§0). `bin` means an ETF binary. `idx` is an `int64` index into a list of the same
form, `-1` meaning none.

### 5.1 Sender to transpiler

| Id | Message | When |
| --- | --- | --- |
| **M1** | `(:hello, Hello)` | first frame of a connection, unless the connection only releases a session (M7) |
| **M2** | `(:unit_begin, { seq: int64, unit_name: bin, silica_unit: bin, source: bin })` | before a unit's forms |
| **M3** | `(:form, { seq: int64, unit_name: bin, body: Form })` | one top-level form (§9) |
| **M4** | `(:unit_end, { seq: int64, unit_name: bin, forms: int64 })` | after a unit's forms; `forms` is how many were sent |
| **M5** | `(:end, { seq: int64, units: int64 })` | after the last unit |
| **M6** | `(:abort, { reason: bin })` | give up the session; nothing is transpiled and its stored records are released |
| **M7** | `(:release, { session: bin })` | **instead of a hello**, as the first and only frame of a connection: the session's output has been exported; free its storage (§6.6) |

- **T5.1** `seq` numbers M2 to M5 of the session **consecutively from 0**, across connections. A frame whose `seq` is not
  the next expected is `(:rejected, …, :seq_gap)`; the rejection names the frame's own `seq`, and **no `seq` is used**:
  the next expected `seq` stays what it was. A frame whose `seq` is below the last `(:stored, next)` is a
  duplicate from a resume and is dropped without reply.
- **T5.1a** Every other rejected frame **uses its `seq`** (R5): send the next frame with the next number. A frame
  the schema's decoder rejects has no readable `seq`; it takes the next expected one, and its rejection names that.
- **T5.2** `unit_name` is your language's module name, as your users write it. `silica_unit` is the Silica unit basename you
  ask for: an identifier (letters, digits and `_`, not starting with a digit) that starts with the session's `prefix`
  (§6.1, BEES A1.1), unique in the session. `source` is the path of the source file, used only to label diagnostics.
- **T5.3** Units are sent one at a time: between M2 and M4 of one unit, only M3 for that unit. Forms may come in any
  order within the unit, with one exception: a `(:type)` form comes before every form that names it (T8.14).
  `(:end)` while a unit is open is `:unit_order`.
- **T5.3a** A `(:hello, …)` or `(:release, …)` after the connection's first frame is rejected `:bad_variant` with
  `seq` `-1`; it uses no `seq` and no credit.
- **T5.3b** **Counts.** `forms` in M4 is the number of M3 frames you sent for that unit that used a `seq`, accepted
  or rejected. `units` in M5 is the number of units whose M2 was accepted. A count that is not what the transpiler
  counted does not reject the frame (there is nothing to resend): the frame is accepted, the transpiler sends a
  `(:diagnostic, …)` with code `T1002` and severity `:error` naming both numbers at once, and the session cannot
  end `:ok` (`:failed` in check mode, at best `:partial` otherwise). A frame the schema's decoder refused while the
  unit was open may or may not have been a form, so either count is accepted for it. (Added 2026-11-13.)

### 5.2 Hello

```
Hello = {
    contract: int64,                          // 1
    session:  bin,                            // empty for a new session; a session id to resume (§6.3)
    sender: {
        language:      bin,                   // your language's name, e.g. "elixir"
        prefix:        bin,                   // the unit prefix reserved for your language (BEES A1.1), e.g. "ex_"
        codex:         bin,                   // your inbound codex's name
        codex_version: bin },
    options: {
        profile:   :bees | :silica,           // §7.4
        choices:   List[Choice],              // session defaults (§7.2)
        hints:     { proven: Policy, declared: Policy, inferred: Policy },   // §8.3
        run: {
            mode:      :transpile | :check,   // §6.5; :check validates and stores nothing
            max_frame: int64 } }              // the largest frame you will send; the transpiler may grant less
}
Choice = { requirement: Requirement, choice: ChoiceName, params: List[(bin, bin)], note: bin }
Policy = :trust | :check | :advisory
```

- **T5.4** On a resume (`session` not empty) every other field must equal the original hello's, or the transpiler
  answers `(:refused, …, :session_mismatch)`. A check-mode hello with a non-empty `session` is refused `:bad_hello` (T6.12).

### 5.3 Transpiler to sender

| Id | Message | Meaning |
| --- | --- | --- |
| **R1** | `(:welcome, { session: bin, contract: int64, transpiler: bin, flow: { resume_from: int64, credit: int64, max_frame: int64 } })` | hello accepted. `resume_from` is the first `seq` to send (0 for a new session). `credit` is how many M2 to M5 frames you may send now (§6.2) |
| **R2** | `(:refused, { reason: atom, detail: bin })` | hello refused; the transpiler closes. Reasons in §5.4 |
| **R3** | `(:credit, n: int64)` | you may send n more frames |
| **R4** | `(:stored, next: int64)` | every frame with `seq` below `next` is durable in local storage (§6.3). Exclusive, as Silica's `(:synced, next)` (transport §6.8.2) |
| **R5** | `(:rejected, { seq: int64, reason: atom, where: bin })` | that frame failed validation. It is recorded as rejected and its `seq` is used (T5.1 and T6.2 name the two reasons that use none); the session goes on. `where` is a path into the frame (`.body.code.nodes[12]`), for people; it is empty when the schema's decoder rejected the frame, because Silica's `decode` reports a reason and no position |
| **R6** | `(:progress, { stage: :resolve | :hints | :lower | :mechanics | :print | :write, unit_name: bin })` | the transpiler started a stage for a unit; for display only |
| **R7** | `(:diagnostic, Diagnostic)` | one finding (§6.4) |
| **R8** | `(:result, Result)` | the session is finished (§6.4); the transpiler stops sending |
| **R9** | `(:released, { session: bin, freed: boolean })` | the answer to M7: `freed` is `false` when the session is unknown or not finished; the transpiler then closes |

### 5.4 Reasons

- **T5.5** A rejection (R5) carries either one of Silica's `decode` rejection atoms (transport §4.3: `:truncated`,
  `:trailing_bytes`, `:bad_tag`, `:too_large`, `:too_deep`, `:too_long`, `:out_of_range`, `:bad_utf8`, `:unknown_atom`,
  `:bad_variant`, `:missing_field`, `:duplicate_field`, `:unknown_field`, `:unsupported`, `:bad_version`) or one of
  this contract's:

| Reason | Meaning |
| --- | --- |
| `:seq_gap` | `seq` is not the next expected (T5.1) |
| `:no_credit` | sent without credit (T6.2) |
| `:unit_order` | a form or unit end for a unit that is not open, or a unit begin while one is open (T5.3) |
| `:bad_unit_name` | `silica_unit` is not an identifier, lacks the prefix, or repeats (T5.2) |
| `:bad_index` | an index points outside its list, or a child index is not below its parent's (T9.2) |
| `:bad_choice` | a choice that does not belong to its requirement, a missing or extra parameter (§7) |
| `:profile` | a construct the session's profile does not allow (§7.4) |
| `:low_level` | a low-level construct outside its rules (§9.5) |
| `:bad_hint` | a hint on a node that cannot carry one, or a type index out of range (§8) |
| `:bad_node` | a node declaration (T9.17) whose name, port, tick time, redial, peer, registered name, tag or field type is not allowed, or a remote that names a peer the declaration does not list |

- **T5.6** A refusal (R2) has one of: `:contract` (a version the transpiler does not serve), `:session_mismatch`,
  `:unknown_session` (a resume names a session the transpiler does not hold), `:busy` (every storage region holds a
  session, finished ones waiting for their release included; try later, or release one, §6.6), `:choices` (a BEES requirement missing or
  given twice in a `:bees` session, §7.2), `:bad_hello` (it did not decode, and `detail` is then the decoder's reason
  atom as text, for example `missing_field`; or it breaks T5.4, T6.12 or T8.4, or its `max_frame` is below 1; or the
  connection's first frame is neither a hello nor a release).

---

## 6. Session

### 6.1 Opening

```
sender                                   transpiler
  ── (:hello, …) ──────────────────────►
  ◄────────────── (:welcome, …) or (:refused, …)
  ── (:unit_begin) (:form)… (:unit_end) … (:end) ──►   (under credit, §6.2)
  ◄── (:credit) (:stored) (:rejected) …
  ◄── (:progress) (:diagnostic) … (:result, …)
```

- **T6.1** Send nothing after the hello until you have the welcome. Use the welcome's `max_frame`, which is never larger
  than yours.

### 6.2 Flow control

- **T6.2** Credit-based, as Silica's carriers are (transport §6.2): you may send M2 to M5 only while you hold credit; each
  consumes one. M1 and M6 need none. The welcome's `credit` is your first allowance and each R3 adds to it. A frame sent
  without credit is rejected `:no_credit` and its `seq` is **not** used.
- **T6.3** The transpiler gives credit as its local storage accepts records, so a sender of any size never makes the
  transpiler hold more than a bounded window in memory. **As built:** the window is 64 (**provisional**). Each time
  half of it is used the transpiler makes what it has durable and then sends `(:stored, next)` followed by
  `(:credit, 32)`; a sender that has used its whole window waits for that pair.

### 6.3 Durability and resume

- **T6.4** `(:stored, next)` means the frames below `next` are on disk and survive a crash of the transpiler: it is sent
  only after Silica's store has answered `(:synced, …)` for them (transport §6.8.5). Frames you have sent and not seen
  stored may be lost.
- **T6.5** To resume after a dropped connection or a transpiler restart, connect again and send the same hello with
  `session` set to the welcome's session id. The welcome's `resume_from` is where to restart; send from there. Frames
  below it that you resend are dropped (T5.1), so resending too much is harmless.
- **T6.5a** `resume_from` is never below the last `(:stored, next)` you saw, and after a dropped connection it is
  usually every frame the transpiler had received. Rejections are part of the session: a frame that was rejected
  before the drop stays rejected and its `seq` stays used. A session whose `(:end)` was already stored is resumed
  with `resume_from` equal to the number of frames stored and `credit` 0: send nothing, the `(:result, …)` follows
  (at once if the session had finished; its diagnostics are sent only the first time). A resumed session that is
  still attached to an older connection is taken over by the new one. (Added 2026-11-13.)
- **T6.5b** A session id is text of the form `<region>:<number>` (`intake_1:42`); treat it as opaque.
- **T6.6** **Open:** how long the transpiler keeps an unfinished session it has not heard from.

### 6.4 Result

```
Diagnostic = { seq: int64, unit_name: bin,
               finding: { severity: :error | :warning | :note, code: bin, message: bin },
               place:   { file: bin, line: int64, column: int64 } }
Result     = { status: :ok | :partial | :failed,
               counts: { units: int64, gaps: int64, rejected: int64 },
               session: bin, files: int64 }
```

- **T6.7** After `(:end)` is stored, the transpiler transpiles the session's units and sends diagnostics, then one
  result. `seq` in a diagnostic is the frame it concerns (-1 for the session); `file`, `line` and `column` point into
  **your** source, from the locations you sent (§9.1). `code` is the transpiler's diagnostic code (T-numbers, listed in
  the app design §8).
- **T6.8** `status` is `:ok` when every unit was written with no error and no gap, `:partial` when some units or forms
  were written and others were rejected or are gaps, `:failed` when nothing was written (`files` is then 0: a unit
  of which nothing could be written gives no file and a `T4003` diagnostic).
- **T6.8a** `counts.gaps` in a transpile result is the gaps you sent (the number a check session of the same frames
  reports, T6.11) plus one for each form you sent without a gap that the transpiler itself could not write. Each gap
  form has one diagnostic: code `T4001` when the gap is yours, `T4002` when it is the transpiler's (a construct it
  does not print yet), and a `T31xx` code when the form's types are missing or inconsistent (T8.13: your fault, and
  severity `:error`). So `counts.gaps` minus the number of `T4002` and `T31xx` diagnostics is the check session's
  number. (Added 2026-11-13.) Two codes come with **no** gap: `T2001` (a lowering choice of your hello that the
  written unit does not follow, T7.5) and `T4004` (a form that was written, with a warning about what was written,
  T9.13). A `T4002` diagnostic on a unit and not on a form (something the transpiler saw only when it had the whole
  unit: a spawned function that the unit does not have, an ordinary call of a process function) counts one gap.
  `session` names the session
  whose storage now holds the output, and `files` is how many files it holds: the Silica units, the BEES manifests and
  the BEES lowering-choices file (BEES A9.1). The result is sent only after those records are durable.
- **T6.9** The output is in the transpiler's local storage, not in files. The driver (app design §6.6) exports it into
  a directory, builds it with the Silica compiler and runs the BEES conformance programs; none of that is part of the
  result in version 1. **Open:** whether a later version reports the build.

### 6.5 Check mode

- **T6.10** A hello with `options.run.mode` `:check` opens a check session. The transpiler decodes and validates every
  frame exactly as in a transpile session, answers with `(:credit, …)` and `(:rejected, …)`, and **stores nothing and
  transpiles nothing**. There is no `(:stored, …)`.
- **T6.11** After `(:end)`, a check session ends with `(:result, …)`: `status` `:ok` when no frame was rejected,
  otherwise `:failed` (also after a `T1002` finding, T5.3b); `counts.rejected` the number rejected; `counts.units`
  the units seen; `gaps` the gaps sent (gap forms and gap nodes);
  `session` the check session's id; `files` 0.
- **T6.11a** A check session's credit is a fixed window (**provisional** 64, in the welcome), refilled by
  `(:credit, 32)` each time half of it is used. `(:abort, …)` ends a check session with no result: the transpiler
  closes the connection.
- **T6.12** A check session cannot be resumed (`session` in its hello must be empty) and needs no storage region, so it
  is never refused `:busy`. It is the contract's executable shape check: use it in your test loop (§0).

### 6.6 Releasing a session

- **T6.13** A finished transpile session keeps its storage until it is released, so its output can be exported, again
  if need be. An `(:abort, …)` (M6) frees an unfinished session's storage at once. To release it, open a new connection and send `(:release, { session })` as its only frame (no hello, no
  credit). The transpiler answers `(:released, { session, freed })` and closes.
- **T6.14** Release frees the session's storage for other sessions. Release a session only after its output is
  exported. **Open:** whether the transpiler releases finished sessions on its own after some time.

---

## 7. Lowering choices

### 7.1 What a choice is

High-level constructs (§9.4) say **what** your program does: receive with a timeout, send, spawn, catch a failure. The
transpiler decides **how** from a choice. The choices are the BEES lowering-choices table (BEES A9.1), so a choice you
make here is the line the transpiler writes into your lowering-choices file.

### 7.2 Session defaults

- **T7.1** In a `:bees` session, `Hello.choices` must hold **exactly one choice for each requirement** below; otherwise
  `(:refused, …, :choices)`. In a `:silica` session only A3.4 and A6.8 apply: exactly one choice for each of those
  two, and the others must be absent.
- **T7.2** Atom spellings replace BEES's hyphens and dots with underscores.

| `requirement` | BEES | `choice` atoms | `params` keys |
| --- | --- | --- | --- |
| `:a3_2` | stack reserve | `:lowered`, `:default` | `reserve` (lowered only), `release` |
| `:a3_3` | suspension points | `:phase_field`, `:continuation_table`, `:other`, `:not_applicable` | none |
| `:a3_4` | yield points | `:back_edge`, `:budget_counter`, `:none`, `:other` | `budget` (optional, budget_counter) |
| `:a4_2` | child ids | `:single_pool`, `:pool_tree`, `:other` | `pool_size`; `fanout`, `leaf_size` |
| `:a4_3` | supervisor shape | `:one_per_shape`, `:uniform_shape`, `:other` | none |
| `:a4_4` | restart and strategy | `:chosen` | `restart`, `strategy` |
| `:a5_1` | recoverable errors | `:result_values`, `:result_variants`, `:mixed`, `:rejected`, `:not_applicable` | none |
| `:a5_4` | send to a dead recipient | `:proxy`, `:liveness_check`, `:accept_sender_death`, `:not_applicable`, `:other` | none |
| `:a5_5` | links and exit requests | `:silica_link`, `:supervisor_request`, `:not_supported`, `:other` | none |
| `:a6_8` | byte and bit operations | `:lookup_tables`, `:not_supported`, `:other` | none |
| `:a7_1` | dynamic dispatch | `:module_table`, `:own_dispatch`, `:not_applicable` | none |

- **T7.3** Parameter values are binaries holding the BEES spelling (`{<<"restart">>, <<"transient">>}`). The keys and
  values are BEES's (`contract/conformance/lowering-choices.md` in BEES); a wrong key or value is `:bad_choice`.
- **T7.4** **`:other` means you lower that construct yourself with low-level constructs (§9.5).** A high-level node whose
  effective choice is `:other` is rejected `:bad_choice`: you must send its low-level form instead. `note` is required
  for `:other` and `:not_applicable` and is copied into the lowering-choices file.
- **T7.5** **Provisional:** which choices the transpiler implements in its first release is in the app design §5.2. A
  choice listed here and not yet implemented is answered by a T2001 diagnostic naming it, and every node using it
  becomes a gap. **As built (2026-11-13):** the printer writes processes one way, whatever the profile (§9.4a), and
  that way is the choices `a3_3 phase_field`, `a4_2 single_pool` (your `pool_size`), `a4_3 uniform_shape`,
  `a4_4 chosen` (your `restart` and `strategy`), `a5_4 accept_sender_death`, and for an exit request
  `a5_5 supervisor_request`. A unit that has processes gets **one**
  T2001 diagnostic that names each choice of your hello that this does not follow (a different choice for one of
  those five; `a3_4` other than `none`, because no yield point is written; `a3_2`, because a child's specification
  carries no stack policy: limitation observed). The nodes are still written, as §9.4a says; they do not become
  gaps. The one choice that is read for a node is `a5_5`: an `(:exit_signal)` is written only under
  `supervisor_request` (T9.15). Overrides (§7.3) are not read, **with one exception (2026-11-14): an `a4_4`
  override on the `(:spawn)` of a static child (T9.14b)**, whose `restart` is that child's restart policy.

### 7.3 Overrides

- **T7.6** A function form may override the session default for single nodes: its `notes.overrides` (§9.3) is a list of
  `{ node: idx, requirement: Requirement, choice: ChoiceName, detail: { params: List[(bin, bin)], note: bin } }`. The override applies
  to that node only. A node may have at most one override per requirement.
- **T7.7** An override must name a requirement the node's construct uses (the H-table, §9.4, lists them); otherwise
  `:bad_choice`.
- **T7.8** Every override is listed in the lowering-choices file's notes, so a reviewer sees each departure from the
  session default. **Open:** BEES's checker accepts one line per requirement; until BEES gives overrides a form, the
  transpiler writes them as `#` comment lines under the requirement's line.

### 7.4 Profiles

- **T7.9** `:bees`: the output uses the BEES units (BEES Part B). Values without a trusted type are `bees_term` cells
  (BEES A6.1). Every high-level construct is available.
- **T7.10** `:silica`: the output uses no BEES unit. **Every value must have a type** the transpiler can trust or check
  (§8); a node left untyped is `:profile`. The process constructs H20 to H25, H38 and H39 are not available
  (`:profile`); send low-level forms. This profile is for statically typed languages that want plain Silica.

---

## 8. Type hints

### 8.1 What a hint is

- **T8.1** Hints are optional on the wire: a frame with no hints is valid in the `:bees` profile, and every value is
  then a `bees_term`. **As built (2026-11-13) the untyped representation does not exist**, so a function is written
  only when its types are stated as §8.6 requires. §8.6 is the rule for typed output: **you decide every type.**
- **T8.2** A hint is a claim that a node's value, or a function's arguments and result, always have a type. With a
  hint the transpiler may emit typed Silica instead of `bees_term` cells, and messages with hinted types travel through
  Silica's own `encode`/`decode((:etf), …)` (transport §4; BEES B1a N5) instead of a hand-made encoding.

### 8.2 Strength

Every hint says how sure it is:

| `strength` | Meaning | Typical source |
| --- | --- | --- |
| `:proven` | your language's type checker verified it | Gleam, Haskell |
| `:declared` | the programmer wrote it, nothing enforced it | Erlang `-spec`, Elixir `@spec` |
| `:inferred` | your inbound codex worked it out | your own analysis |

### 8.3 Policy

- **T8.3** `Hello.hints` gives the session's policy for each strength. A hint may override it (§8.4).

| Policy | What the transpiler does |
| --- | --- |
| `:trust` | emits typed Silica with no check. A wrong hint is a Silica compile error or wrong behaviour; it is on you |
| `:check` | emits typed Silica, and a **validating conversion** where untyped code meets typed code (function entry, message receipt). A value that does not fit fails the actor, as a failed `decode` rejects bytes |
| `:advisory` | emits untyped code; the hint is used only for names, documentation and diagnostics |

- **T8.4** **Recommended:** `{ proven: :trust, declared: :check, inferred: :check }`. In a `:silica` session `:advisory`
  is not allowed (`:bad_hello`): there is no untyped representation to fall back on.

### 8.4 Where hints go

```
Hint = { node: idx, type: idx, strength: :proven | :declared | :inferred, policy: :default | Policy }
```

- **T8.5** A function form's `notes.hints` (§9.3) attaches a type to a node: **any node of the form** (T9.7), for
  example a variable's binding, a function's clause pattern, a record or tuple construction, a message in a send or
  a receive clause, a call, an operand of an operator. `node` is `-1` for the form's own signature (a function's
  argument and result types, given as a `(:t_fun, …)` type). `type` indexes the form's `types`. A node has at most
  one hint; a second hint on the same node is `:bad_hint` when it names a different type index (**as built:** not
  checked at receipt; the first hint is used). §8.6 says which nodes **must** have one.
- **T8.6** **Representation** conversions (between an untyped `bees_term` and a typed value, §8.3) happen only at
  function entry and at message receipt, never inside an expression, so their cost is where people can see it.
  **Numeric** conversions (integer to float, float to integer) are not these: they are operators that you write
  where your language converts (T8.12), and nothing else converts a number.

### 8.5 The type vocabulary

A form's `types` is a flat table like the node table (child indices below the parent's). Every entry is a tagged
tuple (`{t_int, i64}`, `{t_basic, boolean}`). The types that have no field of their own are the kinds of one entry,
`:t_basic`: a one-atom tuple is not a Silica run-time value (transport §6.2), and a bare atom among these entries
makes Silica's derived decoder fault (measured 2026-11-12; app design §10). Each entry is one of:

| Tag | Fields | Silica type (Silica specification §4) |
| --- | --- | --- |
| `:t_int` | `width: :i8 \| :i16 \| :i32 \| :i64 \| :u8 \| :u16 \| :u32 \| :u64` | `int8` … `uint64` |
| `:t_float` | `width: :f32 \| :f64` | `float32`, `float64` |
| `:t_basic` | `kind: :boolean \| :char \| :text \| :bytes \| :symbol \| :dynamic` | `:boolean` is `boolean`; `:char` is `char`; `:text` is `string`, UTF-8 checked; `:bytes` is `string` (bytes) in `:silica` and a byte sequence (BEES A6.7) in `:bees`; `:symbol` is `atom`; `:dynamic` is `bees_term` (`:bees` only) |
| `:t_symbols` | `names: List[bin]` | an atom union, `:a \| :b` |
| `:t_tuple` | `elems: List[idx]` | a tuple |
| `:t_tagged` | `tag: bin, elems: List[idx]` | a tagged tuple `(:tag, …)` |
| `:t_record` | `fields: List[(bin, idx)]` | a record |
| `:t_list` | `elem: idx` | `List[T, normal]` |
| `:t_union` | `alts: List[idx]` | an inline sum; its alternatives must be told apart by kind, tag or arity (Silica E2404) |
| `:t_fun` | `params: List[idx], result: idx` | a function type |
| `:t_actor` | `message: idx` | an actor reference whose messages have that type |
| `:t_named` | `name: bin, args: List[idx]` | a type declared by a `:type` form of the session (§9.3) |
| `:t_var` | `name: bin` | a type parameter of the enclosing `:type` or function signature |

- **T8.7** **Fallbacks are fixed, so a hint never stops a program from translating.** Where the transpiler cannot honour
  a hint it falls back as below and reports a T3xxx note; the program still translates.

| Hint | Fallback |
| --- | --- |
| an integer type of unbounded size (send `:t_int` `:i64` for Erlang `integer()`) | `int64`; overflow fails the actor (BEES A6.6). Bigger integers wait on Silica |
| a `:t_union` Silica cannot tell apart (E2404) | `(:t_basic, :dynamic)` in `:bees`; a T3002 error and a gap in `:silica` |
| `:t_var` in a position Silica cannot make generic | **open**: whether the transpiler specialises per use or falls back to `(:t_basic, :dynamic)` |
| type classes, higher-kinded types | not in the vocabulary: send the specialised types, or no hint |

### 8.6 The sender decides every type

**Decided 2026-11-13 (binding).** The language side decides all data types. The transpiler never infers a type and
never converts a value on its own. It prints what it is told, and reports a diagnostic with your file and line when
a type or a conversion it needs is missing or the typing you sent is inconsistent. The hints (§8.4) and each form's
type table (§8.5) are how you state types; nothing new is on the wire.

- **T8.8** **Who decides.** Every type in the output comes from you. Your codex knows your language's typing rules;
  the transpiler knows none of them. It does not promote an integer to a float, does not guess a variable's type
  from how it is used, does not look up another function's signature to type a call, and does not pick between
  integer and float division.
- **T8.9** **Stated type.** A node has a *stated type* in exactly these cases, and in no other:

| Node | Its stated type |
| --- | --- |
| any node with a hint (T8.5) | the hint's type. It is used as written, before every row below |
| `(:int)` | an integer: `int64`, or the integer width its place states (the other operand of its operator, the parameter, field or result it is written into). Never a float |
| `(:float)` | a float: `float64`, or `float32` where its place states `float32`. Never an integer |
| `(:text)`, `(:bytes)`, `(:boolean)`, `(:symbol)` | `string`, `string` (as built: a byte string is written as a Silica string, whatever the profile), `boolean`, `atom` (a symbol takes a symbol-union or tagged type its place states) |
| `(:var)` used as a value | the stated type of its binding: a parameter has the type the signature hint gives it; a local variable has the type of its binding (T8.10 b) |
| `(:op)` with a comparison or boolean operator, or `<>` | fixed by the operator: `boolean`; `string` for `<>` (Appendix B) |
| `(:op)` with a conversion operator | fixed by the operator: `to_float` is `float64`; `trunc` and `round` are `int64` (T8.12) |
| `(:op)` with an arithmetic operator | fixed by the operator: the type of its operands, which T8.11 requires to be one type |
| `(:tuple)`, `(:record)` without a `base` | the tuple or record of its elements' or fields' stated types, when every one has one |
| `(:field)` | the type of that field in the record's stated type |
| `(:block)`, `(:case)`, `(:cond)`, `(:match)`, `(:loop_hint)` | the type its place states (the function's result for a body); otherwise only a hint |
| every other node: `(:call)`, `(:apply)`, `(:fun_ref)`, a `(:record)` update, `(:nil)`, `(:cons)`, `(:list)`, `(:map)`, `(:receive)`, `(:self)`, … | **only a hint**, or the type its place states (the function's result for a body). An argument of a call is **not** such a place: the transpiler does not know the callee's signature |

  Notes on the table. (1) **The hint wins for a structured value**: a `(:tuple)` whose first element is a symbol
  may be hinted with a `(:t_tagged)`, a `(:t_union)` or a `(:t_named)` that has that alternative, and a symbol with
  a `(:t_symbols)`; the hint is then its type. (2) A `(:gap_node)` has no stated type and cannot be given one: the
  form that holds it is a gap (T9.10). (3) For a receive clause, the hint goes on the clause's pattern node.
  (4) **As built**, types are compared as the Silica types they are written as: every `(:t_symbols)` outside a
  union is `atom`, and every `(:t_actor)` is Silica's `actor_ref`, whatever its message type. A
  `(:t_basic, :dynamic)` cannot be written (`T4002`): there is no untyped representation yet (T8.1).
  The rows that need no hint are not inference: each is fixed by the node itself or by a type you already stated.
  A hint that disagrees with a fixed row (a hint `:t_float` on an `(:int)` literal, a hint `:t_int` on a `/`) is
  inconsistent typing (`T3103`).
- **T8.10** **Where a type is required.** You must state a type (by a hint, unless T8.9 fixes it) for:
  - **(a) every function form:** a hint on node `-1` whose type is a `(:t_fun, params, result)` with one parameter
    type for each of the function's `arity` parameters. A closure `(:lambda)` needs a `(:t_fun, …)` hint on its node.
  - **(b) every local variable binding:** a `(:var)` in a pattern binds a variable. Its type is the hint on that
    `(:var)` node; without one, it is the stated type of what the pattern is matched with, taken apart position by
    position (a parameter's type for a clause pattern, the stated type of a `(:match)`'s value or a `(:case)`'s
    subject). When neither exists the binding has no type. So for `X = f(A)` hint the `(:var)` `X` or the `(:call)`.
  - **(c) every operand of an arithmetic or comparison operator** (Appendix B). An operand that is a literal is
    fixed by the literal; every other operand must have a stated type.
  - **(d) every call result that is used:** as an operand, as the value of a binding, as the subject of a
    `(:case)`, or as a statement whose value is dropped. Hint the `(:call)` or `(:apply)` node with its result type.
    (A call whose value is only passed on as an argument, or returned as the function's result, needs none.)
  - **(e) every value the output must name a type for:** the subject of a `(:case)`, the value of a `(:match)`,
    every expression of a `(:block)` but the last, a `(:record)` or list construction that is not directly the
    function's result, a message in a send and in a receive clause.
- **T8.11** **No mixing.** The two operands of an arithmetic or comparison operator must have **the same stated
  type**: both the same integer width, or both the same float width, or (comparison only) both `boolean`, both
  `string`, both `atom` or the same structured type. An integer next to a float is not converted for you, and
  neither is `int32` next to `int64`. `div` and `rem` take integers; `/` takes floats and gives a float. An integer
  literal is an integer: next to a float operand write a `(:float)` literal or a `to_float`.
- **T8.12** **Numeric conversion is an operator you write.** Where your language converts a number, send the
  conversion as an `(:op)` with one operand (Appendix B, group "conversion"):

| `op` | Operand | Result | Meaning |
| --- | --- | --- | --- |
| `to_float` | any integer type | `float64` | the float nearest the integer; exact when the magnitude is at most 2^53 (as built, beyond 2^53 the result is a float near the integer, not always the nearest) |
| `trunc` | `float64` | `int64` | the integer part, toward zero |
| `round` | `float64` | `int64` | the nearest integer, a half away from zero |

  Which one your language means is your decision: Erlang's and Elixir's `/` on integers is `to_float` on each
  operand and then `/`; Erlang's `trunc/1` and `round/1` and Gleam's `float.truncate` and `float.round` are `trunc`
  and `round`; Gleam's `int.to_float` is `to_float`. A float that is not a number, is infinite or is outside
  `int64` has no defined `trunc` or `round` here: guard it or send a gap. A conversion your language has and this
  table does not (floor, ceiling, other widths) is a gap (T9.10) until the table grows. **Open:** conversions
  between integer widths and to `float32`.
- **T8.13** **What the transpiler does when the typing is missing or inconsistent.** It does not guess. The form
  is not written (it becomes a failing stub when its signature can be written, as a gap does, T9.10), it counts in
  `Result.counts.gaps` (T6.8a), and one `(:diagnostic, …)` of severity `:error` names the construct and node, with
  `place` taken from the node's location (T9.3) in the form's `file`:

| Code | Meaning |
| --- | --- |
| `T3101` | a type is required (T8.10) and none is stated: the message names the node and says which of (a) to (e) |
| `T3102` | the operands of an arithmetic or comparison operator have different stated types and no conversion was sent (T8.11); the message names both types |
| `T3103` | inconsistent typing: a hint disagrees with what the node fixes (T8.9), a conversion operator has an operand of the wrong kind (T8.12), a signature hint that is not a `(:t_fun)` or has the wrong number of parameters |
| `T3104` | a `(:t_named)` names a type that no `(:type)` form sent earlier in the session declares, or gives it the wrong number of arguments (T8.14) |

- **T8.14** **Declared types.** A `(:t_named, name, args)` entry names the type a `(:type)` form declares (§9.3).
  The `(:type)` form must be sent **before** every form that names it: earlier in the same unit, or in an earlier
  unit of the session (a type declared in a later unit, or never, is `T3104`). `name` is matched exactly, across
  the session's units; declare a name once (a second declaration of a name replaces the first for the forms after
  it). `args` gives one type for each of the declaration's `params`; inside the declaration a `(:t_var, name)`
  stands for the parameter of that name. Silica has no type names, so the transpiler writes the declared type out
  at each use; a type that names itself, directly or through another, cannot be written out and is reported
  (`T4002`). A `(:t_var)` in a function's signature (a generic function) is `T4002`: specialise it (T8.7).
- **T8.15** **Division by zero, overflow and every other arithmetic edge are your language's.** The transpiler
  writes the operator and nothing around it; what the Silica operator then does is Silica's behaviour (Appendix B
  lists what was measured). Where your language defines something else you must send it: Gleam's `a / 0` is `0`,
  so its sender sends a `(:case)` on the divisor; Erlang's float division by zero fails the process, so its sender
  sends a guard with `(:fail)`; a language with integers of unbounded size sends its own check or a gap, or states
  the deviation in its documentation.

- **T8.16** **A type test is a type statement, not a guard you send.** Where your language tests a value's type
  at run time (Erlang's and Elixir's `is_integer(N)` in a guard, a typed pattern), and the variable's stated type
  already **is** the tested type, do not send the test: it says nothing the type does not say, and the transpiler
  knows no language's type tests (a `(:call)` to your `is_integer` is a call to a module outside the session,
  T9.9). Send the type, as the hint that T8.10 asks for, and send the other tests of the guard as they are. This
  holds most of all for a **receive clause**: the hint on its pattern node (T8.9, note 3) is the type of the
  messages the clause takes, and the clause takes no other message. `{add, N} when is_integer(N), N > 0` is the
  pattern `{add, N}` with the hint `(:t_tagged, add, [int])` and the guard `N > 0`. A type test on a variable whose
  stated type is another type, or has none, is not covered by this rule: send what your language means (a
  `(:boolean)`, a gap).

---

## 9. Silica data: what a form contains

### 9.1 Node tables

- **T9.1** A form's code is a **flat node table**: `nodes: List[Node]`, where a node refers to other nodes by their
  index in the list. This is how Silica's own compiler holds code, and it keeps every frame's nesting shallow, so
  `decode` needs no region and only small depth limits.
- **T9.2** **Every child index must be smaller than its parent's index** (children before parents, as a post-order walk
  writes them). This makes cycles impossible and is checked (`:bad_index`).
- **T9.3** Every node's second element is `at: idx`, an index into the form's `code.locations: List[(int64, int64)]` (line,
  column) in the form's `file`. `-1` means no location.
- **T9.4** Where this section writes `idx?`, `-1` means absent.

### 9.2 Profile and scope

The first version covers: functions, literals, data construction and matching, calls, closures, control flow, binaries,
processes, messages, failure, and type declarations. **Open:** a BEAM supplement for OTP behaviours (`gen_server`,
`supervisor`, `gen_statem`), waiting for BEES's Part D supplement. Until then a sender lowers OTP behaviours into
processes and receives itself, or sends them as gaps. **A supervisor whose child list is fixed when it starts needs
no supplement:** its children are sent as static children (T9.14b). Reading your language's supervisor (its
callback module, its child specifications, its start functions) is yours; the Erlang proof of concept does it in
`erlang-to-silica-poc/src/e2s_sup.erl`.

### 9.3 Forms

```
Form = (:function, Function) | (:type, TypeDecl) | (:entry, Entry) | (:gap, FormGap)

Function = { head:  { name: bin, arity: int64, exported: boolean, file: bin },
             code:  { locations: List[(int64, int64)], nodes: List[Node], clauses: List[idx] },
             types: List[TypeNode],
             notes: { hints: List[Hint], overrides: List[Override] } }

TypeDecl = { head: { name: bin, params: List[bin], exported: boolean, file: bin },
             at_line: int64, types: List[TypeNode], root: idx }

Entry    = { function: bin, arity: int64 }       // the program's entry point; at most one per session

FormGap  = { name: bin, place: { file: bin, line: int64 }, construct: bin, note: bin }
```

- **T9.5** `clauses` lists the function's top-level `(:clause, …)` nodes in order. Each has `arity` patterns.
- **T9.6** `Entry` names the function the program starts in. The transpiler writes `main` around it: it registers BEES's
  failure reporter, starts the root supervisor and starts the entry under it (BEES A2.1, A2.2). A session with units and
  no entry is a library; it is written, and `main` is not. **As built:** the entry function must be written in the
  unit that holds the entry form and take no parameters. In a unit with processes (§9.4a) `main` registers a
  failure reporter of its own (no BEES unit is used), starts the unit's supervisor and starts the entry function
  as the first process, with the child id `<silica_unit>_entry`; the program ends, with exit status 0, when that
  process ends. In a unit with no process node `main` calls the entry function and returns 0.
- **T9.11** **Names.** A function is written under the name you send, with these exceptions, which are the same
  for its definition and for every `(:call)` and `(:fun_ref)` that names it:

| Your function name | Written as |
| --- | --- |
| a Silica reserved word or builtin, or `main` (the list is `reserved_names` in `silica-sink/src/ts_print.silica.in`; `move`, `send`, `link`, `self`, `spawn`, `length`, `main`, … are on it) | the name with `__` appended: `move__`, `main__` |
| not an identifier (letters, digits and `_`, not starting with a digit), or starting with `to_silica_` | not written (`T4002`); a caller of it becomes a stub. Mangle such a name yourself |

  The transpiler makes these names itself, so do not send a function name that is one of them: every name that
  starts with `to_silica_`; `<name>__spawn` and `<name>__spawn_watched` for a function `<name>` that can run as a
  process (§9.4a); and `<name>__` for a reserved `<name>`. The same holds for the name of a static child (T9.14b),
  which is written as a child id: not `<silica_unit>_p<number>`, `<silica_unit>_entry`, `<silica_unit>_sup` or
  `<silica_unit>_spawner` (**not checked**). (**Not checked:** a session that sends both `move` and
  `move__` gets two functions of one name, which the Silica compiler refuses.) Record field names are not
  mangled: a field named like a reserved word is not written (`T4002`). A `(:call)` or `(:fun_ref)` whose `module`
  is the `unit_name` of the unit it stands in is a local call, as an empty `module` is.

### 9.4 Nodes: the high-level vocabulary

The node tag is the first element. Patterns use the same node kinds as expressions; which one a node is follows from
where it is referenced. **R** names the BEES requirements whose choice lowers the construct (§7.3 overrides may name
only those).

**Literals and data**

| Id | Node | Notes |
| --- | --- | --- |
| H1 | `(:int, at, value: int64)` | |
| H2 | `(:float, at, text: bin)` | a float, as decimal text that reads back to the same value (`<<"2.5">>`, `<<"1.0e-3">>`). Text, not a float64, because Silica has no float-to-text conversion for the transpiler to print with (app design §6.5) |
| H3 | `(:text, at, value: bin)` | UTF-8 text |
| H4 | `(:bytes, at, value: bin)` | a byte string |
| H5 | `(:symbol, at, name: bin)` | your language's atom or symbol; becomes a Silica atom through `bees_atoms` (BEES A6.3) |
| H6 | `(:boolean, at, value: boolean)` | |
| H7 | `(:nil, at)` | the empty list |
| H8 | `(:tuple, at, elems: List[idx])` | |
| H9 | `(:cons, at, head: idx, tail: idx)` | a list cell |
| H10 | `(:list, at, elems: List[idx], tail: idx?)` | a list; `tail` `-1` is a proper list |
| H11 | `(:map, at, pairs: List[(idx, idx)], base: idx?)` | a map; with `base`, an update of that map |
| H12 | `(:record, at, name: bin, fields: List[(bin, idx)], base: idx?)` | a named record; with `base`, an update |
| H13 | `(:field, at, record: idx, name: bin)` | field access |
| H14 | `(:bits, at, segments: List[idx])` | a binary built or matched from segments. **R** A6.8 |
| H15 | `(:segment, at, value: idx, size: idx?, unit: int64, kind: :integer \| :float \| :binary \| :utf8, signed: boolean, endian: :big \| :little)` | one segment of H14 |

**Names, matching and control**

| Id | Node | Notes |
| --- | --- | --- |
| H16 | `(:var, at, name: bin)` | a variable; in a pattern, a binding |
| H17 | `(:wild, at)` | `_` in a pattern |
| H18 | `(:match, at, pattern: idx, value: idx)` | bind by pattern; a mismatch fails the actor |
| H19 | `(:block, at, exprs: List[idx])` | a sequence; its value is the last |
| H28 | `(:case, at, subject: idx, clauses: List[idx])` | the transpiler adds the failing catch-all Silica needs (BEES A5.3) |
| H29 | `(:clause, at, patterns: List[idx], guard: idx?, body: idx)` | in `case`, `receive`, `try`, functions and closures |
| H30 | `(:cond, at, clauses: List[idx])` | clauses with no patterns, first true guard wins |
| H31 | `(:op, at, op: bin, args: List[idx])` | an operator from Appendix B. Its operands need stated types of one kind (T8.10, T8.11); a numeric conversion is one of these (T8.12) |
| H32 | `(:call, at, module: bin, name: bin, args: List[idx])` | a call known at compile time; `module` empty for a local call. Its result has a type only through a hint on this node (T8.10 d) |
| H33 | `(:apply, at, fun: idx, args: List[idx])` | a call through a function value. **R** A7.1 |
| H34 | `(:apply_mfa, at, module: idx, name: idx, args: List[idx])` | a call whose module or function is computed. **R** A7.1 |
| H35 | `(:fun_ref, at, module: bin, name: bin, arity: int64)` | a named function as a value. **R** A7.1 |
| H36 | `(:lambda, at, clauses: List[idx])` | a closure; the transpiler finds what it captures. **R** A7.1. **As built:** written only as the `fun` of a `(:spawn)` (T9.14); any other `(:lambda)` is answered `T4002` (a Silica function literal captures only integer literals: limitation observed). A function literal of your language **that captures nothing** needs no closure: send it as a `(:function)` form of its own (not exported, with its signature hint, T8.10 a) and a `(:fun_ref)` (H35) where it stands; that lowering is yours (§1; the Elixir proof of concept does it in `lib/e2s/lift.ex`) |
| H37 | `(:loop_hint, at, body: idx)` | marks a body that recurses without bound, where a yield point belongs. **R** A3.4 |

**Processes, messages and failure**

| Id | Node | Notes |
| --- | --- | --- |
| H20 | `(:self, at)` | this process. Its type is `(:t_actor, …)` |
| H21 | `(:spawn, at, fun: idx, args: List[idx], link: boolean)` | a new process running `fun` with `args`, placed under a supervisor. **R** A3.2, A4.2, A4.3, A4.4. **As built:** T9.14 |
| H22 | `(:send, at, to: idx, message: idx)` | **R** A5.4. **Its value is the message** (Erlang's `!`): a hint on the `(:send)`, or the type its place states, must be the message's type (`T3103` otherwise). A language whose send has another value (Gleam's `Nil`) sends the `(:send)` as a statement of a `(:block)`, followed by that value. **As built:** T9.12 |
| H23 | `(:receive, at, clauses: List[idx], timeout: idx?, after: idx?)` | selective receive; with `timeout` (milliseconds) and `after` (body), a receive with a timeout. **R** A3.3. **As built:** T9.13; in tail position only, and **you** put it there (T9.13a) |
| H24 | `(:link, at, to: idx)` | **R** A5.5. **As built:** not written (T9.15) |
| H25 | `(:exit_signal, at, to: idx, reason: idx)` | an exit request to another process. **R** A5.5. Its value is `true`. **As built:** written under `a5_5 supervisor_request` when `reason` is a `(:symbol)` (T9.15) |
| H26 | `(:fail, at, reason: idx)` | end this process with a reason (BEES A5.2). It has no value; it may stand where a value of any type is expected. **As built:** in tail position of a process function (T9.13) with a `(:symbol)` reason, the actor ends with that reason (`(:explicit, reason)`). Anywhere else the actor ends and the reason is not carried (it ends with `badarith`) |
| H27 | `(:try, at, body: idx, clauses: List[idx], catches: List[idx], after: idx?)` | a construct that catches a failure. **R** A5.1 |
| H38 | `(:register, at, name: bin, process: idx)` | give a process a name. **Provisional**: rests on Silica's atom-keyed registry. Its value is `true`. **As built:** written only when `process` is a `(:spawn)` with literal arguments: a **static child** of the unit's supervisor (T9.14b). **R** A4.4 through that `(:spawn)` |
| H39 | `(:send_named, at, name: bin, message: idx)` | send to a registered name. **R** A5.4. Its value is the message, as a `(:send)`'s is (H22). **As built:** T9.14c |

- **T9.7** Every H-node may be the target of an override (§7.3) for the requirements its row lists, and of a hint (§8.4).

### 9.4a Processes, as built

**Provisional (2026-11-13).** This is what the first printer writes for H20 to H26, in either profile, and what
you must send for it. A node outside these rules is not written: its function becomes a failing stub with a
`T4002` diagnostic that names the node and its place. The app design §5.5 says what the Silica looks like.

- **T9.12** **Messages.** The messages of all the processes of one unit are written as one Silica sum of tagged
  tuples. So a message, in a `(:send)` and as the pattern of a receive clause, is one of:
  - a `(:symbol)` (`stop`), or a value whose stated type is a symbol type. In a `(:send)` the hint on a
    `(:symbol)` may also state a sum that has that symbol (a typed language's message type, for a constructor of
    no fields: `Stop` of `Ping(..) | Pong(..) | Stop`); the message is then the symbol;
  - a `(:tuple)` whose first element is a `(:symbol)`, with a hint whose type is a `(:t_tagged, tag, elems)` of
    that symbol (T8.10 e). In a `(:send)` the hint may also state a sum that has that tagged tuple (a
    `(:t_union)`, or a `(:t_named)` that declares one: a typed language's message type); the message is then the
    alternative of the tuple's symbol and size. (**As built**, a receive clause's pattern needs the
    `(:t_tagged)` itself.) **A tag has one type in a unit:** every `(:t_tagged)` you state for the tag `add` in a
    unit must have the same element types (**not checked:** two types for one tag are written as two alternatives
    of the unit's message sum. **As measured 2026-11-13**, the Silica compiler accepts such a sum, and a `case`
    over it then takes a wrong value or ends the program with a memory fault when a message with that tag
    arrives: limitation observed. `{reply, {ok, N}}`, `{reply, {refused, N}}` and `{reply, {Text, N, F}}` in one
    unit are three types for the tag `reply`: give each its own tag. **Open:** whether the transpiler reports it,
    and with which code).

  Any other message (an integer, a tuple that starts with no symbol, a record, a list, a variable or `_` as the
  pattern of a receive clause, which would take any message) is not written. **Processes of different units of a
  session cannot exchange messages** (each unit has its own sum; **not checked**: such a send is written and its
  message is not understood). A `(:send)` whose value is used (it is the message) is written only when the message
  holds no call.
- **T9.13** **Receive.** A `(:receive)` is written only in **tail position** of its function: the function's body
  is the receive, or ends with it (after statements, or inside the clauses of a `(:case)` or `(:cond)` in tail
  position), and each receive clause in turn ends with a value (the process ends), with a call in tail position
  (the process goes on in that function), or with another receive in tail position. A receive whose value is used
  by code of the same function after it is not written, and will not be: **you split the function (T9.13a)**.
  A function with a receive is a **process
  function**: it is written as a Silica actor's phases, not as an ordinary function, and it runs only as a
  process: spawned (T9.14), as the entry (T9.6), or called in tail position by a function that is running as a
  process. An ordinary call of it from anywhere else compiles and fails when it is reached (a `T4002` diagnostic
  on the unit says so when the transpiler sees one). The value a process function ends with goes to nobody, so its
  result type need not be one the printer can write. (An ordinary function that calls a process function whose
  result type the printer cannot write is itself made a failing stub when the unit is complete, with the same
  `T4002` on the unit.) A function that does not receive and has a tail call is written twice, as an ordinary
  function and as a piece a process can go on in; **an ordinary call of a process function that stands only in
  the ordinary version of a function that is not exported, and that nothing calls as an ordinary function, is
  not reported** (it is code nobody reaches: the pieces of T9.13a are such functions).
  - **Guards.** A receive clause's guard is written (T8.16 for type tests).
  - **Timeout.** `timeout` must have an integer type; `after` is in tail position. A timeout of 0 runs `after`
    when no message that is already waiting is taken.
  - **Selective receive is not kept.** A message that no clause of the receive a process waits in takes is
    **dropped**; your language may keep it for a later receive. For a function with one receive that goes on only
    in itself (a loop) or ends, with guards that test only the message, that is the same thing. For any other
    process function (more than one receive, or a tail call of another function) the function is written and a
    `T4004` diagnostic of severity `:warning` says that a message may be dropped where your language keeps it.
    (**Not covered by the warning:** a guard that tests a variable of the process, which in your language can
    make a message wait until that variable changes.)
- **T9.13a** **You split a function at a receive; the transpiler does not** (decided 2026-11-13). What your
  language does around a receive is your language's: in Erlang the code before a receive runs once when the
  process starts, the code after it runs in the same process with the variables it had, and a process may
  receive several times in one function. The transpiler has one shape for it, T9.13's, and you send that shape:
  - **Code before the receive** stays in the function, before the `(:receive)`. It is run by the new process
    when it starts (the spawner sends it its start message right after the spawn, T9.14), so `(:self)` there is
    the new process and a `(:send)` there may ask for what the receive waits for. Nothing is to be done.
  - **Code after the receive** is sent as a **function of its own** (a continuation). Its parameters are the
    variables the code uses that have a value at the receive, and the receive's value when the code uses it;
    you state their types in its signature hint as for every function (T8.10 a). Each clause of the receive
    (and its `after`) ends with a `(:call)` of that function in tail position. The function is not exported.
  - **Several receives** in one function: one continuation for each.
  - **A call of a function that receives, with code after it**: the caller's process must go on when the callee
    is done, so you send a copy of the callee whose every end is a tail call of the continuation (with the
    continuation's variables as extra parameters), and call the copy in tail position.
  - **The state a waiting process keeps** is every variable that has a value at the `(:receive)` (the printer
    keeps them all, at most six: it does not work out which are used). To keep fewer, send the receive as the
    whole body of a function whose parameters are the variables it uses.
  - A receive **inside an expression** (an argument, an operand, a tuple element) has no such shape: bind its
    value first in your own lowering, or send a gap.

  A `(:receive)` that is not in tail position is answered `T4002` with its place, and the message says that
  the sender must split the function. What a continuation is named is yours (T9.11: not `<name>__spawn`,
  `<name>__spawn_watched`, `<name>__` or `to_silica_…`). The Erlang proof of concept does all of this in
  `erlang-to-silica-poc/src/e2s_split.erl`. **Not your language's behaviour after the split:** selective
  receive (T9.13: a function you split has more than one receive or goes on in another function, so it gets
  the `T4004` warning).
- **T9.14** **Spawn.** `fun` must be a `(:fun_ref)` to a function of the same unit with `args` (one for each
  parameter, each with a stated type), or a `(:lambda)` with one clause, no parameters and no guard whose body is
  one `(:call)` of a function of the same unit (its arguments are evaluated by the spawner, before the process
  starts; each needs a stated type) and no `args`. At most seven arguments. Any other `fun` is not written (it
  needs closures). `link` `true` is not written (T9.15). The new process is a child of the unit's supervisor with
  the restart policy of your `a4_4` choice: under `transient` a process that ends with a failure is **started
  again from its first state** (it runs to its first receive when its next message arrives), and under
  `permanent` so is one that ends normally. If your language never restarts a process, choose `temporary`. A
  unit can hold `pool_size` live processes
  (`a4_2`, 1024 when you state none); one spawn more ends the spawner, and with it the process that asked.
  A `(:spawn)` that is the `process` of a `(:register)` is a static child (T9.14b), not this.
- **T9.14b** **A static child: a supervisor whose child list is fixed when it starts** (decided 2026-11-14; BEES
  A4.4, Silica's `Supervisor` behaviour). A `(:register, at, name, process)` whose `process` is the index of a
  `(:spawn)` of T9.14's shape (`link` `false`) **whose every argument is a literal** (`(:int)`, `(:float)`,
  `(:symbol)`, `(:boolean)`) states a child that the unit's supervisor **has in its child list from the moment it
  starts**: it is written into the supervisor's own list of children (Silica: the list its `init` answers), not
  added while the program runs, and it takes no child id from the pool of `a4_2`.
  - **Name.** `name` is the child's id and the name it is registered under (Silica registers a supervised child
    under its child id). It must be an identifier (T9.11) and one child of a unit has it (**not checked:** two
    different static children of one name are both written, and the unit's supervisor then fails when it starts).
    The same node sent in two places is one child.
  - **Restart and strategy: yours, per child.** An `a4_4` override (T7.6) on the `(:spawn)` node states this
    child's `restart` (`permanent`, `transient`, `temporary`); with no override it is the session's `a4_4`. So a
    static child's restart policy is what your source's child specification says, whatever the session's default
    for an ordinary `(:spawn)` is. The override's `strategy` is the strategy of the child's supervisor in your
    source; **as built** a unit has one supervisor, whose strategy is the session's `a4_4` `strategy`, so an
    override that states another strategy is not followed and is named in the unit's `T2001` diagnostic (T7.5).
    **Not carried:** how many restarts in how long a supervisor allows (Erlang's `intensity` and `period`): BEES
    A4.4 has no parameter for it, and the unit's supervisor allows 100 restarts in 10 seconds.
  - **When it starts.** The child is in the list, and its name is registered, as soon as the unit's supervisor
    starts (T9.6: in `main`, or in `to_silica_start()`), **whether or not the `(:register)` node is ever reached.**
    It has not run yet: where the program reaches the node, the child is sent its start message and runs to its
    first receive (T9.13a, "code before the receive"); a message sent to its name before that starts it too.
    Reaching the node again does nothing more (when the child has ended and is not started again, the process
    that reaches it ends, as for a send to its name, T9.14c). The node's value is `true`.
  - **When it ends.** As T9.14 with this child's restart policy: started again from its first state, with the
    literal arguments, and **registered under the same name again** (it is a new process: a `(:t_actor)` value
    of the old one is dead). A static child that has ended and is not started again keeps its row in the
    supervisor's list, and no process is registered under its name.
  - **What it is for.** Send your language's static supervisor (Erlang: a `supervisor` callback module whose
    `init/1` answers a child list; Elixir: a module with `use Supervisor` whose `init/1` ends in
    `Supervisor.init(children, strategy: …)`) this way: where your source starts the supervisor, send one such node for each
    child, in the list's order. Your source's supervisor process is not a process of the output: its children are
    the unit's supervisor's, beside the unit's other processes, so the supervisor itself has no `(:t_actor)` value
    and cannot be sent to, stopped or asked for its children (send a gap for those).
  - Any other `(:register)` (a `process` that is a variable, a `(:self)`, a `(:spawn)` with an argument computed
    when the program runs) is **not written** (`T4002`): Silica gives a supervised process its name when it is
    added, and a running process cannot be given one.
- **T9.14c** **Send to a registered name.** `(:send_named, at, name, message)` is a `(:send)` (H22, T9.12) whose
  destination is the process registered as `name`: **as built**, a static child of the same unit (T9.14b; no
  other process has a name). `name` must be an identifier. Its value is the message. With no process registered
  under the name (the child has ended and is not started again; no static child has that name) **the sender
  ends** (`a5_4 accept_sender_death`), as for a `(:send)` to a process that has ended.
- **T9.15** **Links and exit requests.**
  - `(:exit_signal)` is written when your hello's `a5_5` is `supervisor_request` and `reason` is a `(:symbol)`.
    The reason `normal` does nothing (a process that does not trap exits takes no notice of it). Any other symbol
    ends the process: the unit's supervisor is asked to end the child and to drop it, so it is **not** started
    again whatever `a4_4` says. **The reason is not carried** to the process or to anyone (BEES A5.5, open), and
    nothing that is written can observe it. A process that has ended already, or is no process of the same unit,
    is not found, and nothing happens. A `reason` that is not a symbol literal is not written (`T4002`): whether
    the request does anything must be known when the unit is written. Under any other `a5_5` it is not written.
  - `(:link)` and a `(:spawn)` with `link` `true` are not written (`T4002`), whatever `a5_5` says:
    `supervisor_request` gives a link no meaning, and `silica_link` is not built. Trapping exits has no node. Send
    a gap or the node; the result is the same failing stub. **Or lower it yourself** with the nodes that are
    written, and say in your documentation what your lowering does not keep: the Erlang proof of concept sends
    a process that traps exits and its `spawn_link` as an unlinked `(:spawn)` of a copy of the child's function
    that sends its parent the message `{'EXIT', self(), Reason}` when it ends by a value or by an `exit(Atom)`
    written in the source (`erlang-to-silica-poc/README.md`, "Processes: what this sender splits").

- **T9.17** **A node program: several nodes that send messages to each other** (added 2026-11-16; BEES BEAM mode with
  EPMD). One program is one node. A sender that knows the node its source runs on sends **one `(:node, NodeDecl)`
  form** in the unit that holds the program's functions (any position among the forms; one per session; a second is
  ignored). It carries no code. The transpiler writes **two files beside the unit's**, which BEES reads
  (BEES compiler guide N1 and B1b):

  | Field | Meaning | In the output |
  | --- | --- | --- |
  | `name` | the node's name, `hub@localhost` (short name: BEAM mode) | `node` line; `bees.config` `{node, [{name, ...}]}` |
  | `timing.creation` | an integer, normally 1 | `creation` line |
  | `net.listen_address`, `net.listen_port` | where this node listens; port 0 is ephemeral, registered with EPMD | `{listen_address, ..}`, `{listen_port, ..}` |
  | `net.epmd_port` | the EPMD's port, 4369 for OTP's | `{epmd, external}`, `{epmd_port, ..}`; a peer's port is looked up there (`{port, epmd}`) |
  | `net.cookie_file` | the file holding the shared cookie | `{auth, cookie}`, `{cookie_file, ..}` |
  | `timing.net_ticktime_s` | 4 to 3600 (OTP's default 60) | `{net_ticktime_s, ..}` |
| `timing.redial_initial_ms`, `timing.redial_max_ms` | BEES has no default for redial (its N2c), so the node states it: on a node with a `dial` peer, both `0` (a lost link stays down: `{redial, false}`) or the first delay 10 to 60000 and the most it grows to, from the first delay to 600000 (`{redial, true}, {redial_initial_ms, ..}, {redial_max_ms, ..}`); on a node with no `dial` peer, both `-1` (not stated), because BEES refuses redial there. Anything else is `:bad_node` | `{redial, ..}` in the `beam` list |
  | `tables.peers` | `{ name, host, port, role: :dial \| :listen }` for each node this one talks to; `port` 0 means "through EPMD". `host` is an address or a name BEES resolves | `peer` lines, and `{peers, [...]}` in `bees.config` |
  | `tables.remotes` | `{ name, peer, tag, fields }`: a registered name on `peer`; a send to it is a cast | `remote <name> @ <peer> cast (atom, F1, ...)` |
  | `tables.locals` | `{ name, tag, fields }`: a registered name here that a peer may cast to | `local <name> cast (atom, F1, ...)` |

  (The fields are grouped in records of at most four because Silica's derived decoder takes no more: `contract/tools/README.md`.)

  The files are `<silica_unit>.wire` (the manifest), `<silica_unit>.bees.config` and `<silica_unit>.atoms` (every atom the unit writes as a literal, one a line: BEES compiler guide A1.2, so that the atoms exist in the unit and in BEES's `bees_atoms`; written for every unit of a session that has a node declaration). The mode is always BEAM mode with
  `{epmd, external}` and a cookie (TRUST mode is not written). `fields` are Silica type texts of BEES's wire subset
  (wire-v1 5.3: `int64`, `float64`, `boolean`, `atom`, `string`, ...), one for each field of the message after the tag;
  the sender states every field's type (§8.6) and the transpiler checks only the characters (`:bad_node`).
  - **What crosses is a registered name and a tagged tuple.** A message to a remote name is `{tag, field, ...}`, the
    tagged tuple of T9.12; BEES's wire carries it as the tuple `(atom, field, ...)`, the same value, so a process
    that receives under a `local` name needs no adapter. **Send it as `(:send_named, name, message)`** (H39, T9.14c): a
    remote name is written exactly as a local one, because BEES registers a proxy under it (BEES N1). A pid does not
    cross a node; a request names the registered name its answer is to go to, as an atom or text field, and the
    answering process chooses the `(:send_named)` to the remote name by that field (BEES N4: no call across nodes).
  - **A remote name is not checked against the declaration.** `(:send_named)` is written the same whether the name is
    local, a static child, or declared remote; a name nobody registered ends the sender (T9.14c). A `local` name
    needs a process registered under it (T9.14b): BEES does not (compiler guide N2.3).
  - **Not built here** (reported as gaps by the senders): sending to a pid on another node, `spawn` on another node,
    monitors and links across nodes, `nodedown`, `net_kernel`, `global`, `rpc`.
  - **What the output is not.** The files are the node's configuration; the node's root unit, its start-up and the
    TCP carrier are BEES's (`tools/bees_edge_gen.py`, compiler guide N2.1 and N2.2); `tools/node_kit/build_node.sh`
    writes them for a unit the sink printed. BEES owns `main`, so a node program's entry is a function other than
    `main/0` (the examples use `run/0`), which the root starts. BEES connects **every `peer`
    line** (BEAM mode, BEES N2b): a `dial` peer is dialed, and all `listen` peers share the node's one listener, so a hub
    holds a link to each of its edges (run live 2026-11-17). A peer host is an IPv4 literal or a name; a node that dials
    a name is built with BEES's resolver edge (`bees_edge_gen.py --resolve`, which `build_node.sh` adds; run live
    2026-11-18).

### 9.5 Nodes: the low-level vocabulary

Low-level nodes are already in Silica's shape. Use them where a choice is `:other`, where no high-level node fits, or
where you want exact control. **Provisional:** this vocabulary grows by minor versions of the contract.

| Id | Node | Meaning |
| --- | --- | --- |
| L1 | `(:sl_call, at, unit: bin, name: bin, args: List[idx])` | a call to a function of a BEES unit (BEES Part B) or a Silica builtin (`send_after`, `cancel_timer`, `monotonic_time`, `current_time`, …) by its Silica name; `unit` is empty for a builtin. Only the units and builtins the app design §5.4 lists are allowed. **As built:** the print builtins of T9.16 only |
| L2 | `(:sl_cast, at, to: idx, message: idx)` | Silica's `cast`: the sender dies if the recipient has ended (BEES A5.4) |
| L3 | `(:sl_spawn_child, at, supervisor: idx, pool: bin, behaviour: bin, state: idx, policy: { reserve: int64, release: bin, state_policy: bin })` | add a child under a supervisor with an id from a pool (BEES A3.2, A4.2) |
| L4 | `(:sl_fail_self, at, reason: idx)`, `(:sl_stop_self, at)` | allowed only directly in a behaviour (BEES A5.2) |
| L5 | `(:sl_phase, at, phase: int64, saved: List[idx], resume: bin)` | end the dispatch here and resume in the function `resume` at `phase`, with `saved` in the state (a hand-made A3.3) |
| L6 | `(:sl_yield, at, resume: bin, saved: List[idx])` | end the dispatch and continue through a message to self (a hand-made A3.4) |
| L7 | `(:sl_behaviour, at, state_type: idx, message_type: idx, body: idx)` | marks a function as an actor behaviour with these state and message types (indices into `types`) |

- **T9.8** Low-level nodes must keep BEES's rules that only the program's author can keep: L4 only directly in a
  behaviour; L5 and L6 only in a behaviour; L3 only with a pool declared by the session. A breach is `:low_level`. The
  transpiler still applies every mechanical rule of §1 to low-level code.
- **T9.16** **L1, as built (2026-11-13).** Of the low-level nodes the printer writes **only `(:sl_call)` of a
  Silica builtin that prints**, with `unit` the empty binary (a builtin belongs to no unit) and one argument:

| `name` | Argument's stated type | The call's type | Writes |
| --- | --- | --- | --- |
| `print` | `text` or `bytes` (a Silica `string`) | `symbol` (Silica's `atom`) | the text |
| `println` | the same | `symbol` | the text and a line end |
| `print_int64` | `(:t_int, :i64)` | `symbol` | the integer in decimal |
| `print_float64` | `(:t_float, :f64)` | `symbol` | the float (Silica writes the whole part and at most 15 decimal places, cut and not rounded: limitation observed; no builtin writes the shortest text that reads back) |
| `print_boolean` | `boolean` | `symbol` | `true` or `false` |
| `atom_name` | `symbol` (or a `(:t_symbols)`) | `text` | nothing: its value is the symbol's name |

  The call's type and its argument's are the builtin's own, fixed by Silica as an operator's are (T8.9): no
  hint is needed on the `(:sl_call)`, and a hint must agree. The argument needs a stated type (T8.10 e;
  `T3101` when none); an argument of another type is `T3103` (nothing is converted: send `to_float`, or the
  builtin for the type). The call is written as a call of a helper function `to_silica_b_<name>` that declares
  the `device_io` effect, so it may stand anywhere an expression may, also in a process. Any other `name`, a
  non-empty `unit` (a BEES unit) and every other low-level node (L2 to L7) are **not written**: `T4002`, and
  the function becomes a failing stub. **This is how a language's own output is sent**: your codex turns your
  language's formatting (Erlang's `io:format` with its control sequences) into these calls; a `(:call)` of
  `io:format` is a call to a module outside the session and is not written (T9.9). The checks of T9.8
  (`:low_level` at receipt) are still unbuilt: an `(:sl_call)` the printer does not write is accepted in check
  mode.
- **T9.9** Foreign code is not part of version 1. There is no node for a foreign call, and `dangerous_` units cannot be
  named in L1.

### 9.6 Gaps

- **T9.10** A construct your codex cannot translate is sent as a gap, not left out: a whole form as `(:gap, FormGap)`, or
  one node as `(:gap_node, at, construct: bin, note: bin)` (H40). The transpiler writes a failing stub for it, reports a
  T4001 diagnostic, and counts it in `Result.gaps`. A program with gaps translates and runs until it reaches one.

---

## 10. Versioning

- **T10.1** `Hello.contract` is the contract's major version. A transpiler serves the versions its release lists and
  refuses others (`:contract`).
- **T10.2** **Open:** minor versions (new node kinds, new choices) and how a sender learns which a transpiler serves.
  Proposed: the welcome gains a list of served minor versions.

## 11. Conformance for senders

- **T11.1** **Provisional:** `contract/goldens/` holds golden sessions: for each, a `.frames` file (the bytes a sender
  writes, as `term_to_binary` writes each frame, with its 4-byte length) and an `.expect` file (the replies the
  transpiler must give, reduced to what this contract fixes). Together they hold every message, every node kind and
  type entry, and a frame for each rejection and refusal the transpiler implements. `goldens/README.md` gives the
  format; any sender can replay the bytes, and `goldens.erl` plays them against a transpiler.
- **T11.2** A sender conforms when the BEES conformance programs C01 to C08, written in its language and sent through
  it, pass a check-mode session (§6.5) and then transpile with `status` `:ok`, and the exported output builds with the
  Silica compiler and BEES, passes `tools/conformance.py` in BEES, and its lowering-choices file passes BEES's
  checker (BEES A10).

---

## 12. Worked example

`contract/examples/add_example.erl` is a complete session, frame by frame, for this Erlang program:

```erlang
-module(demo).                                   % line 1
-export([add/2]).                                % line 2
-spec add(integer(), integer()) -> integer().    % line 3
add(A, B) -> A + B.                              % line 4
```

| seq | Frame | What it shows |
| --- | --- | --- |
| none | `{hello, …}` | a `bees` session with one choice per BEES requirement (T7.1) and the recommended hint policy (T8.4) |
| 0 | `{unit_begin, …}` | `silica_unit` `<<"erl_demo">>` starts with the prefix `<<"erl_">>` (T5.2) |
| 1 | `{form, … {function, …}}` | the node table in post-order: patterns `A`, `B` (0, 1), body `A + B` (2, 3, 4), the clause last (5); the `-spec` as a `declared` hint on the signature (node -1) |
| 2 | `{unit_end, …}` | `forms => 1` |
| 3 | `{'end', …}` | no `entry` form, so the session is a library (T9.6) |

`add_example:wire()` gives the bytes, length prefixes included. Every frame passes the checkers of §0 (verified
2026-11-12 with the Erlang binding's checker, and, with the hello's mode set to `check`, by a check-mode session of
the transpiler that ended `ok`: `silica-sink/trials/p0_check_mode`).

A BEAM sender's `term_to_binary/1` writes a list of small integers (most lists of child indices) as `STRING_EXT`
(tag 107), not `LIST_EXT`; the transpiler's decoder accepts it (verified by the same trial).

## Appendix A. ETF for senders

What a sender writes (decoders also accept older spellings; transport §4.7):

| Value | ETF tag |
| --- | --- |
| term prefix | `131` |
| integer 0 to 255 | `SMALL_INTEGER_EXT` 97 |
| integer in signed 32-bit | `INTEGER_EXT` 98 |
| other `int64` | `SMALL_BIG_EXT` 110, at most 8 digit bytes |
| float | `NEW_FLOAT_EXT` 70, IEEE big-endian |
| atom | `SMALL_ATOM_UTF8_EXT` 119 |
| binary | `BINARY_EXT` 109 |
| tuple | `SMALL_TUPLE_EXT` 104 (arity up to 255), `LARGE_TUPLE_EXT` 105 |
| list | `LIST_EXT` 108 ending in `NIL_EXT` 106; the empty list is `NIL_EXT` |
| record (map) | `MAP_EXT` 116, atom keys |
| `true`, `false` | atoms |

A BEAM sender writes `term_to_binary(Term)`. Any other language needs an ETF encoder for this subset and a decoder for
the transpiler's replies (§5.3), which use the same subset.

## Appendix B. Operators

`(:op, at, op, args)` takes one of these spellings. The operands' types are yours to state and must agree (T8.10,
T8.11); the result type is fixed by the operator (T8.9).

| Group | `op` | Operands | Result | Silica written |
| --- | --- | --- | --- | --- |
| arithmetic | `+` `-` `*` | two of one integer type, or two of one float type | that type | `+` `-` `*` |
| arithmetic | `div` `rem` | two of one integer type | that type | `/` `%`: the quotient is cut toward zero and the remainder has the dividend's sign |
| arithmetic | `/` | two of one float type | that type | `/` |
| arithmetic | unary `neg` | one integer or float | that type | `0 - x` |
| conversion | `to_float` `trunc` `round` | one (T8.12) | T8.12 | a helper function written into the unit |
| comparison | `==` `/=` `<` `=<` `>` `>=`, `=:=` `=/=` | two of one type (T8.11) | `boolean` | `==` `!=` `<` `<=` `>` `>=`; `=:=` and `=/=` are written as `==` and `!=`, which is right because both operands have one type |
| boolean | `and` `or` `not`, `andalso` `orelse` | `boolean` | `boolean` | `and` `or` `not` |
| bitwise | `band` `bor` `bxor` `bnot` `bsl` `bsr` | integers | | not written yet (`T4002`) |
| lists and text | `++` (list append), `<>` (byte-string append) | `++`: two lists of one type (T8.11) | `++`: that list type; `<>`: `string` | `<>` is `concat`; `++` is a helper function written into the unit, for lists of `int64`, `float64`, `boolean`, `string`, a symbol type or a process reference (any other element type: `T4002`) |

**Silica's behaviour at the edges** (limitations observed 2026-11-13, compilers 999919 and 999916, Apple Silicon; T8.15 says whose business
they are): integer `div` or `rem` by zero ends the actor (`badarith`); float `/` by zero does not fail and gives a
value that is not a number you can use; integer `+`, `-` and `*` that pass `int64` do not fail and give the
wrapped value (`9223372036854775807 * 4` printed `-4`). BEES A6.6 asks that integer overflow fail the actor: a
sender that needs that sends its own check.

`=:=` between an integer and a float is `false` in Erlang whatever the values: your codex knows both types, so send
`(:boolean, false)` (after evaluating the operands if they have effects), not the operator.

**Open:** whether languages need operators beyond this list, and comparison across types (Erlang's term order).
