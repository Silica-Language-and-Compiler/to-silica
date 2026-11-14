# Decision data: the P0 checks that were not built

2026-11-13, compiler 999919, Apple Silicon. For each item of design phase P0 that the first build left out: what it
is, the contract text it enforces, what a transpiler answers today without it, and what building it takes. Two were
small and unambiguous and are now built; three are not, because the contract text does not yet say enough to build
them without inventing. The demonstrations were run against the build of this date in check mode; each is one
session whose only unusual frame is the one named.

| Item | State | Contract text | Effort |
| --- | --- | --- | --- |
| Counts of `(:unit_end)` and `(:end)` (T1002) | **built** | T5.3b (new), M4, M5 | done |
| Goldens | **built** (22 sessions) | T11.1 | done |
| `:bad_choice` | not built | T5.5, T7.1 to T7.7 | 1 to 2 days once five questions are answered |
| `:low_level` | not built | T5.5, T9.8, T9.9, design §5.4 | half a day for T9.9 and the allow-list; the rest needs a rule the contract lacks |
| A hint on a node that cannot carry one (`:bad_hint`, T8.5) | not built | T5.5, T8.5 | half a day once the list of nodes is fixed |

## 1. Counts (built)

- **What.** `(:unit_end, { …, forms })` says how many forms the unit had; `(:end, { …, units })` how many units.
- **Contract text before.** M4: "`forms` is how many were sent"; M5 none; design §8: "T1002 unit with fewer forms
  than its `unit_end` says". Nothing said what a wrong count does, whether a rejected form counts, or what a check
  session answers.
- **Without it** (the build of 2026-11-12): any number was accepted and ignored; a check session ended `ok`.
- **Built as** contract **T5.3b**: `forms` counts the unit's form frames that used a `seq`, accepted or rejected;
  `units` counts accepted `(:unit_begin)`s. A wrong count does not reject the frame; a `(:diagnostic, …)` with code
  `T1002`, severity `:error`, is sent at once, and the session cannot end `:ok` (`:failed` in check mode, at best
  `:partial` in transpile mode). A frame the decoder refused while a unit was open may have been a form, so either
  count is accepted.
- **Choices made that the user may want to change:** that a wrong count is a diagnostic and not a rejection; that a
  rejected form counts; that check mode, which otherwise sends no diagnostics, sends this one.
- **Tried:** golden `counts_wrong` (check mode: two T1002, `failed`); `p2_actors` (transpile mode: two T1002,
  `partial`, one file). After a resume the counts of a unit that was open across the drop are given the benefit of
  the doubt for frames rejected before the drop (their kind is not stored).

## 2. Goldens (built)

- **What.** `contract/goldens/`: 22 sessions, each a `.frames` file (the sender's bytes) and an `.expect` file (the
  replies, reduced to what the contract fixes). `goldens.erl` generates and plays them; `README.md` gives the format.
- **Contract text.** T11.1 (rewritten to describe what exists).
- **Coverage.** Every message M1 to M7, every form kind, every node H1 to H40 and L1 to L7, every type entry, hint
  strength and policy; `seq_gap`, `unit_order`, `bad_unit_name`, `bad_index`, `bad_hint`, `profile`, four decoder
  reasons, T5.3a, T5.3b; refusals `contract`, `choices`, `bad_hello` (three ways); release of an unknown session;
  abort.
- **Not covered, and why.** `:bad_choice`, `:low_level` (not checked, below). `:no_credit` and `:too_large` (a
  `.frames` file played under credit cannot break the credit rule or the framing; `p0_check_mode` tries
  `too_large`). Transpile-mode replies (they depend on storage; `p2_actors` tries them).
- **Tried:** all 22 play with 0 failures against the build of this date.
- **A limit of the goldens:** the node tables are valid in shape and indices only. They are not meaningful programs,
  so they will need rewriting when `:bad_choice` and `:low_level` are checked (today `ok_every_high_level_node` has a
  `(:send)` under whatever the worked example's hello chose, and `ok_every_low_level_node` has `(:sl_stop_self)` in
  a function that is no behaviour).

## 3. `:bad_choice` (not built)

**What it is.** Validation of lowering choices: in the hello (T7.1 to T7.4), in a form's overrides (T7.6, T7.7),
and of high-level nodes against the effective choice (T7.4).

**What is checked today:** only T7.1 (one choice per requirement, `:choices` refusal).

**What happens today.** Each of these check sessions was welcomed and ended `status ok, rejected 0`:

| # | Frame | Rule it breaks |
| --- | --- | --- |
| 1 | hello: `a4_4` with `params` `[{"bogus_key", "bogus"}]` | T7.3: a wrong key or value is `:bad_choice` |
| 2 | hello: `a3_2` `:lowered` with no `reserve` parameter | T7.3, §5.4 "a missing or extra parameter" |
| 3 | hello: requirement `a4_3` with choice `:phase_field` (a choice of `a3_3`) | §5.4 "a choice that does not belong to its requirement" |
| 4 | hello: `a5_4` `:other` with an empty `note` | T7.4: `note` is required for `:other` |
| 5 | form: an override of `a3_3` on an `(:int)` node | T7.7: the node's construct does not use that requirement |
| 6 | form: a `(:send)` node while the session's `a5_4` is `:other` | T7.4: a high-level node whose effective choice is `:other` |
| 7 | form: two overrides of `a5_4` on one node | T7.6: at most one override per requirement |

**Why it was not simply built.** The text leaves these open:

1. **A bad choice in the hello: refusal or rejection?** `:bad_choice` is a rejection reason (R5, §5.4), and a
   rejection needs a session; the hello is answered by welcome or refusal, and the refusal reasons (T5.6) have
   `:choices` only for "missing or given twice". Is a wrong parameter in the hello `(:refused, :choices)`,
   `(:refused, :bad_hello)`, or a new refusal reason?
2. **The parameter tables.** T7.2 lists keys per requirement and T7.3 says the keys and values are BEES's
   (`contract/conformance/lowering-choices.md` in BEES). Which keys are required and which optional for each choice
   (T7.2 marks only `budget` optional), and which values are legal (`restart`: `permanent | transient | temporary`?
   `release`: the five Silica algorithms? is `reserve` any integer text?) would have to be copied from BEES's
   checker into the transpiler, and kept in step with it.
3. **Which constructs use which requirement** is in the H-table's **R** column, but only for the node that is the
   construct. Does an override on a `(:clause)` inside a `(:receive)` count as on the receive? (As written: no.)
4. **`:not_applicable`** for a requirement, with a node in the session that uses it: `:bad_choice` like `:other`,
   or a gap (T7.5 makes a node under an unimplemented choice a gap)?
5. **Overrides in a `:silica` session** for requirements that do not apply there (T7.1 says nine of the eleven
   "must be absent" from the hello; nothing says an override of one is `:bad_choice`).

**Effort once answered:** one unit of table lookups beside `ts_check` (the node walk exists); 1 to 2 days with
goldens. It adds no frame type, so it does not touch the schema or the senders, except that a sender that sends a
wrong parameter today, unnoticed, would start being refused. None of the three proof-of-concept senders was checked
against BEES's parameter tables.

## 4. `:low_level` (not built)

**What it is.** T9.8: L4 (`sl_fail_self`, `sl_stop_self`) only directly in a behaviour; L5, L6 only in a behaviour;
L3 only with a pool the session declared. T9.9: no `dangerous_` unit in L1. Design §5.4: L1 may name only the units
and builtins of an allow-list.

**What happens today.** Each of these was welcomed and ended `status ok, rejected 0`:

| # | Frame |
| --- | --- |
| 8 | `(:sl_stop_self)` in a function with no `(:sl_behaviour)` node |
| 9 | `(:sl_call)` naming `dangerous_sockets`, and one naming `no_such_unit` |
| 10 | `(:sl_spawn_child)` with pool `undeclared_pool` |

**What could be built now (half a day):** T9.9 (a unit name starting `dangerous_` in L1) and the allow-list of
design §5.4, which is a fixed list in the transpiler. Not built in this pass because the allow-list itself is
provisional ("the BEES units of BEES Part B and … the list operations") and has never been written out name by
name; a wrong list would reject valid senders.

**What cannot be built from the text:**

1. **"Directly in a behaviour."** A function is a behaviour when it holds an L7 `(:sl_behaviour)` node, but the
   node table is flat: nothing says where in the function L7 must be, or what "directly" means for L4 in terms of
   the table (not inside a `(:lambda)`? not inside a `(:case)` clause? BEES A5.2 is about Silica source, not about
   node tables).
2. **"A pool declared by the session."** The contract has no frame or field that declares a pool. The `a4_2`
   choice has `pool_size` (and `fanout`, `leaf_size`) but no pool names, and L3's `pool` is a free binary.

**Effort once answered:** half a day for T9.9 and the allow-list; half a day more for L4 to L6 given a definition;
L3 needs a contract addition first.

## 5. A hint on a node that cannot carry one (T8.5, not built)

**What it is.** T8.5 lists where a hint may go: "a variable's binding, a function's clause pattern, a record or
tuple construction, a message in a send or a receive clause", and `-1` for the signature, "given as a `(:t_fun, …)`
type". T5.5: "`:bad_hint`: a hint on a node that cannot carry one, or a type index out of range".

**What is checked today:** the indices only (golden `reject_bad_hint`).

**What happens today.** Demonstration 11: a hint on a `(:clause)` node, and a hint on the signature whose type is
`(:t_int, :i64)`, not a `t_fun`: welcomed, `status ok`. (In transpile mode the printer then reports the second as a
gap: "the hint on its signature is not a function type".)

**Open in the text:** whether T8.5's list is complete. T9.7 says "every H-node may be the target … of a hint", which
contradicts a closed list; a node's role (a `(:var)` as a binding or as a use, a `(:tuple)` as a pattern or as a
construction) is not in the node itself (§9.4: "which one a node is follows from where it is referenced"), so the
check needs the walk from the clauses down that the printer does, not the flat walk `ts_check` does.

**Effort once answered:** the signature half (node -1 must be a `t_fun` whose parameter count is the arity) is an
hour and is unambiguous in spirit, but it changes what check mode accepts for senders that hint a signature with
anything else, so it was left for the decision. The node half is half a day.

## Also not built: `:no_credit` in practice

`:no_credit` (T6.2) is implemented. In check mode it cannot happen unless a sender ignores its credit, because the
window is refilled as frames are processed. In transpile mode credit now follows storage (T6.3), so a sender that
sends more than 64 frames without reading replies will meet it; no trial sends without credit on purpose.

## Summary for the decision

- Building `:bad_choice` needs answers 1 to 5 of §3; the largest is where the parameter tables live (copied into
  the transpiler, or read from BEES at build time).
- Building `:low_level` needs a definition of "directly in a behaviour" over node tables and a way to declare
  pools; T9.9 and the allow-list can be built as soon as the allow-list is written out.
- T8.5 needs a ruling between its own closed list and T9.7.
- Until then a check-mode `ok` does not mean the choices, overrides, low-level nodes and hint positions of a session
  are valid; it means shapes, indices, order, names, counts and profile are.
