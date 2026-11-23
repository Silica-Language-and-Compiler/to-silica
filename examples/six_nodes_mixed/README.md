# six_nodes_mixed: one mesh, six nodes, four languages

A complete mesh of six nodes (fifteen links) in which the nodes are written in different languages and still talk to
each other, because all of them become Silica programs on BEES's BEAM mode (EPMD, cookie; contract T9.17).

| Node | File | Language | Links |
| --- | --- | --- | --- |
| `xa@localhost` | `mesh6_a.erl` | Erlang, through to-silica | listens for the five others |
| `xb@localhost` | `mesh6_b.ex` | Elixir, through to-silica | dials xa, listens for the rest |
| `xc@localhost` | `mesh6_c.gleam` | Gleam, through to-silica | dials xa and xb, listens for the rest |
| `xd@localhost` | `mesh6_d.erl` | Erlang, through to-silica | dials xa to xc, listens for xe and xf |
| `xe@localhost` | `mesh6_e.ex` | Elixir, through to-silica | dials xa to xd, listens for xf |
| `xf@localhost` | `mesh6_f.silica` | Silica, written by hand | dials the five others |

Every node serves requests on its registered name `<x>_in` and asks the five other nodes to double a number (node
1..6 asks node 1..6 for 10 * asker + asked). A request is `(request, <name to answer to>, <number>)` and an answer is
`(reply, <name of the service>, <number>)`; both names are atoms, so the wire shape is `(atom, atom, int64)` in
every language. Thirty requests and thirty answers cross the fifteen links.

## The Silica node

`mesh6_f.silica` is not printed by to-silica. It is about a hundred lines: two actors registered as `f_in` and
`f_inbox`, an actor that asks, and the two functions the node's main calls (`to_silica_start/0`, `run__spawn/0`).
Nothing in it mentions the network: it casts to registered names, and BEES's proxies carry the messages. The three
files a transpiled node gets from the sink are written by hand beside it: `mesh6_f.wire` (the manifest),
`mesh6_f.bees.config`, and `mesh6_f.atoms` (the atoms the unit writes as literals).

## Build and run

Transpile the five source programs with their senders (`--mode transpile`), export the sink's files
(`tools/export_debug_output.py`), and build each node with `tools/node_kit/build_node.sh` (start delay 6000 ms). The
Silica node is built by the same script with this directory as the export directory and `mesh6_f` as the unit.
Start the six programs within a few seconds of each other, with EPMD running.

Ran live on 2026-11-20 (compiler 999906): every node completed five handshakes, answered five requests and printed
five answers, with the thirty expected values and no refused payload. Logs: `tools/node_kit/live_run_mixed6_*.txt`.
