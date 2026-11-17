#!/bin/bash
# Builds the to-silica transpiler (dangerous_to_silica) with the Silica compiler.
#
#   silica-sink/build.sh <build-dir> [port]
#
# <build-dir> is created if needed; everything is built there, the generated *.silica units included. [port]
# replaces the default listening port 7411 (a literal in ts_config).
# Environment:
#   SILICA            the Silica checkout (default /Volumes/2T/silica)
#   SILICA_COMPILER   default $SILICA/binaries/silica-999909-macos-applesilicon
#   TS_STORE          memory (default) or backing; TS_STORE_DIR (backing: default <build-dir>/store),
#   TS_REGIONS, TS_CAPACITY, TS_SESSIONS   the pools (silica-sink/tools/expand.py says what each is)
#   TS_TRIAL_FAULTS   1: build with the trial hooks of ts_config set (the trials need them); never for real use
# Needs: the compiler, clang, ar, python3. Takes about six minutes (measured 2026-11-13: 343 s, 2.5 GB resident at
# most).
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
# The build is one compilation unit (the compiler's design document APPLICATION_IS_ONE_COMPILATION_UNIT.md): silica.config
# lists every unit of the application, and one compiler run compiles them all. There is no mode that compiles parts
# separately and links their objects. The compiler writes one .sams for each unit as a work-around of its own; this script
# assembles them and links the program (link_program), which is the compiler's output, not a second compilation.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="${1:?usage: build.sh <build-dir> [port]}"
PORT="${2:-7411}"
SILICA="${SILICA:-/Volumes/2T/silica}"
CC="${SILICA_COMPILER:-$SILICA/binaries/silica-999909-macos-applesilicon}"
export TS_STORE="${TS_STORE:-memory}"
mkdir -p "$BUILD" && BUILD="$(cd "$BUILD" && pwd)" || exit 1
export TS_STORE_DIR="${TS_STORE_DIR:-$BUILD/store}"
if [ "$TS_STORE" = backing ]; then
    STORE_STD="dangerous_store dangerous_store_backing_carrier"; mkdir -p "$TS_STORE_DIR" || exit 1
else
    STORE_STD="store_memory_carrier"
fi
SHARED="ts_text ts_out ts_config ts_pool ts_reply ts_records"
STORE_ONLY_STD="storelog $STORE_STD"
STORE_STD_ALL="Supervisor wire_etf wireframe Carrier $STORE_ONLY_STD"
STORE_UNITS="dangerous_ts_port ts_region ts_actor_store"
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

# Every atom and record shape of the build, in one order (tools/prelude.py).
cp "$HERE/../contract/tcp_transport_v1.silica" tcp_transport_v1.silica
OWN="ts_check ts_print ts_intake ts_session dangerous_ts_session $STORE_UNITS ts_actor_transpile dangerous_to_silica"
echo "one compiler run: every unit (about six minutes)"
ALL="$(for u in $STD $SHARED $OWN; do [ "$u" = wire_etf ] || echo "$u.silica"; done)"
python3 "$HERE/tools/prelude.py" --all ts_prelude.silica wire_etf.silica tcp_transport_v1.silica $ALL || exit 1
printf 'ts_prelude.silica\nwire_etf.silica\ntcp_transport_v1.silica\n' > silica.config
for u in $ALL; do echo "$u" >> silica.config; done
compile compile.log
link_program
