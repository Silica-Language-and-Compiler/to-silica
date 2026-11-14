#!/bin/bash
# Builds the to-silica transpiler (dangerous_to_silica) with the Silica compiler.
#
#   silica-sink/build.sh <build-dir> [port]
#
# <build-dir> is created if needed; everything is built there, the generated *.silica units included. [port]
# replaces the default listening port 7411 (a literal in ts_config).
# Environment:
#   SILICA            the Silica checkout (default /Volumes/2T/silica)
#   SILICA_COMPILER   default $SILICA/binaries/silica-999916-macos-applesilicon
#   TS_STORE          memory (default) or backing; TS_STORE_DIR (backing: default <build-dir>/store),
#   TS_REGIONS, TS_CAPACITY, TS_SESSIONS   the pools (silica-sink/tools/expand.py says what each is)
#   TS_TRIAL_FAULTS   1: build with the trial hooks of ts_config set (the trials need them); never for real use
#   TS_FAST           1: the four-run build with a cached schema unit (below); for work on the transpiler only
#   TS_SCHEMA_CACHE   TS_FAST only: a directory that keeps run 1's output between builds (default
#                     <build-dir>/../.ts_schema_cache)
# Needs: the compiler, clang, ar, python3. Takes about six minutes (measured 2026-11-13: 343 s, 2.5 GB resident at
# most); with TS_FAST=1 about six minutes the first time and about two with the cache.
#
# ONE COMPILER RUN (the default, since compiler 999916). The compiler compiles every unit of silica.config in one
# process. Up to compiler 999919 that process ended with out_of_memory (in its type_surface_cache actor) when the
# schema unit's derived decoder and the transpiler's own units were compiled together, so this script compiled in
# four runs. With 999916 one run holds everything (STATUS.md, "Compiler memory").
# The run still compiles ts_prelude first (tools/prelude.py: a unit that names every atom and record shape of the
# build in one fixed order). Limitation observed (999916): without it the program compiles and links, and each
# store owner ends at its first message with "language_error: no case arm matched"; with it the program runs.
# Not understood further.
#
# TS_FAST=1: FOUR COMPILER RUNS. Kept only because it is faster to rebuild (the schema unit, which takes more than
# half of the time, is compiled once and cached); it is no longer needed for memory. The runs:
#   run 1  the schema unit (its output is kept in a cache: it depends only on the schema, wire_etf and the compiler)
#   run 2  the store units: the region ports and the store owners
#   run 3  the checks and the printer, against an interface-only copy of the schema unit
#   run 4  the session logic and the actors, against interface-only copies of what runs 2 and 3 compiled
# An interface-only copy has the same exported signatures and no real body; the linked program holds the real
# units. The copy of the schema unit and of the two store units is made here from the unit itself; those of
# ts_print and ts_intake are src/stubs/*.silica.in, and this script checks their signatures against the units.
# Objects of different runs link correctly only if the runs number atoms and record shapes alike, which is what
# ts_prelude was written for: this script checks that runs 2 to 4 end with equal tables and that the schema run's
# are a prefix of them, and fails otherwise. Units several runs need (ts_text, ...) are compiled in each; the
# linked program takes the last run's.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="${1:?usage: build.sh <build-dir> [port]}"
PORT="${2:-7411}"
SILICA="${SILICA:-/Volumes/2T/silica}"
CC="${SILICA_COMPILER:-$SILICA/binaries/silica-999916-macos-applesilicon}"
export TS_STORE="${TS_STORE:-memory}"
mkdir -p "$BUILD" && BUILD="$(cd "$BUILD" && pwd)" || exit 1
export TS_STORE_DIR="${TS_STORE_DIR:-$BUILD/store}"
CACHE="${TS_SCHEMA_CACHE:-$BUILD/../.ts_schema_cache}"
if [ "$TS_STORE" = backing ]; then
    STORE_STD="dangerous_store dangerous_store_backing_carrier"; mkdir -p "$TS_STORE_DIR" || exit 1
else
    STORE_STD="store_memory_carrier"
fi
SHARED="ts_text ts_out ts_config ts_pool ts_reply ts_records"
STORE_ONLY_STD="storelog $STORE_STD"
STORE_STD_ALL="Supervisor wire_etf wireframe Carrier $STORE_ONLY_STD"
STORE_UNITS="dangerous_ts_port ts_region ts_actor_store"
MAIN_STD="Supervisor wire_etf wireframe Carrier dangerous_sockets dangerous_tcp_carrier"
FRONT_UNITS="ts_check ts_print ts_intake"
MAIN_UNITS="ts_print ts_intake ts_session dangerous_ts_session dangerous_ts_port ts_actor_store ts_actor_transpile"
STD="$STORE_STD_ALL dangerous_sockets dangerous_tcp_carrier"

mkdir -p "$BUILD/dangerous_exposure_source/lib" && cd "$BUILD" || exit 1
rm -f ./*.sams ./*.o ./*.iface ./*.derived ./*.silica silica.config silica.atoms silica.shapes silica.link silica.compile.* dangerous_to_silica
python3 "$HERE/tools/expand.py" "$BUILD" > /dev/null || exit 1
ln -sfn "$SILICA/compiler/stdlib/net" dangerous_exposure_source/sockets
rm -f dangerous_exposure_source/lib/*.a
for lib in sockets $([ "$TS_STORE" = backing ] && echo store); do
    clang -std=c11 -O2 -arch arm64 -mmacosx-version-min=26.0 -c "$SILICA/compiler/stdlib/net/silica_$lib.c" -o "silica_$lib.o" || exit 1
    ar rcs "dangerous_exposure_source/lib/libsilica_$lib.a" "silica_$lib.o" && rm "silica_$lib.o"
done
for u in $STD; do ln -sf "$SILICA/compiler/stdlib/$u.silica" "$u.silica"; done
for u in ts_text ts_out ts_config; do cp "$HERE/src/$u.silica" "$u.silica"; done
sed -i '' "s/\"listen:7411\"/\"listen:$PORT\"/" ts_config.silica
if [ "${TS_TRIAL_FAULTS:-0}" = 1 ]; then
    python3 - <<'PY' || exit 1
import re
s = open("ts_config.silica").read()
for name in ("fault_session", "fault_transpile_once", "fault_transpile_always"):
    s, n = re.subn(r'(fn %s\(\) -> string \{\n    )""' % name, r'\1"__ts_%s__"' % name, s)
    if n != 1:
        raise SystemExit("build.sh: ts_config has no trial hook " + name)
open("ts_config.silica", "w").write(s)
PY
fi

compile() {   # the compiler exits 75 or 76 to be run again (Silica trials/silica_compiler.mk)
    rm -f silica.compile.inprogress silica.compile.crashed
    while true; do
        "$CC" > "$1" 2>&1; ec=$?
        [ $ec -eq 75 ] || [ $ec -eq 76 ] || break
    done
    if [ $ec -ne 0 ]; then echo "compile failed (exit $ec); see $BUILD/$1"; grep -A12 "Compilation error" "$1" | head -16; tail -4 "$1"; exit 1; fi
}

link_program() {
    objs=""
    for s in *.sams; do clang -mmacosx-version-min=26.0 -c -x assembler "$s" -o "${s%.sams}.o" || exit 1; objs="$objs ${s%.sams}.o"; done
    clang $objs dangerous_exposure_source/lib/*.a -o dangerous_to_silica -Wl,-e,main -Wl,-macos_version_min,26.0 || exit 1
    echo "built $BUILD/dangerous_to_silica (listens on 127.0.0.1:$PORT; store: $TS_STORE$([ "$TS_STORE" = backing ] && echo " in $TS_STORE_DIR"))"
}

# Every atom and record shape, in one order, for every run (tools/prelude.py). The schema's come first, so the
# schema run's tables are a prefix of the later runs' and its cached output stays good when other units change.
cp "$HERE/../contract/tcp_transport_v1.silica" tcp_transport_v1.silica
OWN="ts_check ts_print ts_intake ts_session dangerous_ts_session $STORE_UNITS ts_actor_transpile dangerous_to_silica"
if [ "${TS_FAST:-0}" != 1 ]; then
    echo "one compiler run: every unit (about six minutes)"
    rm -rf stubs
    ALL="$(for u in $STD $SHARED $OWN; do [ "$u" = wire_etf ] || echo "$u.silica"; done)"
    python3 "$HERE/tools/prelude.py" --all ts_prelude.silica wire_etf.silica tcp_transport_v1.silica $ALL || exit 1
    printf 'ts_prelude.silica\nwire_etf.silica\ntcp_transport_v1.silica\n' > silica.config
    for u in $ALL; do echo "$u" >> silica.config; done
    compile compile.log
    link_program
    exit 0
fi
REST="$(for u in $STD $SHARED ts_check ts_print ts_intake ts_session dangerous_ts_session $STORE_UNITS ts_actor_transpile dangerous_to_silica; do [ "$u" = wire_etf ] || echo "$u.silica"; done)"
python3 "$HERE/tools/prelude.py" ts_prelude.silica wire_etf.silica tcp_transport_v1.silica > /dev/null || exit 1
KEY="$(cat "$HERE/../contract/tcp_transport_v1.silica" "$SILICA/compiler/stdlib/wire_etf.silica" ts_prelude.silica "$CC" | shasum -a 256 | cut -c1-16)"
mkdir -p schema
if [ -f "$CACHE/$KEY/tcp_transport_v1.sams" ]; then
    echo "run 1: the schema unit, from the cache $CACHE/$KEY"
    cp "$CACHE/$KEY/tcp_transport_v1.sams" schema/ && cp "$CACHE/$KEY/atoms" schema/atoms && cp "$CACHE/$KEY/shapes" schema/shapes || exit 1
else
    echo "run 1: the schema unit (about three minutes)"
    printf 'ts_prelude.silica\nwire_etf.silica\ntcp_transport_v1.silica\n' > silica.config
    compile compile1.log
    cp tcp_transport_v1.sams schema/ && cp silica.atoms schema/atoms && cp silica.shapes schema/shapes
    mkdir -p "$CACHE/$KEY" && cp schema/tcp_transport_v1.sams schema/atoms schema/shapes "$CACHE/$KEY/"
    rm -f ./*.sams ./*.iface ./*.derived silica.atoms silica.shapes
fi
python3 "$HERE/tools/prelude.py" --all ts_prelude.silica wire_etf.silica tcp_transport_v1.silica $REST || exit 1

check_tables() {   # a later run may only append to the atom and shape tables of the runs before it
    for t in atoms shapes; do
        if [ "$(head -c "$(wc -c < "$1/$t")" silica.$t | cmp - "$1/$t"; echo $?)" != "0" ]; then
            echo "build.sh: a compiler run changed silica.$t instead of appending to it; the runs do not link safely"; exit 1
        fi
    done
}

make_schema_interface() {
    cp "$HERE/../contract/tcp_transport_v1.silica" tcp_transport_v1.silica
    python3 - <<'PY' || exit 1
src = open("tcp_transport_v1.silica").read()
call = "<- decode((:etf), frame, { max_bytes: 1048576, max_depth: 16, max_length: 65536 })"
if src.count(call) != 2:
    raise SystemExit("build.sh: the schema unit's decode calls are not where this script expects them")
src = src.replace(call, "<- (:rejected, :unsupported)").replace("sequence proc[mem(normal), transport]", "sequence")
open("tcp_transport_v1.silica", "w").write(src)
PY
}

same_tables() {   # same_tables <run dir>: this run's tables must be those of the run kept in <run dir>
    for t in atoms shapes; do
        cmp -s silica.$t "$1/$t" || { echo "build.sh: two compiler runs disagree on silica.$t (tools/prelude.py missed an atom or a shape); they do not link safely"; diff silica.$t "$1/$t" | head -5; exit 1; }
    done
}
keep_run() {   # keep_run <dir> <unit>...: keeps the run's tables and the objects of these units
    mkdir -p "$1" && rm -f "$1"/* && cp silica.atoms "$1/atoms" && cp silica.shapes "$1/shapes" || exit 1
    d="$1"; shift
    for u in "$@"; do cp "$u.sams" "$d/" || exit 1; done
    rm -f ./*.sams ./*.iface ./*.derived
}
mkdir -p real_src

echo "run 2: the store units (the region ports and the store owners)"
echo ts_prelude.silica > silica.config
for u in $STORE_STD_ALL $SHARED $STORE_UNITS; do echo "$u.silica" >> silica.config; done
compile compile2.log
check_tables schema
keep_run store_run $STORE_ONLY_STD $STORE_UNITS

echo "run 3: the checks and the printer, against the schema unit's interface"
make_schema_interface
printf 'ts_prelude.silica\nwire_etf.silica\ntcp_transport_v1.silica\n' > silica.config
for u in wireframe $SHARED $FRONT_UNITS; do echo "$u.silica" >> silica.config; done
compile compile3.log
same_tables store_run
keep_run front_run $FRONT_UNITS

echo "run 4: the actors, against the interfaces of the printer, the checks and the store units"
python3 - <<'PY' || exit 1
import os, re
# An interface-only copy takes the place of each unit an earlier run compiled. Those of ts_print and ts_intake are
# written by hand (src/stubs); the `fn` line of every exported function of one must be in the real unit, or the two would not link as meant.
for unit in ("ts_print", "ts_intake"):
    real = open(unit + ".silica").read()
    stub = open("stubs/" + unit + ".silica").read()
    exported = re.findall(r"^export (\w+)/\d+;", stub, re.M)
    for line in re.findall(r"^fn .*$", stub, re.M):
        if line.split("(")[0][3:] in exported and line not in real:
            raise SystemExit("build.sh: the interface copy of %s has a function the unit does not have: %s" % (unit, line[:70]))
    os.replace(unit + ".silica", "real_src/" + unit + ".silica")
    open(unit + ".silica", "w").write(stub)
# The root unit names only the supervisor function of each store unit: its interface-only copy keeps that
# function, with the same signature and an empty child list.
for unit in ("dangerous_ts_port", "ts_actor_store"):
    full = open(unit + ".silica").read()
    os.replace(unit + ".silica", "real_src/" + unit + ".silica")
    head = re.search(r"^export \w+/1;\n\nimpl \w+ for Supervisor;\n", full, re.M)
    init = re.search(r"^fn init\(.*?^}\n", full, re.S | re.M)
    wrap = re.search(r"^fn \w+_sup\(.*?^}\n", full, re.S | re.M)
    f = re.search(r"^fn flags\(.*?^}\n", full, re.S | re.M)
    if not (head and init and wrap):
        raise SystemExit("build.sh: %s is not the supervisor unit this script expects" % unit)
    body, n = re.subn(r"<- \[\n.*?\n        \]", "<- []", init.group(0), flags=re.S)
    if n != 1:
        raise SystemExit("build.sh: the child list of %s is not where this script expects it" % unit)
    open(unit + ".silica", "w").write("module %s;\n\nuse Supervisor;\n\n%s\n%s\n%s\n%s" % (unit, head.group(0), f.group(0) if f else "", body, wrap.group(0)))
PY
printf 'ts_prelude.silica\nwire_etf.silica\ntcp_transport_v1.silica\n' > silica.config
for u in $MAIN_STD $SHARED $MAIN_UNITS dangerous_to_silica; do [ "$u" = wire_etf ] || echo "$u.silica" >> silica.config; done
compile compile4.log
same_tables store_run
cp schema/tcp_transport_v1.sams store_run/*.sams front_run/*.sams . && cp real_src/*.silica . || exit 1
cp "$HERE/../contract/tcp_transport_v1.silica" tcp_transport_v1.silica

link_program
