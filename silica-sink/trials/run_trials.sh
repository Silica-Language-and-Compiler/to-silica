#!/bin/bash
# Runs the transpiler's trials.
#
#   silica-sink/trials/run_trials.sh <work-dir> <port> [all]
#
# Builds the transpiler itself, in <work-dir>/memory (a (:memory) store) and, with `all`, in <work-dir>/backing (a
# (:backing) store in <work-dir>/backing/store), each with TS_TRIAL_FAULTS=1 and TS_REGIONS=2, then runs:
#   p0_check_mode   check mode end to end (contract 6.5)
#   goldens         every session of contract/goldens, compared with its expected replies
#   p2_actors       transpile mode on the pool of regions: two sessions at once, busy, release, resume after a
#                   dropped connection, a session actor and a transpile actor that fail and are restarted by their
#                   supervisors, counts (T1002), abort, credit that follows storage
#   p1_export       the generated erl_demo.silica is exported from the debug output, compiled by the Silica
#                   compiler together with a caller, linked and run: add(2, 3) must print 5
#   p3_types        "the sender decides every type" (contract 8.6): one session of functions whose types are
#                   stated by hints, with conversion operators, declared types and lists, and of functions whose
#                   typing is missing or inconsistent: each must get its T31xx diagnostic at its file and line;
#                   then the generated unit is compiled with a caller, linked and run, and its output compared
#   p4_processes    the process nodes (contract H20 to H26, 9.4a): a session whose functions spawn, send, receive
#                   (with guards and timeouts), fail and go on in one another, and functions the printer does
#                   not write (links, exit requests, a receive that is not in tail position, ...), each with its
#                   diagnostic; static children (contract T9.14b) and sends to their names, one restarted under
#                   its name; the generated unit is compiled with a caller that starts the processes, and its
#                   output compared; a second session with an entry point gives a program that is run alone
#   with `all`:     p2_actors again on the (:backing) store; then the transpiler is killed (SIGKILL) and started
#                   again: a finished and an unfinished session are found, resumed and released; then an orderly
#                   end ("exit" on standard input) must give exit status 0
# Needs erl, erlc, clang, python3. Exit status 0 when every trial passed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
mkdir -p "${1:?usage: run_trials.sh <work-dir> <port> [all]}" && WORK="$(cd "$1" && pwd)" || exit 1
PORT="${2:?usage: run_trials.sh <work-dir> <port> [all]}"
ALL="${3:-}"
SILICA="${SILICA:-/Volumes/2T/silica}"
CC="${SILICA_COMPILER:-$SILICA/binaries/silica-999906-macos-applesilicon}"
EBIN="$WORK/trial_ebin"; mkdir -p "$EBIN"
erlc +debug_info -o "$EBIN" "$REPO"/contract/bindings/erlang/*.erl "$REPO/contract/examples/add_example.erl" \
    "$REPO/contract/goldens/goldens.erl" "$HERE/p0_check_mode/p0_trial.erl" "$HERE/p2_actors/p2_trial.erl" "$HERE/p3_types/p3_trial.erl" \
    "$HERE/p4_processes/p4_trial.erl" || exit 1
failed=0

build() {   # build <medium>
    echo "--- building the transpiler ($1 store)"
    TS_STORE="$1" TS_TRIAL_FAULTS=1 TS_REGIONS=2 TS_CAPACITY=8388608 "$HERE/../build.sh" "$WORK/$1" "$PORT" > "$WORK/build_$1.log" 2>&1 \
        || { tail -20 "$WORK/build_$1.log"; echo "FAIL  build ($1)"; exit 1; }
}
start() {   # start <medium> <log name>: standard input is a pipe kept open, so that "exit" can be sent to it
    BUILD="$WORK/$1"
    rm -f "$BUILD/stdin.fifo"; mkfifo "$BUILD/stdin.fifo"
    ( cd "$BUILD" && exec ./dangerous_to_silica < stdin.fifo > "$2.out" 2> "$2.err" ) &
    PID=$!
    exec 9> "$BUILD/stdin.fifo"
    sleep 2
}
stop() { kill -9 "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; exec 9>&-; sleep 0.5; }

build memory
start memory p0; echo "--- p0_check_mode"
erl -noshell -pa "$EBIN" -s p0_trial main "$PORT" || failed=1
echo "--- goldens"
erl -noshell -pa "$EBIN" -s goldens play "$PORT" "$REPO/contract/goldens" || failed=1
stop

start memory p2; echo "--- p2_actors (memory store)"
erl -noshell -pa "$EBIN" -s p2_trial main "$PORT" memory "$WORK/memory/p2.out" || failed=1
stop

echo "--- p1_export"
OUT="$WORK/export"; rm -rf "$OUT"; mkdir -p "$OUT"
python3 "$REPO/tools/export_debug_output.py" "$WORK/memory/p2.out" intake_0:0 "$OUT" || failed=1
cat > "$OUT/call_add.silica" <<'SILICA'
use erl_demo;

fn main() -> int64 {
    sequence proc[device_io]
        _: atom <- print_int64(erl_demo@add(2, 3));
        _: atom <- println("")
    produces
        pure 0
    end
}
SILICA
( cd "$OUT" && printf 'erl_demo.silica\ncall_add.silica\n' > silica.config \
  && while true; do "$CC" > compile.log 2>&1; ec=$?; [ $ec -eq 75 ] || [ $ec -eq 76 ] || break; done \
  && [ $ec -eq 0 ] \
  && for s in *.sams; do clang -mmacosx-version-min=26.0 -c -x assembler "$s" -o "${s%.sams}.o" || exit 1; done \
  && clang ./*.o -o call_add -Wl,-e,main -Wl,-macos_version_min,26.0 \
  && got="$(./call_add)" && echo "erl_demo@add(2, 3) = $got" && [ "$got" = "5" ] ) || { echo "FAIL  p1_export"; failed=1; }

start memory p3; echo "--- p3_types"
erl -noshell -pa "$EBIN" -s p3_trial main "$PORT" "$WORK/memory/p3.id" || failed=1
stop
OUT="$WORK/export_types"; rm -rf "$OUT"; mkdir -p "$OUT"
python3 "$REPO/tools/export_debug_output.py" "$WORK/memory/p3.out" "$(cat "$WORK/memory/p3.id")" "$OUT" || failed=1
cp "$HERE/p3_types/call_types.silica" "$OUT/"
( cd "$OUT" && printf 'erl_types.silica\ncall_types.silica\n' > silica.config \
  && while true; do "$CC" > compile.log 2>&1; ec=$?; [ $ec -eq 75 ] || [ $ec -eq 76 ] || break; done \
  && [ $ec -eq 0 ] \
  && for s in *.sams; do clang -mmacosx-version-min=26.0 -c -x assembler "$s" -o "${s%.sams}.o" || exit 1; done \
  && clang ./*.o -o call_types -Wl,-e,main -Wl,-macos_version_min,26.0 \
  && ./call_types > got.txt && diff got.txt "$HERE/p3_types/expected.txt" \
  && echo "ok    the generated erl_types.silica compiles, links and prints what p3_types/expected.txt says" ) \
  || { echo "FAIL  p3_types: the generated unit (see $OUT/compile.log, $OUT/got.txt)"; failed=1; }

start memory p4; echo "--- p4_processes"
erl -noshell -pa "$EBIN" -s p4_trial main "$PORT" "$WORK/memory/p4.ids" || failed=1
stop
# compile_run <dir> <program> <seconds> <unit>...: compiles the units behind a prelude unit (limitation observed:
# the units of a program agree on atom numbers only when one unit names every atom first) with Silica's
# Supervisor unit, links, and runs the program with a time limit; its output is in got.txt and err.txt.
compile_run() {
    ( cd "$1" && prog="$2" && secs="$3" && shift 3 \
      && ln -sf "$SILICA/compiler/stdlib/Supervisor.silica" Supervisor.silica \
      && python3 "$HERE/../tools/prelude.py" --all ts_prelude.silica Supervisor.silica "$@" > /dev/null \
      && printf 'ts_prelude.silica\nSupervisor.silica\n' > silica.config && for u in "$@"; do echo "$u" >> silica.config; done \
      && while true; do "$CC" > compile.log 2>&1; ec=$?; [ $ec -eq 75 ] || [ $ec -eq 76 ] || break; done \
      && [ $ec -eq 0 ] \
      && for s in *.sams; do clang -mmacosx-version-min=26.0 -c -x assembler "$s" -o "${s%.sams}.o" || exit 1; done \
      && clang ./*.o -o "$prog" -Wl,-e,main -Wl,-macos_version_min,26.0 \
      && perl -e 'alarm shift; exec @ARGV' "$secs" "./$prog" < /dev/null > got.txt 2> err.txt )
}
OUT="$WORK/export_procs"; rm -rf "$OUT"; mkdir -p "$OUT"
python3 "$REPO/tools/export_debug_output.py" "$WORK/memory/p4.out" "$(sed -n 1p "$WORK/memory/p4.ids")" "$OUT" || failed=1
python3 - "$OUT/erl_procs.silica" "$HERE/p4_processes/call_procs.silica.in" "$OUT/call_procs.silica" <<'PY' || failed=1
import re, sys
unit = open(sys.argv[1]).read()
sums = re.search(r"fn to_silica_send\(to: actor_ref, m: (.*)\) -> boolean \{", unit)
open(sys.argv[3], "w").write(open(sys.argv[2]).read().replace("MMM", sums.group(1)))
PY
compile_run "$OUT" call_procs 30 erl_procs.silica call_procs.silica \
  && ( cd "$OUT" && sort got.txt | diff - <(sort "$HERE/p4_processes/expected.txt") && grep -q kaboom err.txt ) \
  && echo "ok    the generated erl_procs.silica compiles, links, and its processes do what p4_processes/expected.txt says; the echo that is told to fail ends with kaboom" \
  || { echo "FAIL  p4_processes: the generated unit (see $OUT/compile.log, $OUT/got.txt, $OUT/err.txt)"; failed=1; }
OUT="$WORK/export_entry"; rm -rf "$OUT"; mkdir -p "$OUT"
python3 "$REPO/tools/export_debug_output.py" "$WORK/memory/p4.out" "$(sed -n 2p "$WORK/memory/p4.ids")" "$OUT" || failed=1
compile_run "$OUT" erl_entry 20 erl_entry.silica \
  && echo "ok    the generated erl_entry.silica is a program: its main starts the entry function as a process, and it ends (status 0) when that process has its answer" \
  || { echo "FAIL  p4_processes: the program with an entry point (see $OUT/compile.log, $OUT/err.txt)"; failed=1; }

if [ "$ALL" = all ]; then
    rm -rf "$WORK/backing/store"
    build backing
    start backing p2; echo "--- p2_actors (backing store)"
    erl -noshell -pa "$EBIN" -s p2_trial main "$PORT" backing "$WORK/backing/p2.out" || failed=1
    echo "--- kill -9, start again on the same backing store (app design 4.3)"
    stop
    start backing p3
    for i in $(seq 1 90); do [ "$(grep -c "recovered" "$WORK/backing/p3.out")" -ge 2 ] && break; sleep 1; done
    grep "recovered" "$WORK/backing/p3.out"
    erl -noshell -pa "$EBIN" -s p2_trial after_restart "$PORT" "$WORK/backing/p2.out.ids" || failed=1
    echo "--- orderly end"
    echo exit >&9
    for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$PID" 2>/dev/null || break; sleep 0.5; done
    if kill -0 "$PID" 2>/dev/null; then echo "FAIL  the transpiler did not end on \"exit\""; failed=1; stop
    else wait "$PID"; ec=$?; exec 9>&-
        [ $ec -eq 0 ] && echo "ok    \"exit\" on standard input: the regions are closed and the exit status is 0" || { echo "FAIL  exit status $ec"; failed=1; }
    fi
fi
[ $failed -eq 0 ] && echo "all trials passed" || echo "SOME TRIALS FAILED"
exit $failed
