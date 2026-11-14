# to-silica
A collection of officially tracked transpilers from various languages to silica.

All proof of concept compilers are required to have -poc at the end of their names. 

## Documents

- [HOWTO_language_creators.md](HOWTO_language_creators.md): **start here if you own a language.** A step-by-step guide to writing a sender: who does what (you decide every data type and every numeric conversion, and you lower your language's own semantics, such as the code around a `receive`, before you send; the transpiler infers nothing and splits nothing), the connection and frame sequence, a first session in check mode, how to state types, gaps, release, resume, names and testing.
- [contract/tcp-transport-v1.md](contract/tcp-transport-v1.md): the TCP transport contract a language's sender implements. Its normative schema is the Silica unit [contract/tcp_transport_v1.silica](contract/tcp_transport_v1.silica). A worked example is in [contract/examples/](contract/examples/), checkers in [contract/tools/](contract/tools/), and derived, non-normative type bindings for other languages in [contract/bindings/](contract/bindings/).
- [silica-sink/silica_sink_design.md](silica-sink/silica_sink_design.md): the design of the Silica application that receives the transport, stores it locally and writes Silica.
- [silica-sink/](silica-sink/): silica-sink, the Silica application that receives every sender's frames and writes Silica (`silica-sink/src/`, built with `silica-sink/build.sh`); what is built and what is not is in [silica-sink/STATUS.md](silica-sink/STATUS.md).
- [erlang-to-silica-poc/](erlang-to-silica-poc/), [elixir-to-silica-poc/](elixir-to-silica-poc/), [gleam-to-silica-poc/](gleam-to-silica-poc/): proof-of-concept senders, each written in its own language: an inbound codex (that language's own parser to the contract's frames) and a TCP sender.
- [tools/](tools/): `export_debug_output.py`, the provisional exporter of the transpiler's debug output.
