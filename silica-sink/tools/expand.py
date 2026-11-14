#!/usr/bin/env python3
"""expand.py: writes the transpiler's *.silica units from silica-sink/src/*.silica.in.

Silica has no type aliases: every type is spelled out where it is used. The contract's frame types are large, so the
transpiler's sources are written with $NAME$ placeholders for them and this script spells them out. The generated
.silica files are what the Silica compiler reads; edit the .silica.in files, never the .silica files.

The placeholder texts below are checked against the normative schema, contract/tcp_transport_v1.silica: the expansion
of $TO_TRANSPILER$ must equal the type in the schema's decode_to_transpiler signature (comments and white space
aside), or this script fails. So the transpiler's types cannot drift from the schema.

The pools are also spelled out here, because a store region is one `carried_on` declaration, an actor's child id is
one atom literal, and Silica has neither loops over declarations nor atoms made at run time:

  TS_STORE      memory (default) or backing: the medium of the store regions (app design 3.3)
  TS_STORE_DIR  backing only: the directory of the <name>.sildat files (a literal in the program; default
                /var/lib/to-silica)
  TS_REGIONS    how many regions, so how many transpile sessions at once (default 4)
  TS_CAPACITY   bytes per region, a multiple of 4096 (default 8388608 for memory, 67108864 for backing)
  TS_SESSIONS   how many session actors, so how many connections at once (default 8)

Usage: python3 silica-sink/tools/expand.py <output-directory>     (build.sh passes its build directory)
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "src")
SCHEMA = os.path.join(HERE, "..", "..", "contract", "tcp_transport_v1.silica")

STORE = os.environ.get("TS_STORE", "memory")
if STORE not in ("memory", "backing"):
    raise SystemExit("expand.py: TS_STORE must be memory or backing")
STORE_DIR = os.environ.get("TS_STORE_DIR", "/var/lib/to-silica")
REGIONS = int(os.environ.get("TS_REGIONS", "4"))
CAPACITY = int(os.environ.get("TS_CAPACITY", "8388608" if STORE == "memory" else "67108864"))
SESSIONS = int(os.environ.get("TS_SESSIONS", "8"))
if not (1 <= REGIONS <= 16 and 1 <= SESSIONS <= 64 and CAPACITY % 4096 == 0 and CAPACITY >= 65536):
    raise SystemExit("expand.py: TS_REGIONS 1..16, TS_SESSIONS 1..64, TS_CAPACITY a multiple of 4096, at least 65536")
if '"' in STORE_DIR or "\\" in STORE_DIR:
    raise SystemExit("expand.py: TS_STORE_DIR must not hold a quote or a backslash")

M = {}
M["LI"] = "List[int64, mem(normal)]"
M["LS"] = "List[string, mem(normal)]"
M["LII"] = "List[(int64, int64), mem(normal)]"
M["LSI"] = "List[(string, int64), mem(normal)]"
M["LSS"] = "List[(string, string), mem(normal)]"
M["RX"] = "{ mode: atom, expected: int64, pending: string }"
M["REQ"] = ":a3_2 | :a3_3 | :a3_4 | :a4_2 | :a4_3 | :a4_4 | :a5_1 | :a5_4 | :a5_5 | :a6_8 | :a7_1"
M["CHOICENAME"] = (":lowered | :default | :phase_field | :continuation_table | :back_edge | :budget_counter | :none | "
                   ":single_pool | :pool_tree | :one_per_shape | :uniform_shape | :chosen | :result_values | "
                   ":result_variants | :mixed | :rejected | :proxy | :liveness_check | :accept_sender_death | "
                   ":silica_link | :supervisor_request | :not_supported | :lookup_tables | :module_table | "
                   ":own_dispatch | :other | :not_applicable")
M["POLICY"] = ":trust | :check | :advisory"
M["CHOICE"] = "{ requirement: $REQ$, choice: $CHOICENAME$, params: $LSS$, note: string }"
M["CHOICES"] = "List[$CHOICE$, mem(normal)]"
M["SENDER"] = "{ language: string, prefix: string, codex: string, codex_version: string }"
M["HINTPOL"] = "{ proven: $POLICY$, declared: $POLICY$, inferred: $POLICY$ }"
M["RUN"] = "{ mode: :transpile | :check, max_frame: int64 }"
M["OPTIONS"] = "{ profile: :bees | :silica, choices: $CHOICES$, hints: $HINTPOL$, run: $RUN$ }"
M["HELLO"] = "{ contract: int64, session: string, sender: $SENDER$, options: $OPTIONS$ }"
M["UNITBEGIN"] = "{ seq: int64, unit_name: string, silica_unit: string, source: string }"
M["SPAWNPOL"] = "{ reserve: int64, release: string, state_policy: string }"
M["NODE"] = " | ".join([
    "(:int, int64, int64)", "(:float, int64, string)", "(:text, int64, string)", "(:bytes, int64, string)",
    "(:symbol, int64, string)", "(:boolean, int64, boolean)", "(:nil, int64)", "(:tuple, int64, $LI$)",
    "(:cons, int64, int64, int64)", "(:list, int64, $LI$, int64)", "(:map, int64, $LII$, int64)",
    "(:record, int64, string, $LSI$, int64)", "(:field, int64, int64, string)", "(:bits, int64, $LI$)",
    "(:segment, int64, int64, int64, int64, :integer | :float | :binary | :utf8, boolean, :big | :little)",
    "(:var, int64, string)", "(:wild, int64)", "(:match, int64, int64, int64)", "(:block, int64, $LI$)",
    "(:case, int64, int64, $LI$)", "(:clause, int64, $LI$, int64, int64)", "(:cond, int64, $LI$)",
    "(:op, int64, string, $LI$)", "(:call, int64, string, string, $LI$)", "(:apply, int64, int64, $LI$)",
    "(:apply_mfa, int64, int64, int64, $LI$)", "(:fun_ref, int64, string, string, int64)", "(:lambda, int64, $LI$)",
    "(:loop_hint, int64, int64)",
    "(:self, int64)", "(:spawn, int64, int64, $LI$, boolean)", "(:send, int64, int64, int64)",
    "(:receive, int64, $LI$, int64, int64)", "(:link, int64, int64)", "(:exit_signal, int64, int64, int64)",
    "(:fail, int64, int64)", "(:try, int64, int64, $LI$, $LI$, int64)", "(:register, int64, string, int64)",
    "(:send_named, int64, string, int64)",
    "(:gap_node, int64, string, string)",
    "(:sl_call, int64, string, string, $LI$)", "(:sl_cast, int64, int64, int64)",
    "(:sl_spawn_child, int64, int64, string, string, int64, $SPAWNPOL$)",
    "(:sl_fail_self, int64, int64)", "(:sl_stop_self, int64)", "(:sl_phase, int64, int64, $LI$, string)",
    "(:sl_yield, int64, string, $LI$)", "(:sl_behaviour, int64, int64, int64, int64)"])
M["NODES"] = "List[$NODE$, mem(normal)]"
M["TYPENODE"] = " | ".join([
    "(:t_int, :i8 | :i16 | :i32 | :i64 | :u8 | :u16 | :u32 | :u64)", "(:t_float, :f32 | :f64)",
    "(:t_basic, :boolean | :char | :text | :bytes | :symbol | :dynamic)",
    "(:t_symbols, $LS$)", "(:t_tuple, $LI$)", "(:t_tagged, string, $LI$)", "(:t_record, $LSI$)", "(:t_list, int64)",
    "(:t_union, $LI$)", "(:t_fun, $LI$, int64)", "(:t_actor, int64)", "(:t_named, string, $LI$)",
    "(:t_var, string)"])
M["TYPES"] = "List[$TYPENODE$, mem(normal)]"
M["HINT"] = ("{ node: int64, type: int64, strength: :proven | :declared | :inferred, "
             "policy: :default | :trust | :check | :advisory }")
M["HINTS"] = "List[$HINT$, mem(normal)]"
M["OVERRIDE"] = ("{ node: int64, requirement: $REQ$, choice: $CHOICENAME$, "
                 "detail: { params: $LSS$, note: string } }")
M["OVERRIDES"] = "List[$OVERRIDE$, mem(normal)]"
M["FHEAD"] = "{ name: string, arity: int64, exported: boolean, file: string }"
M["CODE"] = "{ locations: $LII$, nodes: $NODES$, clauses: $LI$ }"
M["NOTES"] = "{ hints: $HINTS$, overrides: $OVERRIDES$ }"
M["FUNCTION"] = "{ head: $FHEAD$, code: $CODE$, types: $TYPES$, notes: $NOTES$ }"
M["TYPEDECL"] = ("{ head: { name: string, params: $LS$, exported: boolean, file: string }, at_line: int64, "
                 "types: $TYPES$, root: int64 }")
M["ENTRY"] = "{ function: string, arity: int64 }"
M["FORMGAP"] = "{ name: string, place: { file: string, line: int64 }, construct: string, note: string }"
M["BODY"] = "(:function, $FUNCTION$) | (:type, $TYPEDECL$) | (:entry, $ENTRY$) | (:gap, $FORMGAP$)"
M["FORM"] = "{ seq: int64, unit_name: string, body: $BODY$ }"
M["UNITEND"] = "{ seq: int64, unit_name: string, forms: int64 }"
M["END"] = "{ seq: int64, units: int64 }"
M["TO_TRANSPILER"] = ("(:hello, $HELLO$) | (:unit_begin, $UNITBEGIN$) | (:form, $FORM$) | (:unit_end, $UNITEND$) | "
                      "(:end, $END$) | (:abort, { reason: string }) | (:release, { session: string })")
M["DECODED"] = "(:ok, $TO_TRANSPILER$) | (:rejected, atom)"
# The transpiler's replies (R1..R9), as in the schema's decode_to_sender.
M["FLOW"] = "{ resume_from: int64, credit: int64, max_frame: int64 }"
M["WELCOME"] = "{ session: string, contract: int64, transpiler: string, flow: $FLOW$ }"
M["REFUSED"] = ("{ reason: :contract | :session_mismatch | :unknown_session | :busy | :choices | :bad_hello, "
                "detail: string }")
M["REJECTED"] = "{ seq: int64, reason: atom, where: string }"
M["COUNTS"] = "{ units: int64, gaps: int64, rejected: int64 }"
M["RESULT"] = "{ status: :ok | :partial | :failed, counts: $COUNTS$, session: string, files: int64 }"
# The transpiler's own records (not on the wire).
M["SESS"] = ("{ s: { phase: int64, silica: boolean, prefix: string, max_frame: int64, miscounts: int64, floor: int64 }, "
             "q: { next: int64, credit: int64, open: string, names: string, forms: int64, blind: int64, marked: boolean }, "
             "n: $COUNTS$ }")
M["CHECKED"] = "{ reason: atom, where: string, gaps: int64 }"
M["DIGEST"] = ("{ kind: atom, seq: int64, name: string, text: string, count: int64, check: $CHECKED$, "
               "flags: { silica: boolean, check_mode: boolean }, keep: string, printed: $PRINTED$ }")
# What ts_print answers for one form (see the header of ts_print.silica.in):
#   ok true            text is the form's Silica source, exports its export lines, sig "name/arity" of a printed function
#   ok false, stub true   text is a failing stub with the function's signature (it compiles, and so do its callers)
#   ok false, stub false  nothing could be written; text is ""
#   code "T4001" (the sender sent a gap), "T4002" (the transpiler cannot print the construct yet) or "T3101".."T3104"
#   (a type the contract requires is missing, or the sender's typing is inconsistent; contract T8.13); why says what and
#   names the construct; file, line, column are the place in the sender's source (line 0: none)
#   decl: for a (:type) form, the entry it adds to the session's declared types (contract T8.14); "" otherwise
M["PRINTED"] = ("{ ok: boolean, stub: boolean, exports: string, text: string, sig: string, code: string, why: string, "
                "at: { file: string, line: int64, column: int64 }, decl: string }")
# --- printer placeholders (owned by the printer work; add new entries only between these two marker lines) ---
M["ENV"] = "List[(string, string, string), mem(normal)]"   # (source variable, printed as, Silica type or "")
M["EX"] = "{ text: string, type: string }"                 # a printed expression and its Silica type ("": not known)
# the form's node table, type table and hints (the types the sender states, contract 8.6), and the session's
# declared types so far (ts_print: "THE DECLARED TYPES OF THE SESSION")
# f: "name_arity" of the function being printed (its process functions are named after it)
M["CTX"] = "{ ns: $NODES$, ts: $TYPES$, hs: $HINTS$, os: $OVERRIDES$, d: string, f: string }"
M["STOPPED"] = "{ construct: string, node: int64, code: string, note: string }"   # what stopped the printer
# --- end of printer placeholders ---
M["STEP"] = "{ sess: $SESS$, out: string, done: boolean, keep: string, own: string, mark: boolean }"
M["VERDICT"] = "{ reason: atom, where: string, fin: boolean, sess: $SESS$, note: string }"
M["OWN"] = ("(:session, { id: string, started_at: int64 }) | (:rejected_frame, $REJECTED$) | "
            "(:ended, { rejected: int64, frames: int64, miscounts: int64 }) | (:aborted, { reason: string }) | "
            "(:output_begin, { attempt: int64 }) | (:output_file, { path: string, content: string }) | "
            "(:transpiled, { result: $RESULT$ }) | (:released, { id: string })")
M["OWNSUM"] = "{ kind: atom, text: string, a: int64, b: int64, c: int64 }"
M["CARRIER_EVENT"] = ("(:link_up, string) | (:rx, string) | (:tx_credit, int64) | (:tx_failed, atom) | "
                      "(:link_down, atom)")
M["CONNS"] = "List[dangerous_actor_ref, mem(normal)]"
# Every actor's messages are tagged tuples: a supervisor's child list refuses a behaviour whose message type holds
# a bare atom beside tuples (limitation observed, E2003).
M["SESSION_STATE"] = ("{ conn: $CONNS$, slot: int64, token: int64, rx: $RX$, id: string, sess: $SESS$, "
                      "seen: int64 }")
M["SESSION_EVENT"] = ("$CARRIER_EVENT$ | (:boot, int64) | (:adopt, dangerous_actor_ref, int64, int64) | "
                      "(:store, int64, atom, string, int64) | (:rebuild, int64, int64, string)")
M["DRAINED"] = "{ rx: $RX$, sess: $SESS$, out: string, done: boolean, fault: boolean, ask: string }"
M["LISTENER_STATE"] = "{ lst: $CONNS$, accepted: int64 }"
M["LISTENER_EVENT"] = ("(:link_up, string) | (:accepted, dangerous_actor_ref, string) | (:rx, string) | "
                       "(:tx_credit, int64) | (:tx_failed, atom) | (:link_down, atom) | (:boot, int64)")
M["STORE_REF"] = "actor_ref" if STORE == "memory" else "dangerous_actor_ref"
M["STORE_CARS"] = "List[$STORE_REF$, mem(normal)]"
M["OWNER_EVENT"] = ("(:link_up, string) | (:log, int64, int64, int64) | (:tx_credit, int64) | (:synced, int64) | "
                    "(:rx, string) | (:rx_end, int64) | (:tx_failed, atom) | (:read_failed, atom) | (:link_down, atom) | "
                    "(:boot, int64) | (:shutdown, int64) | (:port_lost, int64) | "
                    "(:lease, int64, int64, int64, string) | (:resume, int64, int64, string, string) | "
                    "(:put, int64, int64, string) | (:mark, int64, int64) | (:finish, int64, int64, int64, int64) | "
                    "(:drop, int64, string) | (:detach, int64) | (:more, int64) | (:free, int64, int64, string) | "
                    "(:t_boot, int64) | (:t_more, int64) | (:t_out, int64, string, string) | "
                    "(:t_done, int64, atom, int64, int64, int64, string)")
M["JOB"] = ("{ phase: int64, slot: int64, token: int64, id: string, base: int64, hello: string, attempt: int64, "
            "tally: { rejected: int64, frames: int64, miscounts: int64 }, result: string, pending: string }")
M["OWNER_IO"] = ("{ up: boolean, closing: boolean, next: int64, oldest: int64, rx_credit: int64, waits: $LI$, "
                 "mode: int64, free_slot: int64, free_token: int64 }")
M["OWNER_STATE"] = "{ car: int64, r: int64, rx: $RX$, io: $OWNER_IO$, job: $JOB$ }"
M["STORE_EVENT"] = ("(:link_up, string) | (:log, int64, int64, int64) | (:tx_credit, int64) | (:synced, int64) | "
                    "(:rx, string) | (:rx_end, int64) | (:tx_failed, atom) | (:read_failed, atom) | (:link_down, atom)")
M["PORT_STATE"] = "{ car: $STORE_CARS$, r: int64, reopen: boolean }"
M["PORT_EVENT"] = ("$STORE_EVENT$ | (:boot, int64) | (:p_boot, int64) | (:p_tx, string) | (:p_sync, int64) | "
                   "(:p_read, int64) | (:p_read_stop, int64) | (:p_credit, int64) | (:p_trim, int64) | (:p_close, int64)")
M["TALLY"] = "{ units: int64, gaps: int64, files: int64, written: int64 }"
M["UNIT_ACC"] = ("{ silica_unit: string, name: string, exports: string, text: string, sigs: string, entry: string, "
                 "stubs: boolean }")
# decls: the session's declared types so far (ts_print: "THE DECLARED TYPES OF THE SESSION")
M["TRANSPILE_STATE"] = ("{ r: int64, attempt: int64, silica: boolean, acc: $UNIT_ACC$, n: $TALLY$, diag: string, "
                        "decls: string }")
M["TRANSPILE_EVENT"] = "(:boot, int64) | (:t_start, int64, string) | (:t_record, int64, string) | (:t_end, int64)"
M["FLAGS"] = ("{ strategy: :one_for_one | :one_for_all | :rest_for_one, allowed_restart_count: int64, "
              "restarts_time_frame: int64 }")
M["SUP_REPLY"] = ("{ tag: :child_started | :ok | :children | :count | :child_info | :error, child: actor_ref, "
                  "status: atom, children: List[{ id: atom, agent_type: :worker | :supervisor, child: actor_ref, "
                  "restart: :permanent | :temporary | :transient }, mem(normal)], count: int64, "
                  "child_info: { id: atom, agent_type: :worker | :supervisor, child: actor_ref, "
                  "restart: :permanent | :temporary | :transient }, error: atom }")
M["EXIT_REPORT"] = ("{ child: actor_ref, child_id: atom, failure_reason: :normal | :language_error | :memory_fault | "
                    "(:explicit, atom) | :noproc | :unknown, restarted: boolean, new_child: actor_ref }")


def child_spec(state, event):
    return ("{ id: atom, agent_type: :worker | :supervisor, initial_state: %s, "
            "behavior: fn(msg: %s, state: %s) -> (:no_reply, %s), restart: :permanent | :temporary | :transient, "
            "shutdown: int64, flavor: :plain | :dangerous, state_policy: state_policy }" % (state, event, state, state))


for kind in ("SESSION", "LISTENER", "OWNER", "TRANSPILE", "PORT"):
    M[kind + "_SPECS"] = "List[%s, mem(normal)]" % child_spec("$%s_STATE$" % kind, "$%s_EVENT$" % kind)
    M[kind + "_SUP"] = "($FLAGS$, $%s_SPECS$)" % kind


def arms(prefix, n):
    lines = ["        %d -> :%s%d;" % (i, prefix, i) for i in range(n)]
    lines.append("        _: int64 -> :%s0" % prefix)
    return "\n".join(lines)


def index_arms(prefix, n):
    out = "0 - 1"
    for i in reversed(range(n)):
        out = "case a == :%s%d of { true -> %d; false -> %s }" % (prefix, i, i, out)
    return out


def children(prefix, n, state, behaviour):
    item = ("            { id: :%s%d, agent_type: :worker, initial_state: " + state + ", behavior: " + behaviour +
            ", restart: :permanent, shutdown: 0, flavor: :plain, state_policy: state_policy(:keep_state_area) }")
    return ",\n".join(item % (prefix, i, i) for i in range(n))


M["N_SESSIONS"] = str(SESSIONS)
M["N_REGIONS"] = str(REGIONS)
M["SESSION_NAME_ARMS"] = arms("ts_session_", SESSIONS)
M["STORE_NAME_ARMS"] = arms("ts_store_", REGIONS)
M["PORT_NAME_ARMS"] = arms("ts_port_", REGIONS)
M["PORT_CHILDREN"] = children("ts_port_", REGIONS, "port_initial(%d)", "port")
M["TRANSPILE_NAME_ARMS"] = arms("ts_transpile_", REGIONS)
M["SESSION_INDEX"] = index_arms("ts_session_", SESSIONS)
M["REGION_LABEL_ARMS"] = "\n".join(["        %d -> \"intake_%d\";" % (i, i) for i in range(REGIONS)] +
                                   ["        _: int64 -> \"\""])
M["SESSION_CHILDREN"] = children("ts_session_", SESSIONS, "session_initial(%d)", "session")
M["STORE_CHILDREN"] = children("ts_store_", REGIONS, "ts_region@owner_initial(%d)", "owner")
M["TRANSPILE_CHILDREN"] = children("ts_transpile_", REGIONS, "transpile_initial(%d)", "transpiler")
M["STORE_MEDIUM"] = STORE
if STORE == "memory":
    M["STORE_USES"] = "use store_memory_carrier;"
    M["REGION_DECLS"] = "\n".join("carried_on intake_%d: (:store) (:memory, %d, :trim);" % (i, CAPACITY)
                                  for i in range(REGIONS))
else:
    M["STORE_USES"] = "use dangerous_store;\nuse dangerous_store_backing_carrier;"
    M["REGION_DECLS"] = "\n".join("carried_on intake_%d: (:store) (:backing, \"%s/intake_%d.sildat\", %d, :trim);"
                                  % (i, STORE_DIR, i, CAPACITY) for i in range(REGIONS))
M["REGION_STARTS"] = "\n\n".join(
    ("fn start_%d() -> $STORE_REF$ {\n    sequence proc[concurrency]\n        c: $STORE_REF$ <- "
     "spawn_dangerous_carrier(intake_%d, stack_policy(0, :keep_last_message), state_policy(:keep_state_area));\n"
     "        _: boolean <- cast(c, (:open, self(), \"\") impl ActorMessage {})\n    produces\n        pure c\n"
     "    end\n}") % (i, i) for i in range(REGIONS)) + "\n\nfn start_region(r: int64) -> $STORE_REF$ {\n    case r of {\n" + \
    "\n".join("        %d -> start_%d();" % (i, i) for i in range(REGIONS - 1)) + \
    ("\n" if REGIONS > 1 else "") + "        _: int64 -> start_%d()\n    }\n}" % (REGIONS - 1)



def literal_expression(path):
    """A Silica expression whose value is the text of the file: string literals of at most about 2000 bytes, joined
    by concat. The file is a template of generated Silica (the process runtime the printer writes at the end of a
    unit with processes, app design 5.5): <S>, <M>, <P> and <C> in it become the printer's marks for the unit's
    state, message, phase and child types; @NAME@ words are filled in by the printer when it writes a unit; a
    $NAME$ placeholder is spelled out here like everywhere else."""
    text = open(path).read()
    if "\\" in text or "\t" in text:
        raise SystemExit("expand.py: %s must not hold a backslash or a tab" % path)
    parts, part = [], ""
    for line in text.splitlines(True):
        line = line.replace('"', '\\"').replace("\n", "\\n")
        for k in "SMPC":
            line = line.replace("<%s>" % k, "\\x13%s\\x14" % k)
        if len(part) + len(line) > 2000 and part:
            parts.append(part)
            part = ""
        part += line
    parts.append(part)
    out = '"%s"' % parts[-1]
    for part in reversed(parts[:-1]):
        out = 'concat("%s", %s)' % (part, out)
    return out


M["PROCESS_RUNTIME"] = literal_expression(os.path.join(SRC, "process_runtime.silica.tmpl"))
M["PROCESS_MAIN"] = literal_expression(os.path.join(SRC, "process_main.silica.tmpl"))

PLACEHOLDER = re.compile(r"\$([A-Z_]+)\$")


def expand(text):
    for _ in range(40):
        new = PLACEHOLDER.sub(lambda m: M.get(m.group(1), m.group(0)), text)
        if new == text:
            return text
        text = new
    raise SystemExit("placeholders nest too deeply")


def squeeze(text):
    text = re.sub(r"//[^\n]*", "", text)
    return re.sub(r"\s+", "", text)


def check_against_schema():
    schema = open(SCHEMA).read()
    start = schema.index("fn decode_to_transpiler(frame: string) -> (:ok,") + len(
        "fn decode_to_transpiler(frame: string) -> (:ok,")
    stop = schema.index(") | (:rejected, atom) {", start)
    want = squeeze(schema[start:stop])
    got = squeeze(expand("$TO_TRANSPILER$"))
    if want != got:
        n = next((i for i in range(min(len(want), len(got))) if want[i] != got[i]), min(len(want), len(got)))
        raise SystemExit("expand.py: $TO_TRANSPILER$ differs from the schema near: schema ...%s... / here ...%s..."
                         % (want[max(0, n - 40):n + 60], got[max(0, n - 40):n + 60]))


def main():
    check_against_schema()
    if len(sys.argv) != 2:
        raise SystemExit("usage: expand.py <output-directory>   (build.sh passes its build directory)")
    out_dir = sys.argv[1]
    for src_dir, to_dir in ((SRC, out_dir), (os.path.join(SRC, "stubs"), os.path.join(out_dir, "stubs"))):
        os.makedirs(to_dir, exist_ok=True)
        for name in sorted(os.listdir(src_dir)):
            if not name.endswith(".silica.in"):
                continue
            text = open(os.path.join(src_dir, name)).read()
            out = ("// GENERATED by silica-sink/tools/expand.py from %s: do not edit; edit the .in file.\n" % name) + expand(text)
            left = PLACEHOLDER.search(out.replace("$NAME$", ""))
            if left:
                raise SystemExit("expand.py: %s uses the unknown placeholder %s" % (name, left.group(0)))
            with open(os.path.join(to_dir, name[:-3]), "w") as f:
                f.write(out)
            print("wrote", os.path.relpath(os.path.join(to_dir, name[:-3]), out_dir))


if __name__ == "__main__":
    main()
