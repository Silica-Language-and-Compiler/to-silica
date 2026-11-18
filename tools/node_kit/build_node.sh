#!/bin/bash
# Builds one node program of a to-silica session into a BEES BEAM-mode executable (EPMD, cookie).
#
#   tools/node_kit/build_node.sh <bees-root> <compiler> <export-dir> <unit> <leaf-dir> [start-delay-ms]
#
#   <bees-root>     a checkout of project-bees (its Makefiles, tools/ and src/ are used; nothing in it is changed)
#   <compiler>      the Silica compiler, for example ../silica/binaries/silica-999906-macos-applesilicon
#   <export-dir>    the files the sink printed for the session (tools/export_debug_output.py): <unit>.silica,
#                   <unit>.wire and <unit>.bees.config
#   <unit>          the Silica unit, for example erl_hub
#   <leaf-dir>      where to build (created); the program is <leaf-dir>/dangerous_<unit>
#   start-delay-ms  how long after the node starts the program's run/0 is started (default 0): a node that dials needs
#                   its link up before it sends, and BEES does not buffer a send to a proxy before that
#
# What this is: BEES's compiler guide N2.1 and N2.2 for a unit the sink printed. The sink writes the unit (a library:
# to_silica_start/0 and run__spawn/0), the manifest and bees.config. BEES's root unit (dangerous_<unit>) is written
# here, by BEES's own tools/bees_edge_gen.py, from the carrier edge, the BEAM-mode node edge and a role file that holds
# main: report failures, start the node (the carrier, EPMD, the cookie), start the unit's processes, call run/0.
# The program source must have no `main/0` (the sink would print a second main): its entry is run/0.
set -eu
BEES="$(cd "${1:?bees-root}" && pwd)"; CC="$(cd "$(dirname "${2:?compiler}")" && pwd)/$(basename "$2")"
EXP="$(cd "${3:?export-dir}" && pwd)"; UNIT="${4:?unit}"; LEAF="${5:?leaf-dir}"; DELAY="${6:-0}"
SRC="$BEES/trials/n2_live/nodes/l"      # a BEAM-mode leaf: the layout to copy
SILICA_STD="$(cd "$(dirname "$CC")/.." && pwd)/compiler/stdlib"
mkdir -p "$LEAF/lib" && LEAF="$(cd "$LEAF" && pwd)"
cd "$LEAF"
for f in "$SRC"/lib/*.silica "$SRC"/lib/*.atoms; do                       # BEES units: listed in the leaf's silica.config, compiled with the node program (one compilation unit)
    [ -L "$f" ] && ln -sfn "$(cd "$(dirname "$f")" && cd "$(dirname "$(readlink "$f")")" && pwd)/$(basename "$(readlink "$f")")" "lib/$(basename "$f")"
done
ln -sfn "$BEES/native/dangerous_exposure_source" dangerous_exposure_source
ln -sfn "$SILICA_STD/Supervisor.silica" lib/Supervisor.silica
cp "$EXP/$UNIT.silica" "lib/$UNIT.silica"
# The sink's atoms manifest for the unit (BEES compiler guide A1.2): bees_config generate merges it into bees_atoms, and
# bees_config check allows the unit to write exactly those atoms as literals (BEES, 2026-11-17; before that a patch was needed).
cp "$EXP/$UNIT.atoms" "lib/$UNIT.atoms"
cp "$EXP/$UNIT.wire" node.wire; cp "$EXP/$UNIT.bees.config" bees.config
: > node.atoms
# the cookie file bees.config names (relative to the leaf): one line, not readable by others
cookie=$(sed -n 's/.*{cookie_file, "\([^"]*\)"}.*/\1/p' bees.config); printf 'to-silica-node-kit-cookie\n' > "$cookie"; chmod 600 "$cookie"
# A dial peer whose host is a name (not an IPv4 literal) needs BEES's resolver edge: bees_edge_gen.py --resolve and its
# three units (the layout of BEES's trials/n2_live/nodes/d). Without it the node prints "resolve <host>: not built into
# this program" and never dials. A node that only listens, or dials IPv4 literals, is built without it.
RESOLVE=""
if grep -E '\{role, dial\}' bees.config | grep -Ev '\{host, "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"\}' | grep -q '{host, "'; then
    RESOLVE="--resolve"
    for u in bees_addr dangerous_bees_resolve dangerous_bees_resolve_native; do ln -sfn "$BEES/src/shim/$u.silica" "lib/$u.silica"; done
fi
cat > run.role <<ROLE
// main of a node program the sink printed (tools/node_kit/build_node.sh): the failure reporter, the node, the unit's
// processes, then run/0 after $DELAY ms (a dialing node's link must be up before it sends).
fn starter(msg: int64, st: int64) -> (:no_reply, int64) {
    sequence
        _: actor_ref <- ${UNIT}@run__spawn()
    produces pure (:no_reply, st + 1) end
}
fn main() -> int64 {
    sequence proc[concurrency, device_io]
        _: atom <- start_reporter();
        n: actor_ref <- node_start(io_ms(), tick_ms());
        _: boolean <- ${UNIT}@to_silica_start();
        s: actor_ref <- spawn(0, starter, stack_policy(0, :keep_last_message), state_policy(:keep_state_area));
        t: timer_ref <- send_after($DELAY, s, 0 impl ActorMessage {});
        _: int64 <- wait_for_exit()
    produces pure 0 end
}
ROLE
ROLES="$BEES/trials/n2_dist/roles"
cat > Makefile <<MK
BEES_ROOT := $BEES
LEAF_DIR := $LEAF
ROLES := \$(BEES_ROOT)/trials/n2_dist/roles
EDGE_GEN := \$(BEES_ROOT)/tools/bees_edge_gen.py
PART := \$(BEES_ROOT)/src/shim/beam_node_edge.part
USES := --use bees_msgs --use bees_dist --use bees_ingress --use bees_peers --use beam_dist --use beam_conf --use beam_peers --use dangerous_beam_auth --use dangerous_beam_net --use $UNIT
_ := \$(shell cd "\$(LEAF_DIR)" && "\$(BEES_ROOT)/tools/bees_config_beam.py" generate --config bees.config -o lib node.wire 1>&2 && \\
	"\$(EDGE_GEN)" dangerous_$UNIT dangerous_$UNIT.silica \$(USES) $RESOLVE \$(PART) \$(ROLES)/node.role \$(ROLES)/cookie_conf.role \$(ROLES)/timing_conf.role run.role)
include \$(BEES_ROOT)/tools/trial.mk
MK
# The root unit is generated while make reads the Makefile, so the entry list is empty on the first run (BEES's own
# n2_live Makefile builds twice for the same reason): the second run links.
for pass in 1 2; do
    make -s build SILICA_COMPILER="$CC" 2>&1 | tail -4
done
ls -la "$LEAF/dangerous_$UNIT"
