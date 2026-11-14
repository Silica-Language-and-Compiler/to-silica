#!/bin/sh
# Runs the tests of gleam-to-silica-poc. Usage: test/run_test.sh [port]
#
# The offline tests check every frame with the contract's Erlang binding
# (../contract/bindings/erlang/check_frame.erl), so the two binding modules
# are compiled first, with debug_info, and put on the code path.
# With a port (or TO_SILICA_PORT set), the frames are also sent to a to-silica
# transpiler listening on 127.0.0.1 at that port, in check mode.
set -e
cd "$(dirname "$0")/.."
bindings="$(pwd)/build/contract_bindings"
mkdir -p "$bindings"
erlc +debug_info -o "$bindings" \
    ../contract/bindings/erlang/tcp_transport_v1.erl \
    ../contract/bindings/erlang/check_frame.erl
if [ -n "$1" ]; then
    TO_SILICA_PORT="$1"
    export TO_SILICA_PORT
fi
ERL_FLAGS="-pa $bindings" gleam test
