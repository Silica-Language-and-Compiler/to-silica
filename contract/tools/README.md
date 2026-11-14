# Contract tools

## Checking a sender: check mode

The executable check of the contract is a running transpiler in **check mode** (contract §6.5). Send a hello with
`options.run.mode` `:check` and then your frames, exactly as you would to transpile. Every frame is validated with
the normative schema's own decoders (`../tcp_transport_v1.silica`) and answered: `(:rejected, …)` for a bad frame,
and a final `(:result, …)` whose `status` is `:ok` only when no frame was rejected. Nothing is stored or transpiled.

There is deliberately no file-based checker: a sender is checked over the same TCP path it uses in production, and
no sender has to write Silica's storage format.

## Offline checks

A binding's checker, where one exists, checks terms without a transpiler: `../bindings/erlang/check_frame.erl`.
Bindings are derived and non-normative; when a binding's checker and check mode disagree, check mode is right.

## Silica's limits that shaped the schema

Measured 2026-11-12 with `../silica/binaries/silica-999919-macos-applesilicon`: a record decodes only with at most
4 fields, a tuple with at most 8 elements, and a record field may not be named `unit`. A list whose element type
mixes bare atoms with tagged tuples that hold lists makes the derived decoder fault when it decodes one, which is
why the type table has `(:t_basic, kind)` and no bare-atom entry (contract §8.5). Compiling the schema unit
takes about three minutes, and it cannot be compiled in one compiler process together with the transpiler's own
units with compiler 999919 (the compiler ran out of memory). **With compiler 999916 (2026-11-13) it can:** one
compiler process compiled the schema unit and all the transpiler's units in 343 s with at most 2.5 GB resident, and
`../../silica-sink/build.sh` now builds that way; the limits on shapes above were re-tested with 999916 and are
the same, except that the 8-element limit on a decoded tuple did not reproduce with either compiler (9- and
10-element tuples decoded). Compile it as Silica's `programmer_tools/transport_beam_demo/run_demo.sh` compiles its
program: a directory holding `wire_etf.silica` (from Silica's `compiler/stdlib`) and `tcp_transport_v1.silica`, a
`silica.config` listing them in that order, then the compiler with no arguments.
