# Decision data: what the printer does about types and names

Evidence for one pending decision: how much the printer (`silica-sink/src/ts_print.silica.in`) does about numeric
types and about names, and whether the sender or the sink owns that work. Measured 2026-11-13, Apple Silicon,
Silica compiler `silica-999919-macos-applesilicon`, Erlang/OTP 29, Elixir 1.20.5, Gleam 1.19.2 (all three installed
and run). Nothing under `silica` or `project-bees` was changed. Every experiment is kept in
`/private/tmp/claude-501/-Volumes-2T-to-silica/b923f54f-c3c2-4a04-835a-2e1dc9367430/scratchpad/w2/decision_printer/`
(directory names are given as `[n1]`). Only what was run is reported; section 5 lists what was not.

How a test was run: one directory per test, `silica.config` naming the unit(s), the compiler run with no arguments;
programs assembled and linked as STATUS.md describes. A normal run of every program here ended with exit status 2
(not investigated). Compiler messages are quoted as printed, without the "See specification" line.

## 1. Numeric mixing

### 1.1 What Silica accepts

Each row is the unit `module nX; export f/N; fn f(<params>) -> <result> { <body> }`.

| Dir | Parameters | Result | Body | Compiler |
| --- | --- | --- | --- | --- |
| `[n1]` | `a: float64, b: int64` | `float64` | `a * b` | `E2003 type mismatch: b` (line 4 column 9) |
| `[n2]` | `a: int64, b: int64` | `float64` | `a / b` | `E2003 type mismatch: a` |
| `[n3]` | `a: int64` | `float64` | `a + 1.5` | `E2003 type mismatch: a` |
| `[n4]` | `a: int64, b: float64` | `boolean` | `a < b` | `E2003 type mismatch: a` |
| `[n5]` | `a: int64, b: float64` | `boolean` | `a == b` | `E2003 type mismatch: a` |
| `[n6]` | `a: int32, b: int64` | `int64` | `a + b` | `E2003 type mismatch: a` |
| `[n6b]` | `a: int32` | `int32` | `a + 1` | compiles |
| `[n16]` | `a: float64` | `float64` | `a * 2` | compiles; `g(1.25)` printed `2.5` |
| `[n16]` | none | `float64` | `1` | compiles; printed `1.0` |
| `[n16]` | `a: float64` | `boolean` | `a < 3` | compiles; `h(2.5)` printed `true` |
| `[n12]` | `a: float64, b: float64` | `float64` / `boolean` | `a / b`, `a == b` | compile; `d(7.0, 2.0)` printed `3.5`, `eq(1.0, 1.0)` printed `true` |

So: no implicit conversion between `int64` and `float64` or between integer widths, in arithmetic or comparison. One
exception observed: an **integer literal** next to a float operand, or where a `float64` is expected, is taken as a
float (`[n16]`). A float literal next to an integer operand is not (`[n3]`). The specification says the same of
widths (§8.2.3: "Types must match exactly; no widening") and describes `/` only for integers (§7.3: "integer division
(truncates toward zero)").

### 1.2 Conversion builtins

The specification lists these (§22.19, "Wire Transport Builtins"; "The bit, atom and width conversions below are
pure"), and the compiler source lists the same names (`compiler/src/sir_generator/terms/transport_calls.silica`,
`is_transport_builtin`):

```
float64_bits(f: float64) -> int64,  float64_of_bits(b: int64) -> float64      // bit patterns, not values
float32_to_float64(f: float32) -> float64,  float64_to_float32(f: float64) -> float32
to_int64(x: <any integer type>) -> int64,  to_uint64(x: <any integer type>) -> uint64
to_int8(n: int64) -> int8 ... to_uint32(n: int64) -> uint32   // truncating width conversions
```

**No builtin converts an integer value to a float value or a float value to an integer** in either place. Tested:

| Test | Source | Result |
| --- | --- | --- |
| `[n7]` widening | `to_int64(a)` with `a: int32`, then `+ 1` on 41 | printed `42` |
| `[n7]` narrowing | `to_int64(to_int32(4294967298))` | printed `2` (truncated, no failure) |
| `[n7]` float widths | `float32_to_float64(float64_to_float32(0.1))` | printed `0.100000001490116` |
| `[n7]` bits | `float64_of_bits(4607182418800017408)`; `float64_bits(1.0)` | printed `1.0`; `4607182418800017408` |
| `[n8_*]` int to float | `to_float64(a)`, `int64_to_float64(a)`, `to_float(a)`, `float64_of_int64(a)` | each `E2007 unknown function: <name>` |
| `[n8_float64]` | `float64(a)` | `E1040 expected ';' after this statement before the next statement` |
| `[n8f_*]` float to int | `float64_to_int64(a)`, `truncate(a)`, `round(a)`, `floor(a)` | each `E2007 unknown function: <name>` |
| `[n8f_to_int64]` | `to_int64(a)` with `a: float64` | `E2003 to_int64 expects an integer argument bound to a typed name; got float64` |

### 1.3 A conversion written in Silica works

`[n9]`, complete unit apart from `main` (which prints each call):

```silica
fn i2f_pos(n: int64) -> float64 {
    case n == 0 of {
        true -> 0.0;
        false -> case n % 2 == 0 of {
            true -> 2.0 * i2f_pos(n / 2);
            false -> 2.0 * i2f_pos(n / 2) + 1.0
        }
    }
}
fn i2f(n: int64) -> float64 {
    case n < 0 of { true -> 0.0 - i2f_pos(0 - n); false -> i2f_pos(n) }
}
fn mean_move(p0: int64, p1: int64) -> float64 {          // APP_GAPS X4, with conversions inserted by hand
    case p1 == 0 of { true -> 0.0; false -> i2f(p0) / i2f(p1) }
}
fn scale(p0: float64, p1: int64) -> float64 {            // demo.erl scale/2, first product only
    p0 * i2f(p1)
}
```

Output: `i2f(0)` `0.0`; `i2f(7)` `7.0`; `i2f(0 - 3)` `-3.0`; `i2f(9007199254740993)` `9007199254740992.0` (Erlang's
`float(9007199254740993)` printed `9.007199254740992e15`); `mean_move(7, 2)` `3.5`; `mean_move(7, 0)` `0.0`;
`scale(2.5, 4)` `10.0`. It recurses once per bit (at most 63 calls, not tail calls). The other direction, `[n17]`: a
truncating `f2i` built from `float64_bits`, `/`, `%` and a power-of-two helper printed `3`, `-3`, `0`,
`1000000000000000` for `3.99`, `-3.99`, `0.5`, `1.0e15`.

### 1.4 Division by zero

| Test | Expression | Result |
| --- | --- | --- |
| `[n10]` | `d(0 - 7, 2)` with `fn d(a, b) { a / b }`; `(0 - 7) % 2` | printed `-3`; `-1` (truncation toward zero; Erlang printed the same for `-7 div 2`, `-7 rem 2`) |
| `[n10]` | `d(7, 0)` in `main` | the program printed `badarith` and ended with exit status 1; the line after it was not printed |
| `[n11]` | `r(7, 0)` with `a % b` | the same: `badarith`, exit status 1 |
| `[n13]` | `a / 0` with a literal zero | compiles (no compile-time message) |
| `[n12]` | `d(7.0, 0.0)` with `float64` | no failure; `print_float64` printed `9223372036854775807.000000000000000` |

### 1.5 The three languages

| Claim | Erlang (`erl -noshell -eval`) | Elixir (`elixir -e`) | Gleam (`gleam run`, `gleam build`) |
| --- | --- | --- | --- |
| integer with float | `2.5*4` → `10.0`; `1+1.5` → `2.5` | `10.0`; `2.5` | `a + b` with `a: Int, b: Float`: `error: Type mismatch` |
| division | `7/2` → `3.5`; `4/2` → `2.0` | `3.5`; `2.0` | `7 / 2` → `3` (Int); `7.0 /. 2.0` → `3.5`; separate `+` and `+.` |
| integer division | `7 div 2` → `3`; `-7 rem 2` → `-1`; `7.0 div 2` → `badarith` | `div(7,2)` → `3`; `rem(-7,2)` → `-1`; `div(7.0, 2)` → `ArithmeticError` | `-7 / 2` → `-3`; `-7 % 2` → `-1` |
| compare | `1 < 1.5` → `true` | `true` | `a < b` with Int and Float: `error: Type mismatch`, "The < operator expects arguments of this type: Int" |
| equality | `1 == 1.0` → `true`; `1 =:= 1.0` → `false` | `1 == 1.0` → `true`; `1 === 1.0` → `false` | `a == b` with Int and Float: `error: Type mismatch` |
| division by zero | `7 div 0`, `7 / 0` → `badarith` | `ArithmeticError` for both | `7 / zero` → `0`; `7 % zero` → `0`; `7.0 /. fzero` → `0.0` |

Sources of the claims besides these runs: Erlang Reference Manual, "Expressions", arithmetic and term comparison;
Elixir `Kernel` documentation (`//2`, `div/2`, `==/2`, `===/2`); the Gleam language tour ("Ints", "Floats": division
by zero is defined as zero).

Two consequences that follow directly from the tables:

- A Gleam program that the Gleam compiler accepts never mixes Int and Float in one operator, so every Gleam `(:op)`
  already satisfies Silica's rule. The remaining Gleam difference is division by zero: Gleam gives `0`, and the
  printer's `div` → `/` gives `badarith` in Silica (`[n10]`). The Gleam sender maps `DivInt` to `div` and `DivFloat`
  to `/`, and `AddInt | AddFloat` both to `+` (`codex.gleam`, the operator table).
- Erlang and Elixir need a conversion wherever an integer meets a float, and for every `/` on integers; `==` between
  an integer and a float needs one too, while `=:=` between them is `false` without looking at the values. The
  printer today maps `=:=` and `==` both to Silica `==`, and `div`, `/` both to Silica `/` (`ts_print.silica.in`,
  the operator table at lines 92 to 94).

## 2. Who can know the type of an expression

### 2.1 What the contract allows today

- T8.5: "A function form's `notes.hints` (§9.3) attaches a type to a node: a variable's binding, a function's clause
  pattern, a record or tuple construction, a message in a send or a receive clause. `node` is `-1` for the form's
  own signature". T9.7 adds: "Every H-node may be the target of an override (§7.3) ... and of a hint (§8.4)". So a
  hint on an operand node (a `(:var)`, a `(:call)`, an `(:op)`) is allowed by T9.7; T8.5's list does not name it.
- Strength and policy (§8.2, §8.3): `:proven`, `:declared`, `:inferred`; `:trust`, `:check`, `:advisory`.
- T8.6: "Conversions happen only at function entry and at message receipt, never inside an expression, so their cost
  is where people can see it." §8.3 shows these are conversions between untyped and typed code (`bees_term` to a
  Silica type). Read literally, T8.6 also forbids an int-to-float conversion inside `A * B`. To print `mean_move/2`
  under T8.6 as written, the conversion would have to happen at function entry (bind `f0 <- i2f(p0)` first and use
  `f0` in the body), or T8.6 would have to say that it speaks only of representation conversions.
- The type vocabulary (§8.5) has `:t_int` and `:t_float` and no "number" type. Erlang's `number()` has no entry.
- Appendix B has no conversion operator; the contract gives a sender no way to write "this integer as a float"
  except a `(:call)` to its own language's function (`erlang:float/1`), which the printer refuses (a call with a
  module name is a gap, `call_text`).

### 2.2 What the three senders send today

| Sender | Hints sent | Operands of an `(:op)` |
| --- | --- | --- |
| Erlang (`e2s_codex.erl`, `signature/1`) | one hint per function, `node => -1`, `strength => declared`, from `-spec` | no hint |
| Elixir (`codex.ex`, the `@spec` section) | one hint per function, `node: -1`, `:declared`, from `@spec` | no hint |
| Gleam (`codex.gleam`, `signature`) | one hint per function, `node: -1`, `Proven`, only when the signature is fully annotated ("glance has no types"); one generated actor-loop function carries an `Inferred` hint, also on `node: -1` | no hint |

No sender hints an inner node (`grep` for every place a hint is built: Erlang 1, Elixir 1, Gleam 2, all `-1`). The
sender sources were being edited by other work during this session; this is their state at the end of it. The Gleam sender parses with `glance` and does not run Gleam's type checker, so it
does not know the types of unannotated bindings; it does know from the operator spelling whether an operation is on
Ints or Floats, and that spelling is lost for `+ - *` and comparisons (one `op` text for both).

### 2.3 What the sink could infer

The sink has the parameter and result types from the signature hint and the kind of every literal. The printer is
called once per form, as each frame arrives (`ts_intake.silica.in`, `ts_print@form_source(f.body)`), and forms may come in any order (T5.3).

| Example | Operands | Derivable in the sink from one form? |
| --- | --- | --- |
| `mean_move(balance, moves) -> balance / moves`, `@spec (integer(), integer()) :: float()` | two parameters | yes: both `int64` from the hint; `/` is float division (Appendix B); so both are converted |
| `scale(F, N) -> F * N * 1.5`, `-spec (float(), integer()) -> float()` | two parameters and a float literal | yes: `F` `float64`, `N` `int64`; the product mixes, so `N` is converted; `(F * N)` is then float, as is `1.5` |
| a variable bound from a call to a function of the same unit | the callee's hint | only with the other forms of the unit at hand (a second pass, or a table of signatures kept per unit) |
| a variable bound from a call into another unit or session, from a function with no hint (APP_GAPS C6), from a message with no hint, or out of a `:dynamic` value | nothing | no |
| a `-spec` with `number()` | not expressible (§8.5) | no: integer or float is known only at run time, which is the untyped representation (`bees_term`), not built |

Neither (no hints on operands, no inference): the state today. Mixed expressions print as written and the unit is
refused by the compiler (`[n1]`, `[n2]`; APP_GAPS C9, X4). The alternative with no type knowledge is to make such a
form a gap, which also needs the types to know that it mixes.

## 3. Reserved words and names

### 3.1 The lists

**Specification §2.2.1** (79 words): `actor actor_ref atom atomic boolean buf case call_supervisor cast char
concurrency core_id core_set dangerous_actor_ref device_actor_ref device_io device_window effect efficiency_cores else
end enum export false float16 float32 float64 fn for from hot_swap if impl import int8 int16 int32 int64 lifetime
mailbox mem module network_io normal not of performance_cores proc produces provided pub pure recv ref region
register_rwr required return sequence spawn spawn_dangerous spawn_device spawn_device_registered spawn_registered
spawn_registered_supervisor string struct supervisor_ref trait true type uint8 uint16 uint32 uint64 underscore unit
use where`.

**Lexer** (`compiler/src/lexer/lexer_keywords.silica`, `keyword_token_kind`, 121 lexemes; `is_type_keyword` adds
`pid` and `dangerous_pid`, which get no keyword token). Differences:

- In the specification, not in the lexer (11): `else enum from hot_swap import network_io pub register_rwr type
  underscore where`. The compiler accepted all 11 in every position tested.
- In the lexer, not in the specification (55): `Bytes List String and band bnot bool bor bytes c_wrapper carried_on
  dangerous_pid demonitor device external_danger failure_reason foreign get_core_capabilities get_cpu_topology
  get_efficiency_cores get_performance_cores link meta monitor monitor_ref negate_float16 negate_float32
  negate_float64 negate_int16 negate_int32 negate_int64 negate_int8 normal_noncacheable normal_writeback
  normal_writethrough or pid pin_actor_realtime pin_actor_to_core pin_actor_to_efficiency_core pin_actor_to_numa_node
  pin_actor_to_performance_core rec register_actor remove_actor self send set_actor_priority shl shr
  spawn_dangerous_registered spawn_linked timer_ref unpin_actor wrapper_meta`.

**Builtin function names** (from `effect_checker_core.silica` `is_builtin_fn`, `type_checker_builtin_signatures.silica`
and `transport_calls.silica`; 58 of them tested, the list is in `words.py`): `println print print_string print_int64
print_float64 print_boolean print_atom concat concatenate contains ends_with starts_with length_bytes length_chars
substring substring_until_char prepend encode decode call call_registered cast_registered add_child stop_self
fail_self monotonic_time current_time send_after cancel_timer to_int64 to_int32 to_uint64 float64_bits
float64_of_bits float32_to_float64 char_code atom_name byte_at byte_slice bytes_of join_bytes actor_id peek poke
recreate checked_int64_add file_exists read_lines kill_abnormal wait_for_exit get_actor_memory_usage` and the seven
`negate_*`. The source lists more of the same families (`print_int8`, `to_uint8`, `pin_mode`, ...), not tested.

### 3.2 Compiler tests: 241 words, one compile per word and position

Words: the two lists above, the builtins, and 56 others (`params result main int float list Some None Ok Error in
let do when receive after try catch fun def ...`, and `len`, `at`, `heap_used`); all 56 were accepted everywhere. Templates (`iso.py`), `W` the word:

| Column | Unit(s) |
| --- | --- |
| def | `export W/1; export keep/0;` and `fn W(p0: int64) -> int64 { p0 }`, never called |
| call | `export W/1; export g/1;`, the same `fn W`, and `fn g(p0: int64) -> int64 { W(p0) }` |
| q-call | the same with `x@W(p0)` (the unit is `x`) |
| x-call | unit `x` exports `W/1`; unit `y`: `use x;` ... `x@W(p0)` |
| param | `fn f(W: int64) -> int64 { W }` |
| bind | `fn f(p0: int64) -> int64 { W: int64 <- p0; W }` |
| field | `x: { W: int64 } <- { W: p0 }; x.W` |
| module | unit `W` exports `f/1`; unit `y`: `use W;` ... `W@f(p0)` |

Totals (accepted of 241): def 229, call 74, q-call 127, x-call 127, param 128, bind 127, field 134, module 126.

| `W` | def | call | q-call | x-call | param | bind | field | module |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `case` | ok | E1069 | E1069 | E1069 | E1069 | E1069 | E1040 | E1069 |
| `unit`, `int64`, `string` | ok | E1040 | E1069 | E1069 | E1000 | E1040 | E1040 | E1040 |
| `export`, `of`, `true`\*, `List` | ok | E1040 | E1069 | E1069 | E1069 | E1040 | E1040 | E1040 |
| `end` | ok | E1040 | E1069 | E1069 | E1069 | E1040 | ok | E1040 |
| `self`, `send`, `spawn` | ok | E2020 | E1069 | E1069 | E1069 | E1040 | E1040 | E1010 |
| `link`, `monitor`, `demonitor` | E1068 | E1068 | E1069 | E1068 | E1069 | E1040 | E1040 | E1010 |
| `region`, `ref`, `buf`, `atomic` | ok | ok | E1069 | E1069 | E1000 | E1040 | ok | E1010 |
| `meta` | ok | E1040 | E1069 | E1069 | E1069 | E1058 | E1040 | E1040 |
| `provided`, `required` | ok | E1040 | E1069 | E1069 | E1069 | E1059 | E1059 | E1040 |
| `struct` / `sequence` / `produces` | E1047 / E1049 / E1048 in every column | | | | | | | |
| `concat`, `println`, `to_int64`, `negate_int64` (all 58 builtins) | ok | E2020 | ok | ok | ok | ok | ok | ok |
| `params`, `result`, `main`, `type`, `else`, `pid`, `div`, `rem` | ok | ok | ok | ok | ok | ok | ok | ok |

\* `true` and `false` as def: `E4011 function true shadows an imported or earlier definition (spec 19.3.2)`.

Messages, as printed:

- `E1069 function 'g' has no parsable body; an expression inside it could not be parsed (for example a call whose
  function name is a keyword such as link)`
- `E1040 expected ';' after this statement before the next statement`
- `E1000 There is an uncategorized syntactic defect in the code you are working on. ...` (it says the location is on
  a line before the one it names)
- `E2020 call to `concat` is ambiguous: `concat` is a builtin and a function in this module; call the module's
  function as `x@concat(...)``
- `E1068 'link' is an actor runtime intrinsic (link, monitor, demonitor) and cannot be the name of a module function
  or export; choose a different name`
- `E1058 'meta' is a reserved keyword and cannot be used as a variable binding name; choose a different name`;
  `E1059 'provided' is a reserved keyword and cannot be used as a record field name; choose a different name`
- APP_GAPS C22 reproduced (`[k_case]`, `case/1` the only export): `E4016 module must define main/0, export at least
  one function, or export a trait (spec 19.1, 3.4.8)`.

Findings:

1. **114 words cannot name a callable function**: exactly the lexer's 121 lexemes less the seven `negate_*`. Every
   call form is refused (q-call and x-call refuse the same 114). None of the 11 specification-only words is among
   them. The list for this compiler is `iso_fnq.tsv` in the experiment directory.
2. **Limitation observed: for 102 of those 114, the definition alone compiles with no message** (column def). A unit
   that exports `case/1` beside another export compiles; the error appears in whichever unit calls it. So "the
   generated unit compiled" does not show that its names are usable.
3. **A builtin's name is allowed as a function name, but an unqualified call is E2020.** The printer prints local
   calls unqualified (`call_text`). The message's own remedy, `unit@name(...)`, compiled for all 58. One further
   limitation observed: a qualified call whose argument is itself a qualified call is refused, `[q6]`
   `q6@concat(q6@g(p0), p0)`: `E2005 cannot infer concrete type for qualified call argument (needed to resolve
   trait-parameter body)`. An unqualified inner call (`[q2]`), an arithmetic argument (`[q1]`), or binding the inner
   call to a typed name first (`[q3]`) compiled.
4. STATUS.md limit 4, narrowed: of `params`, `result`, `export`, only `export` is refused (E1040 as a binding and as
   a field). `unit` as a record field: E1040, confirmed.
5. Parameters, bindings and fields refuse nearly the same set as functions (param 113, bind 114, field 107 of the
   114; `device` is accepted as a parameter; `atomic buf device_window end failure_reason ref region` as fields).
   The printer names parameters `p0, p1, ...` and prints no bindings, so today only function names and (when
   records are printed, APP_GAPS C4) field names reach Silica from the source.
6. Module names: `module case;` compiles alone (234 of 241), but 115 words cannot be used by a caller (`use W;` /
   `W@f`). The contract already forces a prefix on every unit (T5.2), so no unit is named by a bare keyword.
7. Atoms (`[at_*]`): `:case`, `:unit`, `:export`, `:fn`, `:true`, `:end`, `:int64`, `:sequence`, `:Foo`, `:ok` as
   an atom literal each compiled.

### 3.3 Identifier shape (`iso.py --words shapes`, same eight templates)

| Name | Result |
| --- | --- |
| `Foo`, `fooBar`, `F`, `FOO_BAR`, `f1`, `a__b`, `_lead`, `trail_`, `__x__`, `_`, `_1` | accepted in every position, including as a module name |
| `foo` and `Foo` in one unit (`[r4]`) | two functions; the program printed `12` |
| `a` repeated 31, 63, 64, 127, 128, 255, 256, 1000, 5000, 70000 times | accepted as function, parameter, binding and field; no length limit found. `[r1]`: a 5000-byte function name assembled, linked and ran (printed `117`). A module name is limited by the file name (macOS: "File name too long" from 255 bytes) |
| `café` | `E0001 unexpected character 'é': non-ASCII characters may appear only in string, character and atom literals and ...` |
| `valid?`, `save!` | `E1040` (as a parameter: `E1000`) |
| `hello world`, `a.b`, `a/b`, `a-b` | `E1045 function declaration 'world' is missing the 'fn' prefix; write 'fn <name>(...) -> <type> { ... }'` |
| `'case'` | `E0004 unterminated character literal: a character literal holds exactly one character, and no closing "'" follows` |
| `a$b` | `E0001 unexpected character '$': it does not begin any token (spec 2.2); ...` |
| `1abc` | `E0005 malformed numeric literal '1a': a numeric literal cannot be followed directly by a letter, ...` |

This agrees with specification §2.2.2 (`letter (letter | digit | "_")*`, letter including `_`).

### 3.4 Three link-level limits that any naming rule meets

The emitted symbol of a function is `<unit>_<function>`, with no arity (`x.sams`: `.global x_params`).

| Test | Source | Result |
| --- | --- | --- |
| `[r2c]` same name, two arities | unit `erl_o`: `export add/2; export add/3;` with both definitions; a caller of both | compiles (exit 0); assembler: `erl_o.sams:35:1: error: symbol 'erl_o_add' is already defined` |
| `[r2b]` the same in one unit with `main` | `add(1, 2) * 100 + add(1, 2, 3)` | `E2005 add argument count mismatch` at the two-argument call |
| `[r5]` same name, same arity | two `fn case_(p0: int64)` | `E4015 duplicate function definition case_ with same arity` |
| `[r3]` unit and function joined by `_` | unit `erl_a` exports `b_c/0`; unit `erl_a_b` exports `c/0`; `main` calls both | compiles; linker: `duplicate symbol 'erl_a_b_c' in: .../erl_a.o .../erl_a_b.o` |
| `[r8]` a function named `main` in a library unit | unit `erl_m` exports `main/0` (returns `int64`); the program's unit has its own `main` | compiles; linker: `duplicate symbol 'main' in: .../erl_m.o .../r8.o` |

Erlang and Elixir allow one name at several arities (Elixir default arguments create them), and the Erlang example
`actors.erl` exports `main/0` (the contract has an `(:entry)` form for it, not printed yet, APP_GAPS C7). The examples of the three proofs of concept have no name at two arities (checked with
`module_info(functions)` and `__info__(:functions)`).

### 3.5 What the three languages allow

| Language | Run here | Silica |
| --- | --- | --- |
| Erlang: any atom names a function | `q.erl` with `'case'/1`, `'hello world'/0`, `'Up'/0`, `'+'/2`, `'valid?'/1` compiled and ran: `1 hw up 3 true` | `case` reserved; the others not identifiers (3.3); `Up` accepted |
| Elixir: `?` and `!` endings, operators, any atom through `unquote` | `Foo.Bar` with `valid?/1`, `save!/1`, `a + b`, `:"hello world"`, `unit/1` ran; `__info__(:functions)` printed `[+: 2, "hello world": 0, save!: 1, unit: 1, valid?: 1]`; `Atom.to_string(Foo.Bar)` is `"Elixir.Foo.Bar"` | `valid?`, `save!`, `+` not identifiers; `unit` reserved; the module name has dots |
| Gleam: `[a-z][a-z0-9_]*` only | `pub fn Valid` : "I'm expecting a lowercase name here ... can contain a-z, 0-9, or _"; `valid?`: "I can't figure out what to do with this character"; `a__b_1` accepted | always an identifier in Silica |
| Gleam reserved words | refused as a function name ("This is a reserved word"): `as assert auto case const delegate derive echo else fn if implement import let macro opaque panic pub test todo type use` (22 tried, 22 refused) | of these only `case fn if` are also refused by Silica |
| Gleam names that Silica reserves | `pub fn export(module: Int)`, `pub fn region(ref: Int)`, `fn unit`, `string`, `end`, `of` compiled in Gleam | each is one of the 114 |
| Module names | `Elixir.Foo.Bar`, `gleam/int`: dots and slashes | not identifiers; the senders already send a `silica_unit` (T5.2) |

**The senders already mangle.** Each proof of concept applies its README's rules N1 and N4 before sending: N4, "`[A-Za-z0-9_]` kept;
`?` → `_q`; `!` → `_b`; any other character → `_x<hex code point>_`; an empty or digit-leading result gets `_` in
front"; N1, the module's segments in snake_case joined with `_` after the prefix. These rules are in the three
READMEs, not in the contract. Run with the Elixir sender's own module (`elixir -r lib/e2s/names.ex -e ...`):

```
"valid?" -> valid_q            "valid_q" -> valid_q
"save!" -> save_b              "save_b" -> save_b
"hello world" -> hello_x20_world   "hello_x20_world" -> hello_x20_world
"case" -> case      "unit" -> unit      "+" -> _x2b_      "main" -> main
Foo.Bar -> ex_foo_bar    FooBar -> ex_foo_bar    Foo_Bar -> ex_foo_bar
Foo.BarBaz -> ex_foo_bar_baz    Foo.Bar.Baz -> ex_foo_bar_baz
```

So the rule as built is not injective for functions or for modules, and leaves reserved words unchanged. Two modules
that map to one unit are caught by the sink (`:bad_unit_name`, "repeats", T5.2); two functions that map to one name
would meet E4015 in the compiler (`[r5]`).

### 3.6 Mangling schemes, each tested

All spellings below were accepted in all eight positions of 3.2 (`shapes`: `case_`, `case__`, `_case`, `r_case`,
`q_case`, `valid_q3F_`, `hello_q20_world`, `add_2`, `add__2`, `Elixir_Foo_Bar`, `gleam_int`).

| | S1: suffix for reserved words | S2: full escape | S3: arity in every name |
| --- | --- | --- | --- |
| Rule | a name on the reserved list gets `_` appended (`case` → `case_`) | every byte outside `[A-Za-z0-9_]` → `_qXX_` (hex); reserved words by S1 or by escaping one byte | every function `name/N` → `name__N` |
| Valid Silica name? | yes, `[r6]` `erl_q@case_(1)` ran | yes, `[r6]` `valid_q3F_`, `hello_q20_world` ran | yes, `[r10]` `case__1`, `main__0`, `concat__2`, `add__2`, `add__3` compiled, linked, printed `42`, with unqualified local calls |
| Injective? | no as stated: source `case` and source `case_` both give `case_` (E4015, `[r5]`). Yes if every name that is a reserved word followed by underscores also gets one more | no as stated: source `valid?` and source `valid_q3F_` collide. Yes if the introducer `_q` in a source name is itself escaped | yes when applied to every function: the text after the last `__` is always the arity, so `add__2/2` → `add__2__2` and `add/2` → `add__2` differ |
| Reserved words | handled; needs the 114-word list, which belongs to one compiler version (3.1: the specification's list differs from the lexer's in 66 words) | only with S1 added | handled with no list: no reserved word and no builtin tested ends in `__N` |
| Builtin names (E2020) | not handled; needs the builtin list too, or qualified calls with the limit of finding 3 | not handled | handled (`concat__2`, `[r10]`) |
| Two arities of one name (`[r2c]`) | not handled | not handled | handled (`add__2`, `add__3`, `[r10]`) |
| `main` in a library unit (`[r8]`) | not handled unless `main` is put on the list | not handled | handled (`main__0`) |
| Non-identifier bytes (`valid?`) | not handled | handled | not handled; needs S2 |
| Readable for a hand-written caller | `erl_demo@add(2, 3)` unchanged; `erl_q@case_(1)` | unchanged for ordinary names; `ex_m@valid_q3F_(3)` | every call changes: `erl_demo@add__2(2, 3)`; the `p1_export` trial and the contract's worked example call `erl_demo@add(2, 3)` today |
| What a caller in another unit must know | the reserved list and the rule | the escape rule | the rule only (the arity is the number of arguments it writes) |

Not removed by any of the three: the `<unit>_<function>` symbol collision of `[r3]` (unit `erl_a` function `b_c`
against unit `erl_a_b` function `c`). With N1 as built, `Foo` and `Foo.Bar` become `ex_foo` and `ex_foo_bar`, the
shape that collides. It would take a rule on unit names or a marker at the start of function names; not tested.

### 3.7 What BEES says

`project-bees/contract/so-you-want-to-write-a-compiler.md`:

- A1.1: "Emit Silica source, one unit per module or generated helper. Every unit's basename must be unique across the
  whole program, and must start with a prefix reserved for your language. BEES's own units use `bees_` and
  `dangerous_bees_`."
- A1.2: "Symbols must be identifiers (letters, digits and underscore, not starting with a digit); other spellings
  are not supported yet."
- A4.2 area (line 96): "Pool names are identifiers, unique in the program, and should carry your language's prefix".

BEES says nothing found here about function names, reserved words or arities. The contract's T5.2 takes A1.1 over
for `silica_unit`; T4.4 says identifiers travel as binaries and gives no rule for their spelling.

## 4. Options

**No recommendation is given: the evidence is not decisive between the options.** It is decisive on four narrower
points, which hold under every option: (i) printing mixed numeric expressions as written cannot compile (1.1);
(ii) Silica has no int-to-float builtin, so a conversion is a helper function that somebody emits (1.2, 1.3);
(iii) a reserved-word list taken from the specification is the wrong list (3.1, 3.2); (iv) one name at two arities
cannot be emitted under one Silica name (3.4).

| | Option A: the sender owns both | Option B: the sink owns both | Option C: split (names by a contract rule in the sender, types in the sink) |
| --- | --- | --- | --- |
| Summary | The printer stays a printer. The sender sends only names Silica accepts and only type-correct operators | The sender sends source names and source operators; the sink mangles and inserts conversions | The contract fixes one naming rule that senders apply; the sink infers numeric types and converts |
| Erlang, Elixir senders | must type every operand (they have only `-spec`/`@spec` today, 2.2), send an explicit conversion, and carry Silica's reserved and builtin lists (114 + builtins, per compiler version) or use a list-free rule such as S3 | no change for types; N4 could be dropped or kept | apply the contract's rule in place of N4 (N4 is not injective, 3.5); no type work |
| Gleam sender | types are already consistent (1.5); must keep the Int/Float spelling of `+ - *` and say what division by zero means; needs a rule for the Gleam names Silica reserves (`unit`, `export`, `end`, ...) | no change | apply the naming rule; no type work except division by zero |
| Contract text | add a conversion operator or node to Appendix B / §9.4; say in §8 that operand types are the sender's duty; add the naming rule and the reserved list (or S3) to §4 or §5; T8.6 unchanged in spirit but the new operator sits inside expressions | T8.5/T9.7 unchanged; T8.6 must be reworded or the conversion hoisted to function entry (2.1); state that names are source spellings and the sink's mangling is the published rule (a caller needs it, 3.6); H31 must say whose division-by-zero and whose `==` apply | add the naming rule (replacing the READMEs' N1, N4); T8.6 as in B; Appendix B must define `/`, `==`, `=:=` on mixed operands as the semantics the sink implements |
| Sink | checks only (reject or gap a name that is not acceptable, a mixed operator); the smallest printer; errors surface as T-diagnostics instead of E2003 from the compiler | needs a type pass per form plus a per-unit signature table (2.3), an emitted helper unit for `i2f` (1.3), the keyword and builtin lists of its compiler version, and a fallback (gap) where a type is unknown; mixed `number()` code stays unprintable until the untyped representation exists | the type pass and helper as in B; for names only a check that the rule was applied |
| What stays unsolved | the Erlang and Elixir senders cannot type operands that come from unhinted calls or messages either; they would send gaps | the same cases (2.3, last two rows) become gaps in the sink | the same cases; the `[r3]` symbol collision under every option |

## 5. Not run, and limits of this evidence

- Nothing on Linux or with another compiler build; the word lists are those of compiler 999919 and its source tree
  as read on 2026-11-13 (the binary's and the source's keyword tables were compared only through the 241 tests).
- Words outside the 241 were not tested; other contextual words may exist. Builtins beyond the 58 were not tested.
- `float32`, unsigned widths and overflow were not tested beyond `[n6]`, `[n6b]`, `[n7]`.
- The conversions `i2f` and `f2i` were tested on the values shown only; cost and stack use were not measured.
- No sender and no sink code was changed or run against the transpiler for this document; the mangling schemes
  were tested as hand-written Silica units, not as printer output.
- Type names and record field names under each scheme, and hints on inner nodes sent to the running sink, were not
  tested.

## 5a. Compiler 999916 (2026-11-13)

Sections 1.1 to 1.4, the ten words `case unit export self link region meta provided concat main` of 3.2 (def and
call), finding 3 of 3.2 and the five tests of 3.4 were run again with `silica-999916-macos-applesilicon`, each
beside 999919 in one directory (scratch `w3_limits/`): **the same messages and the same output in every case.**
Corrections to the text above that hold for both compilers: the "exit status 2" of the programs of section 1 is
the value their `main` returns (they return an atom; a `main` that returns `0` exits with 0); the E2020 message
reads "a function of this module". New, both compilers: `+`, `-` and `*` past `int64` wrap with no failure
(`max + 1` printed `-9223372036854775808`); `checked_int64_add` and `checked_int64_mul` return `(false, 0)` on
overflow.

## 6. Decision (2026-11-13)

**Decided by the user, binding:** the LANGUAGE side decides all data types, not the Silica side. The sender states
every type the transpiler needs and every numeric conversion; silica-sink never infers a type and never coerces
implicitly. It prints what it is told, and reports a clear diagnostic (with the file and line from the frame's
locations, and the construct named) when a needed type or conversion is missing or the typing is inconsistent.

This is option A of section 4 **for types** (numeric mixing, type tables, whose job it is). It answers decision 4
of STATUS.md as far as types go. **Name mangling is not decided by it** (section 3 stays open).

What was done with it (2026-11-13):

| Where | What |
| --- | --- |
| Contract | §8.6, rules T8.8 to T8.15: who decides (T8.8); what a "stated type" is, as a closed table (T8.9); where a type is required (T8.10 a to e: every function signature, every local binding, every non-literal operand of an arithmetic or comparison operator, every call result that is used, every value the output must name a type for); no mixing (T8.11); numeric conversion as the operators `to_float`, `trunc`, `round` (T8.12); the diagnostics `T3101` to `T3104` (T8.13); declared types and the order of `(:type)` forms (T8.14); division by zero and overflow are the language's (T8.15). T8.1, T8.5, T8.6, T5.3, T6.8a and Appendix B were amended to agree. **No schema change:** hints on inner nodes were already valid (T9.7), and a conversion is an `(:op)` with a new operator name |
| The point of 2.1 about T8.6 | T8.6 now says it speaks of representation conversions only; a numeric conversion is an operator inside the expression where the sender's language converts |
| Sink | `ts_print` takes types from hints only. Removed: the type of a `case` subject taken from its literal patterns, the result type of a call to the function being printed, the printing of an untyped binding by repeating its value. Added: `T3101` to `T3104` with the node's place; the conversion operators as helper functions written into the unit (1.2, 1.3: Silica has no builtin); declared types kept across forms and units; lists; `t_actor` as `actor_ref`; `(:fail)` as the failing expression |
| Senders | each has a typing pass of its own and sends hints and conversions by its language's rules (their READMEs) |
| Guide | `HOWTO_language_creators.md`, section "You decide the types" |

What the table of T8.9 still lets the transpiler read off without a hint, and why it is not inference: a literal's
kind, a variable's type from its binding, the result of an operator from the operator table (a comparison is
`boolean`; an arithmetic operator has the type of its operands, which must be equal), a tuple or record from its
elements, a field from its record's type, and a body from the function's result. Each is fixed by the node or by a
type the sender stated. If even these are to need a hint, T8.9 is the one table to shorten.

Consequences measured after the decision are in STATUS.md ("The three applications' examples").

Still open after it:

1. **Names** (section 3). **Function names: done 2026-11-13 (evening) as a variant of S1**, contract T9.11: a
   function whose name is on the reserved list (`reserved_names` in `ts_print`) or is `main` is written with `__`
   appended, in its definition, its calls and its references. `__` and not `_`, because the senders' own rule
   keeps `__` for its escapes (`total__1`), so a sender's name can end in `_` and not in a bare `__`. Not checked:
   a session that sends both `move` and `move__`. Still open: reserved words and builtins as **field** and module
   names; the `<unit>_<function>` symbol collision of `[r3]`. The senders' rule was made injective and safe for
   several arities of one name without a new contract node (their READMEs, and the guide's section 9); the rest
   needs a decision between S1, S2 and S3 of 3.6, or a list of reserved names in the contract.
2. Whether **check mode** should run the printer's type checks, so that a sender sees `T31xx` without a transpile
   session.
3. Conversions the table of T8.12 does not have: floor, ceiling, integer widths, `float32`.
4. `number()` and other types that are an integer or a float only at run time: they need the untyped
   representation (`bees_term`), which is not built; until then they are the sender's gaps.
