# to-silica
A collection of officially tracked transpilers from various languages to silica.

All proof of concept compilers are required to have -poc at the end of their names.

## How it fits together

```
 your source file          language side (one per language)                 Silica side
 examples/demo.erl  ──►  parser + codex ──► TCP sender  ──frames over TCP──►  silica-sink  ──►  Silica source
                          (erlang-to-silica-poc/ …)       127.0.0.1:7411      (a Silica app:    (one unit per
                                                                               validate, store,   source module)
                                                                               print)
```

- The **language side** owns everything about its language: parsing, type checking, every data type, and its own
  semantics (for example how code around a `receive` is split). It sends the program as frames to the sink.
- The **sink** (`silica-sink/`) is one Silica application shared by all languages. It validates and stores frames and
  prints Silica. It infers and converts nothing.
- The **contract** (`contract/`) is the agreement between the two: the frame format, the node and type tables, the
  rules (`T…`, `H…`, `M…`, `R…` ids).

## I want to…

| I want to… | Go to |
| --- | --- |
| **write a sender for a new language** | [HOWTO_language_creators.md](HOWTO_language_creators.md), then copy the nearest PoC below |
| see **how an existing language is converted** | the PoC for that language (table below): its `README.md`, then `src/` or `lib/` |
| see the **programs that are converted** | `examples/` in each PoC: `demo` and `actors` |
| see **what a PoC cannot convert** | `test/fixtures/` in each PoC (deliberate gaps), and [SENDER_GAPS_STATUS.md](SENDER_GAPS_STATUS.md) |
| read the **exact frame and node rules** | [contract/tcp-transport-v1.md](contract/tcp-transport-v1.md); the normative schema is [contract/tcp_transport_v1.silica](contract/tcp_transport_v1.silica) |
| see a **worked session** frame by frame | [contract/examples/](contract/examples/) and the golden sessions in [contract/goldens/](contract/goldens/) |
| **check** my sender's frames | check mode of a running sink ([contract/tools/README.md](contract/tools/README.md)) |
| **build and run the sink** | [silica-sink/build.sh](silica-sink/build.sh) (about six minutes); what is built: [silica-sink/STATUS.md](silica-sink/STATUS.md) |
| understand **how the sink is designed** | [silica-sink/silica_sink_design.md](silica-sink/silica_sink_design.md) |
| run the **sink's trials** | `silica-sink/trials/run_trials.sh <work-dir> <port> [all]` |
| see **three nodes that send messages to each other** (hub topology, BEES BEAM mode) | `examples/three_nodes/` in each PoC, and contract T9.17 |
| see **a complete mesh** (three nodes, five nodes), and **six nodes of four languages in one mesh** (Erlang, Elixir, Gleam, hand-written Silica) | `examples/three_nodes_mesh/` and `examples/five_nodes_mesh/` in each PoC; [examples/six_nodes_mixed/](examples/six_nodes_mixed/) |
| see **what was found when real apps went through** | [APP_GAPS.md](APP_GAPS.md) (newest first) |
| get **Silica source out** of the sink | [tools/export_debug_output.py](tools/export_debug_output.py) (provisional exporter) |

## The senders

Each PoC is a working foundation for that language's owners. Each holds its parser/codex, its TCP sender, its tests,
two example programs and a README with a quick start and an "Extending this sender" section.

| Language | Directory | Codex | Examples (converted) | Tests |
| --- | --- | --- | --- | --- |
| Erlang | [erlang-to-silica-poc/](erlang-to-silica-poc/) | `src/e2s_codex.erl` | `examples/demo.erl`, `examples/actors.erl` | `test/run_test.sh [port]` |
| Elixir | [elixir-to-silica-poc/](elixir-to-silica-poc/) | `lib/e2s/codex.ex` | `examples/demo.ex`, `examples/actors.ex` | `mix test` (`TO_SILICA_PORT=<port>` for online) |
| Gleam | [gleam-to-silica-poc/](gleam-to-silica-poc/) | `src/gleam_to_silica_poc/codex.gleam` | `examples/demo.gleam`, `examples/actors.gleam` | `test/run_test.sh [port]` |

In each: `demo` is pure functions plus a small process example, `actors` is an application of several actors with a
supervisor. All six transpile with result `ok` and no gap. Beside the codex are the pieces that lower the language's
own semantics: `*_split` (code around a `receive`), `*_sup` (a static supervisor), and for Elixir and Gleam `lift`
(a function literal that captures nothing).

Quick start, with a sink listening on port 7411:

```sh
erl -noshell -pa ebin -run e2s main -extra --port 7411 --mode transpile examples/demo.erl   # in erlang-to-silica-poc/ (see its README to build ebin)
mix e2s --port 7411 --mode transpile examples/demo.ex                                       # in elixir-to-silica-poc/
gleam run -- --port 7411 --mode transpile examples/demo.gleam                               # in gleam-to-silica-poc/
```

Leave out `--mode transpile` for check mode, which validates the frames and stores nothing.

## Other directories

- [elixir-to-silica/](elixir-to-silica/), [erlang-to-silica/](erlang-to-silica/), [gleam-to-silica/](gleam-to-silica/),
  [haskell-to-silica/](haskell-to-silica/): reserved for each language's released transpiler (source and releases).
  They hold only a README for now.
- [contract/bindings/](contract/bindings/): derived, non-normative type bindings (Erlang so far).
- [silica-sink/src/](silica-sink/src/): the sink's Silica source (`*.silica.in` are expanded by
  `silica-sink/tools/expand.py`).

## Not in this repository

The Silica compiler and standard library live in a sibling checkout (`../silica`; `SILICA` in `build.sh`). The sink is
built with `silica-999906-macos-applesilicon` from its `binaries/` (the default of `build.sh` since 2026-11-18; it was 999909 from 2026-11-16). This repository only reads and runs them.

## Documents

- [HOWTO_language_creators.md](HOWTO_language_creators.md): **start here if you own a language.** A step-by-step guide to writing a sender: who does what (you decide every data type and every numeric conversion, and you lower your language's own semantics, such as the code around a `receive`, before you send; the transpiler infers nothing and splits nothing), the connection and frame sequence, a first session in check mode, how to state types, gaps, release, resume, names and testing.
- [contract/tcp-transport-v1.md](contract/tcp-transport-v1.md): the TCP transport contract a language's sender implements. Its normative schema is the Silica unit [contract/tcp_transport_v1.silica](contract/tcp_transport_v1.silica). A worked example is in [contract/examples/](contract/examples/), checkers in [contract/tools/](contract/tools/), and derived, non-normative type bindings for other languages in [contract/bindings/](contract/bindings/).
- [silica-sink/silica_sink_design.md](silica-sink/silica_sink_design.md): the design of the Silica application that receives the transport, stores it locally and writes Silica.
- [silica-sink/STATUS.md](silica-sink/STATUS.md): what is built in the sink and what is not.
- [APP_GAPS.md](APP_GAPS.md) and [SENDER_GAPS_STATUS.md](SENDER_GAPS_STATUS.md): gaps found by sending working applications, and what was done about each, per language.
