# Golden sessions (contract T11.1)

Each golden is one connection: the frames a sender writes and the replies a transpiler must give. All are check-mode
sessions (contract §6.5) or need no session, so playing them stores nothing.

| File | Content |
| --- | --- |
| `<name>.frames` | the sender's bytes, frame after frame: a 4-byte big-endian length, then the ETF term as `term_to_binary/1` writes it (contract T4.1, T4.2). The first frame is the connection's first; the rest are sent under credit (T6.2) |
| `<name>.expect` | the replies, one Erlang term per line ending in a full stop, reduced to what the contract fixes (below) |
| `INDEX.txt` | every golden: name, number of frames, what it shows |
| `goldens.erl` | the terms the files are generated from, the generator and a player |

Reduced replies: `{welcome, Flow}` (the session id is the transpiler's to choose), `{refused, Reason}` and
`{rejected, Seq, Reason}` (`detail` and `where` are text for people), `{diagnostic, Seq, Code}`,
`{result, Status, Counts, Files}`, `{released, Freed}`, and `closed` when the transpiler closes with no result.
`(:credit, n)` frames are not listed: when they come is the transpiler's business.

```sh
erlc -o <ebin> contract/examples/add_example.erl contract/goldens/goldens.erl
erl -noshell -pa <ebin> -s goldens play <port> contract/goldens     # against a running transpiler; status 0 if all match
erl -noshell -pa <ebin> -s goldens write contract/goldens           # regenerate after changing goldens.erl
```

What is and is not here (2026-11-13): `ok_types_stated`, a function typed as contract §8.6 asks (a type form
before its use, hints on a binding and on a call, `to_float`, a guard on the divisor); every message M1 to M7, every form kind, every high-level node H1 to H40 and
low-level node L1 to L7, every type entry, hint strength and policy; a golden for each rejection the transpiler
implements (`seq_gap`, `unit_order`, `bad_unit_name`, `bad_index`, `bad_hint`, `profile`, the decoder's reasons,
T5.3a, the counts of T5.3b) and for the refusals `contract`, `choices`, `bad_hello`. There is no golden for
`:bad_choice` and `:low_level` (the transpiler does not check them yet; `silica-sink/DECISION_DATA_unbuilt_p0.md`),
for `:no_credit` and `:too_large` (they need a sender that breaks the framing or the credit rule, which a `.frames`
file played under credit cannot express), or for transpile-mode replies (`:stored`, resume, release of a held
session), which depend on the transpiler's storage and are tried in `silica-sink/trials/p2_actors`.
The node tables are valid in shape and indices only; they are not meaningful programs.
