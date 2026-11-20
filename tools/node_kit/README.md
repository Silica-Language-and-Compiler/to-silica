# node_kit: building a sink-printed node program with BEES

`build_node.sh` wraps the files the sink prints for a node program (`<unit>.silica`, `<unit>.wire`,
`<unit>.bees.config`, `<unit>.atoms`; contract T9.17) in BEES's BEAM-mode node layer, using BEES's own tools
(`bees_config_beam.py`, `bees_edge_gen.py`, `trial.mk`): the root unit `dangerous_<unit>` with `main` (failure
reporter, node start with the carrier, EPMD and the cookie, the unit's `to_silica_start()`, then `run__spawn()`).
The program's entry must be `run/0`, not `main/0`: BEES owns `main`.

```sh
tools/node_kit/build_node.sh <project-bees> <compiler> <export-dir> erl_hub  <leaf> 0
tools/node_kit/build_node.sh <project-bees> <compiler> <export-dir> erl_edge_a <leaf> 2000   # a dialing node waits 2 s
```

**Atoms (option 3, decided 2026-11-16).** The printer writes its atoms as literals, and BEES's `tools/bees_config.py
check` (rule D30, contract A6.3) refuses a literal outside `bees_atoms`. The sink now writes the unit's atoms as
`<unit>.atoms` (BEES compiler guide A1.2); `bees_config generate` merges it into `bees_atoms`, so the atoms exist at
both ends. BEES's check now accepts the atoms a unit's own manifest lists (2026-11-17), so no patch is needed.

**Redial.** BEES has no default for `redial` (N2c): a node with a dial peer states it (`{redial, off}` or `{redial, Initial, Max}` in the
program's `-silica_node`, contract T9.17), a node without one must not.


**Run 2026-11-17 (compiler 999909 via `silica-compiler`, project-bees working tree on a889471, Apple Silicon, EPMD on 4369): the
three nodes, Erlang programs.** The hub (`erl_hub`, two listen peers) and both edges (`erl_edge_a`, `erl_edge_c`, dial through EPMD, redial
250 to 4000 ms) built with BEES's own check and ran together: cookie digest accepted and handshake complete with both,
`hub: request 21 from a_inbox`, `hub: request 34 from c_inbox`, `a: the hub answered 42`, `c: the hub answered 68`
(`live_run_hub.txt`, `live_run_edge_a.txt`, `live_run_edge_c.txt`). The Elixir programs (`elixir-to-silica-poc/examples/three_nodes/`) ran the same way: `{:hub_got, 21, :a_inbox}`, `{:hub_got, 34, :c_inbox}`, `{:a_got_answer, 42}`, `{:c_got_answer, 68}` (`live_run_elixir_*.txt`). The Gleam programs (`gleam-to-silica-poc/examples/three_nodes/`, Gleam 1.19.2) ran live on 2026-11-18 with compiler 999906: `a: the hub answered 42`, `c: the hub answered 68` (`live_run_gleam_*.txt`).

**Name hosts (2026-11-18).** A peer host may be a name with the `epmd` port (`{host, "localhost"}, {port, epmd}`): BEES's
`bees_config_beam.py` accepts it, and a node that dials one needs BEES's resolver edge. `build_node.sh` reads the
unit's `bees.config` and, when a dial peer's host is not an IPv4 literal, passes `--resolve` to `bees_edge_gen.py` and
adds BEES's `bees_addr`, `dangerous_bees_resolve` and `dangerous_bees_resolve_native` units to the leaf (the layout of
BEES's `trials/n2_live/nodes/d`). Without that the node prints `resolve localhost: not built into this program` and never
dials. A node that only listens is built as before.

**Run 2026-11-18 (same compiler, project-bees on f3af955): the three nodes with `"localhost"` as every peer host.**
Each edge prints `[bees] resolve localhost: ok 127.0.0.1`, then `epmd: found, dialing hub`; the hub completes the
handshake with both, and the replies are the same (`a: the hub answered 42`, `c: the hub answered 68`). The three
`live_run_hub.txt`, `live_run_edge_a.txt`, `live_run_edge_c.txt` are this run. The Elixir set ran the same way the same day, with `"localhost"`
too: the same resolve and handshake lines, `{:hub_got, 21, :a_inbox}`, `{:hub_got, 34, :c_inbox}`, `{:a_got_answer, 42}`,
`{:c_got_answer, 68}` (`live_run_elixir_*.txt`).

**Run 2026-11-19 (compiler 999906, project-bees on e14d29a): the complete mesh, Erlang programs**
(`erlang-to-silica-poc/examples/three_nodes_mesh/`). Three nodes, a link for each pair: `erl_mesh_a` listens for both
others, `erl_mesh_b` dials `ma` and listens for `mc` (a node with both roles), `erl_mesh_c` dials `ma` and `mb`. All
three were built with a start delay of 4000 ms and started 0.7 s apart. Each node completed the handshake with both
others, answered both of their requests and printed both answers it asked for: `a: b_in answered 22`,
`a: c_in answered 24`, `b: a_in answered 42`, `b: c_in answered 44`, `c: a_in answered 62`, `c: b_in answered 64`
(`live_run_mesh_a.txt`, `live_run_mesh_b.txt`, `live_run_mesh_c.txt`).

**Run 2026-11-20: the same mesh as Elixir and as Gleam programs** (`examples/three_nodes_mesh/` of each sender; units
`ex_mesh_*` and `gl_mesh_*`; same compiler, BEES checkout, delay and node names, one language's three nodes at a
time). Both sets completed every handshake and all six requests and six answers: Elixir prints
`{:a_got_answer, :b_in, 22}` and so on to `{:c_got_answer, :b_in, 64}` (`live_run_elixir_mesh_*.txt`), Gleam prints
the Erlang set's lines (`live_run_gleam_mesh_*.txt`). The Gleam mesh writes its peer host as `localhost`. In the
logs a printed line is sometimes cut in two by a `[silica] root actor exited` line written at the same moment.

**Run 2026-11-20: a complete mesh of five nodes, in each language** (`examples/five_nodes_mesh/` of each sender;
units `erl_mesh5_*`, `ex_mesh5_*`, `gl_mesh5_*`; nodes `na` to `ne`; same compiler and BEES checkout). Ten links: a
node dials every node whose letter comes before its own, so `na` only listens, `ne` only dials and the other three
do both. Built with a start delay of 5000 ms, started 0.5 s apart, one language's five nodes at a time. In each
language every node completed four handshakes, answered four requests and printed four answers: twenty requests
and twenty answers, with the twenty expected values (`live_run_mesh5_*.txt`, `live_run_elixir_mesh5_*.txt`,
`live_run_gleam_mesh5_*.txt`).

A node is one compilation unit: the leaf's `silica.config` lists the program's unit and the BEES units, one compiler run compiles them. `build_node.sh` uses BEES's `trial.mk`, which assembles the compiler's per-unit output and links it; that is BEES's stand-in and goes when BEES becomes a source library (project-bees N0c).
