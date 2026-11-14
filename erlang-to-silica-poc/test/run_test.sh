#!/bin/sh
# Builds erlang-to-silica-poc and runs its test. Usage: test/run_test.sh [port]
# With a port, the frames are also sent to a to-silica transpiler listening there, in check mode.
set -e
cd "$(dirname "$0")/.."
mkdir -p ebin
erlc -Wall -o ebin src/*.erl test/e2s_test.erl
erlc +debug_info -o ebin ../contract/bindings/erlang/tcp_transport_v1.erl ../contract/bindings/erlang/check_frame.erl
erl -noshell -pa ebin -s e2s_test main "$@"
