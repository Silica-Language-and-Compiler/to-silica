defmodule E2s.Codex.Error do
  @moduledoc "The source could not be turned into a session: it does not parse, or it defines no module."
  defexception [:message]
end

defmodule E2s.Codex do
  @moduledoc """
  The inbound codex of elixir-to-silica-poc: Elixir source -> the frames of the to-silica TCP transport contract,
  version 1 (`../contract/tcp-transport-v1.md`; rule ids such as T9.2 and node ids such as H21 are cited).

  Parsing is Elixir's own: `Code.string_to_quoted/2` gives the AST (the parser is the gate: nothing is sent unless
  it succeeded). This module only maps that AST to the contract's forms and node tables. Nothing is expanded or
  evaluated, so the mapping is syntactic.

  Scope of the proof of concept (everything else is sent as a gap, T9.10, so a session always completes):

    * in: integers, floats, strings, atoms, booleans, tuples, structs (as records), variables, `=`, `def`/`defp`
      with clauses, patterns and guards, local and remote calls, `|>`, operators, `case`, `cond`, `if`, `fn`,
      `&name/arity`, `f.(x)`, `self()`, `spawn/1,3`, `spawn_link/1,3`, `send/2`, `receive` (with `after`),
      `Process.link/1`, `Process.exit/2`, `exit/1`, `@spec`, `defstruct`; alias patterns (`p = v` in a pattern),
      the pin operator, rebinding, and truthiness in `if`, `cond`, `&&`, `||`, `!`.
    * also in, by lowerings that run before the codex: receives anywhere and trapped exits (`E2s.Split`), a
      `Supervisor` with a static child list (`E2s.Sup`: static children, contract T9.14b), a `fn` that captures
      nothing where an `@spec` types it (`E2s.Lift`); `send(:name, message)` is H39.
    * out: lists, keyword lists, maps, bit syntax and interpolation, comprehensions, `with`, `try`/`raise`, macros,
      `use`/`import`/`require`, sigils, the other OTP behaviours, `Process.register/2` outside a supervisor
      child's start function, and everything that reaches another node.

  Where to extend: one group of `tr/3` clauses per node family, in the contract's order (literals and data; names,
  matching and control; processes; operators; calls). A new construct is a new `tr/3` clause that calls `emit/4`;
  a construct left out calls `gap/3`. Names are spelled only by `E2s.Names`; variable names go through
  `E2s.Codex.Scope`; the truthiness rewrite is `E2s.Codex.Truthiness`.

  ## The typing pass (contract 8.6: the sender decides every type)

  The transpiler infers no type and converts no number, so this codex states both. Typing happens while the nodes
  are written, in one pass, and has three parts:

    * **what a node's type is.** Every `tr/3` clause that knows the type of the node it wrote records it with
      `typed/4` (the builder's `ty`: node index -> `{type, strength}`; types are `E2s.Codex.Types`). Parameters
      get theirs from `@spec`, variables from what they are bound to (`assign/4` takes a pattern apart against the
      type of the value; the builder's `vt`: sent variable name -> type), calls to functions of the module from
      the callee's `@spec` (`env.sigs`), operators and Kernel functions from Elixir's rules (`ruled/5`,
      `kernel_type/2`), a few standard-library calls from `stdlib/4`.
    * **where a type must be stated** (T8.10). `state/2` writes the hint of a node whose type is known and is not
      fixed by the node itself (T8.9); `need/4` is called wherever the contract requires a type: it states the
      type, or, when the codex has none, sends a gap whose note says which type is missing and why. A whole
      construct (a `=`, a `case`, a `receive`, a `fn`, a function) is a gap when one of the variables its patterns
      bind has no type.
    * **numeric conversions and edges** (T8.11, T8.12, T8.15), in `ruled/5`: `to_float/3` around an integer next
      to a float, `division/4` (both operands to float, and the guard that fails with `badarith` on a zero
      divisor), `conversion/4` (`trunc`, `round`), `static/4` (`===` between types that share no value).

  With `strict: false` (used only by the tests of the construct mappings) a missing type is not a gap: the node
  is sent as it is, without a hint. The command line always types.
  """

  alias E2s.Codex.{Error, Scope, Truthiness, Types}
  alias E2s.Names

  @prefix "ex_"
  @poc "outside the proof of concept"
  @inter_node "inter-node communication is outside the proof of concept"
  @pin_value "send the match as a statement of its own: a `=` has no guard to carry the pin's test"
  @otp "OTP behaviours are outside the proof of concept (contract 9.2)"
  @registered "a name is given only to a supervisor's static child, in its start function (contract T9.14b; the transpiler writes no other (:register)); a send to a name is sent (H39)"

  @distribution_elixir ~w(Node)
  @distribution_erlang ~w(rpc erpc global global_group pg pg2 net_kernel net_adm slave peer dist_util)
  @otp_elixir ~w(GenServer Supervisor DynamicSupervisor PartitionSupervisor Agent Task Registry GenEvent Application)
  @otp_erlang ~w(gen_server gen_statem gen_event gen_fsm supervisor supervisor_bridge application proc_lib sys)

  # Elixir spelling -> Appendix B spelling.
  @binary_ops %{
    +: "+", -: "-", *: "*", /: "/",
    ==: "==", !=: "/=", <: "<", <=: "=<", >: ">", >=: ">=", ===: "=:=", !==: "=/=",
    and: "andalso", or: "orelse", <>: "<>"
  }
  @bitwise %{{:band, 2} => "band", {:bor, 2} => "bor", {:bxor, 2} => "bxor", {:bnot, 1} => "bnot",
             {:bsl, 2} => "bsl", {:bsr, 2} => "bsr"}

  # Constructs that look like local calls and are outside the subset.
  @named_gaps %{
    for: "comprehension (for)", with: "with", try: "try", raise: "raise", reraise: "raise", throw: "throw",
    quote: "quote", unquote: "unquote", unless: "unless", super: "super", import: "import", alias: "alias",
    require: "require", use: "use", binding: "binding", to_string: "to_string (protocol dispatch)"
  }

  @module_gaps [:use, :import, :require, :defmacro, :defmacrop, :defguard, :defguardp, :defdelegate, :defimpl,
                :defprotocol, :defexception, :defoverridable]

  # A literal as the literal_encoder below wraps it: {:__block__, meta, [literal]}. A real block holds AST nodes,
  # which are 3-tuples, so the two cannot be confused.
  defguardp is_lit(x)
            when is_number(x) or is_atom(x) or is_binary(x) or is_list(x) or (is_tuple(x) and tuple_size(x) == 2)

  @doc """
  The frames of a whole session for these source files: hello, then per module unit_begin, forms, unit_end, then
  end. `mode` is `:check` or `:transpile` (contract 6.5).

  `opts`: `strict: false` sends a node whose type the codex does not know as it is, instead of as a gap (see the
  module documentation; for the mapping tests only). `session: id` makes the hello a resume of that session (T6.5).
  """
  def frames(files, mode, opts \\ []) when mode in [:check, :transpile] do
    {units, {seq, count}} =
      Enum.map_reduce(files, {0, 0}, fn file, {seq, count} ->
        {frames, n} = units(File.read!(file), file, seq, opts)
        {frames, {seq + length(frames), count + n}}
      end)

    [hello(mode, Keyword.get(opts, :session, ""))] ++ Enum.concat(units) ++ [{:end, %{seq: seq, units: count}}]
  end

  @doc "The frames of the units of one file (M2, M3..., M4 for each module), numbered from `seq0` (T5.1)."
  def file(path, seq0 \\ 0, opts \\ []), do: elem(units(File.read!(path), path, seq0, opts), 0)

  @doc "As `file/3`, for source held in a string; `name` labels the source."
  def string(source, name \\ "nofile", seq0 \\ 0, opts \\ []), do: elem(units(source, name, seq0, opts), 0)

  @doc """
  The gaps in a list of frames, in order: `{unit, form name, line, construct, note}` for every `(:gap)` form and
  every `(:gap_node)`. What `mix e2s --gaps` prints.
  """
  def gaps(frames) do
    Enum.flat_map(frames, fn
      {:form, %{unit_name: unit, body: {:gap, %{name: name, place: %{line: line}, construct: construct, note: note}}}} ->
        [{unit, name, line, construct, note}]

      {:form, %{unit_name: unit, body: {:function, %{head: head, code: %{nodes: nodes, locations: locations}}}}} ->
        for {:gap_node, at, construct, note} <- nodes do
          {unit, "#{head.name}/#{head.arity}", elem(Enum.at(locations, at), 0), construct, note}
        end

      _ ->
        []
    end)
  end

  @doc """
  The modules of a file as `E2s.Split` leaves them (every receive in tail position), as quoted `defmodule`
  forms Elixir's compiler takes. `Macro.to_string/1` of one is the split module as source, which is what
  `mix e2s --split` prints; compiled, it behaves as the module does.
  """
  def split(path) do
    for {:defmodule, meta, [{:__aliases__, _, parts} = name, body]} <- block_forms(parse!(File.read!(path), path)) do
      {forms, _gen} = E2s.Split.forms(body_forms(body), Enum.map_join(parts, ".", &Atom.to_string/1))
      E2s.Split.to_elixir({:defmodule, meta, [name, [do: {:__block__, [], forms}]]})
    end
  end

  @doc "M1. A :bees session: one choice for each BEES requirement (T7.1), the recommended hint policy (T8.4)."
  def hello(mode, session \\ "") do
    {:hello,
     %{
       contract: 1,
       session: session,
       sender: %{language: "elixir", prefix: @prefix, codex: "elixir-to-silica-poc", codex_version: "0.1.0"},
       options: %{
         profile: :bees,
         choices: choices(),
         hints: %{proven: :trust, declared: :check, inferred: :check},
         run: %{mode: mode, max_frame: 1_048_576}
       }
     }}
  end

  def choices do
    [
      choice(:a3_2, :default, [{"release", "release_on_return"}]),
      choice(:a3_3, :phase_field, []),
      choice(:a3_4, :back_edge, []),
      choice(:a4_2, :single_pool, [{"pool_size", "1024"}]),
      choice(:a4_3, :uniform_shape, []),
      choice(:a4_4, :chosen, [{"restart", "transient"}, {"strategy", "one_for_one"}]),
      choice(:a5_1, :result_values, []),
      choice(:a5_4, :accept_sender_death, []),
      choice(:a5_5, :supervisor_request, []),
      choice(:a6_8, :lookup_tables, []),
      choice(:a7_1, :module_table, [])
    ]
  end

  defp choice(requirement, choice, params), do: %{requirement: requirement, choice: choice, params: params, note: ""}

  # ------------------------------------------------------------------ parsing and units

  defp units(source, path, seq0, opts) do
    strict = Keyword.get(opts, :strict, true)
    file = Path.basename(path)
    tops = block_forms(parse!(source, path))
    {modules, stray} = Enum.split_with(tops, &match?({:defmodule, _, [{:__aliases__, _, _}, _]}, &1))
    if modules == [], do: raise(Error, message: "#{path} defines no module")

    stray_gaps =
      for {_, meta, _} = form <- stray, not match?({:__block__, _, [x]} when is_lit(x), form) do
        form_gap("top level", meta, file, "expression outside a module", @poc)
      end

    {frames, _} =
      modules
      |> Enum.with_index()
      |> Enum.map_reduce(seq0, fn {module, i}, seq ->
        frames = unit(module, file, seq, if(i == 0, do: stray_gaps, else: []), strict)
        {frames, seq + length(frames)}
      end)

    {Enum.concat(frames), length(modules)}
  end

  defp parse!(source, path) do
    # Literals carry no position in Elixir's AST; the encoder keeps each one's line and column (T9.3).
    encoder = fn literal, meta -> {:ok, {:__block__, meta, [literal]}} end

    case Code.string_to_quoted(source, columns: true, file: path, literal_encoder: encoder) do
      {:ok, ast} ->
        ast

      {:error, {meta, message, token}} ->
        text = if is_binary(message), do: message, else: message |> Tuple.to_list() |> Enum.join()
        raise Error, message: "#{path}:#{Keyword.get(meta, :line, 0)}: does not parse: #{text}#{token}"
    end
  end

  # One module = one unit (contract 2).
  defp unit({:defmodule, _, [name_ast, body]}, file, seq0, extra, strict) do
    {:__aliases__, _, parts} = name_ast
    name = Enum.map_join(parts, ".", &Atom.to_string/1)
    # Elixir's process semantics are lowered first (E2s.Split, contract T9.13a): the codex types and sends the
    # split functions like any other; `gen` says which functions the split made.
    # Before that: Elixir's Supervisor is read (E2s.Sup: a supervisor start becomes its static children, contract
    # T9.14b), and a fn that captures nothing, written where an @spec declares a function type, becomes a
    # function of the module (E2s.Lift: the transpiler prints no closure).
    {lifted_forms, lifted} = E2s.Lift.forms(E2s.Sup.forms(body_forms(body), name))
    {forms, gen} = E2s.Split.forms(lifted_forms, name)
    env = env(name, file, forms, strict, gen, lifted)

    entry =
      case env.defs[{:main, 0}] do
        nil -> []
        clauses -> if Enum.any?(clauses, &(&1.kind == :def)), do: [{:entry, %{function: fname(:main, 0, env), arity: 0}}], else: []
      end

    bodies = types_first(forms(forms, env)) ++ entry ++ extra

    {frames, next} =
      Enum.map_reduce(bodies, seq0 + 1, fn body, seq ->
        {{:form, %{seq: seq, unit_name: name, body: body}}, seq + 1}
      end)

    [{:unit_begin, %{seq: seq0, unit_name: name, silica_unit: Names.silica_unit(@prefix, name), source: file}}] ++
      frames ++ [{:unit_end, %{seq: next, unit_name: name, forms: length(bodies)}}]
  end

  # T8.14: a (:type) form is sent before every form that names it, so all the type forms of a module go first,
  # and a type that names another (a struct with a field of another struct's type) goes after it.
  defp types_first(bodies) do
    {types, rest} = Enum.split_with(bodies, &match?({:type, _}, &1))
    names = MapSet.new(types, fn {:type, %{head: %{name: name}}} -> name end)

    {ordered, _} =
      Enum.reduce(types, {[], MapSet.new()}, fn type, acc -> place_type(type, types, names, acc) end)

    Enum.reverse(ordered) ++ rest
  end

  defp place_type({:type, %{head: %{name: name}, types: table}} = type, all, names, {ordered, placed}) do
    if MapSet.member?(placed, name) do
      {ordered, placed}
    else
      needs = for {:t_named, other, _} <- table, other != name, MapSet.member?(names, other), do: other

      {ordered, placed} =
        Enum.reduce(needs, {ordered, MapSet.put(placed, name)}, fn other, acc ->
          place_type(Enum.find(all, &match?({:type, %{head: %{name: ^other}}}, &1)), all, names, acc)
        end)

      {[type | ordered], placed}
    end
  end

  defp body_forms(body) do
    case kw(body) do
      :error -> []
      kws -> block_forms(Keyword.get(kws, :do, {:__block__, [], []}))
    end
  end

  defp block_forms({:__block__, _, [x]} = literal) when is_lit(x), do: [literal]
  defp block_forms({:__block__, _, forms}), do: forms
  defp block_forms(form), do: [form]

  # What the forms of a module need to know about each other.
  defp env(name, file, forms, strict, gen, lifted) do
    defs =
      Enum.reduce(forms, %{}, fn form, acc ->
        with {kind, _, _} when kind in [:def, :defp] <- form,
             {:ok, key, clause} <- parse_def(form) do
          Map.update(acc, key, [clause], &(&1 ++ [clause]))
        else
          _ -> acc
        end
      end)

    nested = for {:defmodule, _, [{:__aliases__, _, [first | _] = parts}, body]} when is_atom(first) <- forms, do: {parts, body}

    aliases =
      Enum.reduce(forms, Map.new(nested, fn {[first | _], _} -> {first, "#{name}.#{first}"} end), fn form, acc ->
        case simple_alias(form, acc) do
          {:ok, short, full} -> Map.put(acc, short, full)
          :error -> acc
        end
      end)

    structs =
      for({parts, body} <- nested, struct_module?(body_forms(body)), do: name <> "." <> Enum.join(parts, ".")) ++
        if(Enum.any?(forms, &match?({:defstruct, _, [_]}, &1)), do: [name], else: [])

    specs =
      Enum.reduce(forms, %{}, fn
        {:@, _, [{:spec, _, [{:"::", _, [{fun, _, args}, ret]}]}]}, acc when is_atom(fun) ->
          args = if is_list(args), do: args, else: []
          Map.update(acc, {fun, length(args)}, [{args, ret}], &(&1 ++ [{args, ret}]))

        _, acc ->
          acc
      end)

    # The arities each function name is defined at; default arguments define several (N4, arity).
    arities =
      Enum.reduce(forms, Map.new(Map.keys(defs), fn {fun, _} -> {fun, MapSet.new()} end), fn form, acc ->
        Enum.reduce(def_arities(form), acc, fn {fun, arity}, acc -> Map.update(acc, fun, MapSet.new([arity]), &MapSet.put(&1, arity)) end)
      end)

    env = %{file: file, module: name, defs: defs, locals: MapSet.new(Map.keys(defs)), aliases: aliases,
            structs: MapSet.new(structs), specs: specs, strict: strict, gen: gen, lifted: lifted, made: %{},
            several: for({fun, set} <- arities, MapSet.size(set) > 1, into: MapSet.new(), do: fun)}

    # Declared types first: the fields of the file's structs, then every function's signature from its @spec.
    declarations =
      for({parts, body} <- nested, inner = body_forms(body), struct_module?(inner),
          do: {name <> "." <> Enum.join(parts, "."), inner}) ++
        if(Enum.any?(forms, &match?({:defstruct, _, [_]}, &1)), do: [{name, forms}], else: [])

    records = Map.new(declarations, fn {module, inner} -> {Names.type_name(module), record_info(module, inner, env)} end)
    env = Map.put(env, :records, records)
    source = for key <- Map.keys(defs), not is_map_key(gen, key), into: %{}, do: {key, sig(key, env)}
    # Each round types the made functions one call further from a source function, so the rounds needed grow
    # with the number of made functions; the bound only stops a type that would grow for ever.
    env = made_sigs(Map.merge(env, %{source: source, collecting: true}), 10 + 4 * map_size(gen))
    %{env | collecting: false}
  end

  # ------------------------------------------------------------------ made functions (E2s.Split)

  # The signatures of the functions E2s.Split made (continuations, copies: they have no @spec). A made function
  # is called only by the pieces of the function it was cut from, so its parameters have the types of the
  # arguments of those calls, and its result is the @spec result of the source function it continues. The
  # functions are typed (and the nodes thrown away) until the types the calls give no longer change: local/4
  # notes every call of a made function in the builder's `calls`. A parameter one call gives `{:ok, integer()}`
  # and another `{:refused, integer()}` is the union of the two.
  defp made_sigs(env, tries) do
    env = Map.put(env, :sigs, Map.merge(env.source, Map.new(Map.keys(env.gen), &{&1, made_sig(&1, env)})))

    calls =
      if env.gen == %{} or tries == 0 do
        %{}
      else
        Enum.reduce(env.defs, %{}, fn {key, clauses}, acc ->
          {_idxs, b} = function_nodes(clauses, Map.fetch!(env.sigs, key), env)
          Map.merge(acc, b.calls, fn _key, a, b -> merge_all(a, b) end)
        end)
      end

    made = for {key, types} <- calls, Enum.all?(types, &Types.known?/1), into: %{}, do: {key, types}
    if made == %{} or made == env.made, do: env, else: made_sigs(%{env | made: Map.merge(env.made, made)}, tries - 1)
  end

  defp made_sig(key, env) do
    %{result: {root_name, root_arity} = root, what: what} = Map.fetch!(env.gen, key)

    case {Map.get(env.source, root), Map.get(env.made, key)} do
      {{:ok, _, result}, params} when is_list(params) ->
        {:ok, params, result}

      {{:ok, _, _}, nil} ->
        {:none, "is made by this sender (#{what}) and no call of it could be typed (the code before it is a gap, or a variable it is given has no type)"}

      {{:none, why}, _} ->
        {:none, "is made by this sender (#{what}); it continues #{root_name}/#{root_arity}, which #{why}"}

      {nil, _} ->
        {:none, "is made by this sender (#{what}) from #{root_name}/#{root_arity}, which the codex could not read"}
    end
  end

  # The result type of a made function, also while its parameters are still being collected.
  defp made_result(key, env) do
    with %{result: root} <- Map.get(env.gen, key), {:ok, _, result} <- Map.get(env.source, root), do: result, else: (_ -> nil)
  end

  defp merge_all(a, b), do: Enum.map(Enum.zip(a, b), fn {x, y} -> Types.merge(x, y) end)

  # {name, arity} of every function a def or defp defines.
  defp def_arities({kind, _, [head | _]}) when kind in [:def, :defp] do
    case head do
      {:when, _, [call, _]} -> call_arities(call)
      call -> call_arities(call)
    end
  end

  defp def_arities(_form), do: []

  defp call_arities({fun, _, args}) when is_atom(fun) and is_list(args) do
    defaults = Enum.count(args, &match?({:\\, _, _}, &1))
    for arity <- (length(args) - defaults)..length(args), do: {fun, arity}
  end

  defp call_arities({fun, _, context}) when is_atom(fun) and is_atom(context), do: [{fun, 0}]
  defp call_arities(_), do: []

  # What Types.from_spec/2 needs to read a type expression written in `module`.
  defp spec_env(env, module \\ nil) do
    env = if module, do: %{env | module: module}, else: env
    Map.merge(env, %{module_ref: &module_ref(&1, env), type_name: &Names.type_name/1})
  end

  # A struct's fields and their types, from `defstruct` and `@type t :: %__MODULE__{...}`:
  # %{fields: [{sent field name, type}] | nil, untyped: nil | why its type cannot be stated}
  defp record_info(module, forms, env) do
    declaration = Enum.find(forms, &match?({:defstruct, _, [_]}, &1))
    {:defstruct, _, [arg]} = declaration

    case struct_fields(arg) do
      {:ok, fields} ->
        declared = Enum.find_value(forms, %{}, &struct_type/1)

        pairs =
          for field <- fields do
            case declared do
              %{^field => type} -> {name(field), Types.from_spec(type, spec_env(env, module))}
              _ -> {name(field), Types.unknown("no `@type t :: %__MODULE__{...}` gives the field #{field} a type")}
            end
          end

        untyped =
          Enum.find_value(pairs, fn {field, type} ->
            if Types.unknown?(type), do: "the struct #{module} states no type for its field #{field}: #{Types.reason(type)}"
          end)

        %{fields: pairs, untyped: untyped}

      :error ->
        %{fields: nil, untyped: "the fields of the struct #{module} are not literal names"}
    end
  end

  # A function's signature from its @spec: {:ok, parameter types, result type} | {:none, why it has none}.
  defp sig({fun, arity} = key, env) do
    case env.specs[key] do
      nil ->
        {:none, "has no @spec"}

      [{args, ret}] ->
        types = Enum.map(args ++ [ret], &Types.from_spec(&1, spec_env(env)))

        case Enum.find_index(types, &Types.unknown?/1) do
          nil ->
            {:ok, Enum.drop(types, -1), List.last(types)}

          i ->
            part = if i == arity, do: "result", else: "parameter #{i + 1}"
            {:none, "has an @spec that states no type for its #{part}: #{Types.reason(Enum.at(types, i))}"}
        end

      _several ->
        {:none, "has more than one @spec clause for #{fun}/#{arity}"}
    end
  end

  # `alias A.B` and `alias A.B, as: C` only; they are needed to name structs and remote calls.
  defp simple_alias({:alias, _, [{:__aliases__, _, parts}]}, aliases), do: alias_of(parts, List.last(parts), aliases)

  defp simple_alias({:alias, _, [{:__aliases__, _, parts}, opts]}, aliases) do
    case kw(opts) do
      [as: {:__aliases__, _, [short]}] -> alias_of(parts, short, aliases)
      _ -> :error
    end
  end

  defp simple_alias(_, _), do: :error

  defp alias_of([first | rest] = parts, short, aliases) do
    if Enum.all?(parts, &is_atom/1) do
      {:ok, short, Enum.join([Map.get(aliases, first, Atom.to_string(first)) | rest], ".")}
    else
      :error
    end
  end

  # A nested module that only declares a struct: the Elixir spelling of a record declaration.
  defp struct_module?(forms) do
    Enum.count(forms, &match?({:defstruct, _, [_]}, &1)) == 1 and
      Enum.all?(forms, fn
        {:defstruct, _, [_]} -> true
        {:@, _, [{name, _, _}]} -> name in [:type, :typedoc, :moduledoc, :doc, :enforce_keys, :derive]
        {:__block__, _, [x]} when is_lit(x) -> true
        _ -> false
      end)
  end

  # def/defp -> {:ok, {name, arity}, clause} | :bodiless | {:gap, name, construct}
  defp parse_def({kind, meta, [head | rest]}) do
    {call, guard} =
      case head do
        {:when, _, [call, guard]} -> {call, guard}
        call -> {call, nil}
      end

    case call do
      {name, _, args} when is_atom(name) and (is_list(args) or is_atom(args)) ->
        args = if is_list(args), do: args, else: []
        body = if rest == [], do: :bodiless, else: kw(hd(rest))

        cond do
          Enum.any?(args, &match?({:\\, _, _}, &1)) -> {:gap, Atom.to_string(name), "default arguments (\\\\)"}
          body == :bodiless -> :bodiless
          body == :error -> {:gap, Atom.to_string(name), "#{kind} with a computed body"}
          true -> {:ok, {name, length(args)}, %{kind: kind, meta: meta, args: args, guard: guard, body: body}}
        end

      _ ->
        {:gap, Atom.to_string(kind), "#{kind} with a computed name"}
    end
  end

  defp parse_def({kind, _, _}), do: {:gap, Atom.to_string(kind), "#{kind} with a computed name"}

  # ------------------------------------------------------------------ top-level forms (contract 9.3)

  defp forms(forms, env) do
    {bodies, _emitted} = Enum.flat_map_reduce(forms, MapSet.new(), &form(&1, env, forms, &2))
    bodies
  end

  # A function is sent once, with all its clauses, where its first clause stands.
  defp form({kind, meta, _} = form, env, _forms, emitted) when kind in [:def, :defp] do
    case parse_def(form) do
      {:ok, key, _clause} ->
        if MapSet.member?(emitted, key),
          do: {[], emitted},
          else: {[function(key, Map.fetch!(env.defs, key), env)], MapSet.put(emitted, key)}

      :bodiless ->
        {[], emitted}

      {:gap, name, construct} ->
        {[form_gap(name, meta, env.file, construct, @poc)], emitted}
    end
  end

  # A struct declaration is sent as a type declaration: a record type with its fields (contract 8.5).
  defp form({:defstruct, _, [_]} = form, env, _forms, emitted), do: {[struct_form(env.module, form, env)], emitted}

  defp form({:defmodule, meta, [name_ast, body]}, env, _forms, emitted) do
    inner = body_forms(body)

    with {:__aliases__, _, parts} <- name_ast,
         true <- Enum.all?(parts, &is_atom/1),
         true <- struct_module?(inner) do
      name = env.module <> "." <> Enum.join(parts, ".")
      declaration = Enum.find(inner, &match?({:defstruct, _, [_]}, &1))
      {[struct_form(name, declaration, env)], emitted}
    else
      _ -> {[form_gap("defmodule", meta, env.file, "nested module", @poc)], emitted}
    end
  end

  defp form({:@, meta, [{kind, _, _}]} = form, env, _forms, emitted)
       when kind in [:type, :typep, :opaque, :callback, :macrocallback, :behaviour] do
    # The @type t of a struct is used for the struct's field types; no other type declaration is translated.
    if kind == :type and MapSet.member?(env.structs, env.module) and struct_type(form) != nil do
      {[], emitted}
    else
      {[form_gap(Atom.to_string(kind), meta, env.file, "@#{kind}", @poc)], emitted}
    end
  end

  # @spec (used by its function), @moduledoc, @doc, @impl and other attributes carry no code.
  defp form({:@, _, _}, _env, _forms, emitted), do: {[], emitted}

  defp form({:alias, meta, _} = form, env, _forms, emitted) do
    case simple_alias(form, env.aliases) do
      {:ok, _, _} -> {[], emitted}
      :error -> {[form_gap("alias", meta, env.file, "alias of several modules", @poc)], emitted}
    end
  end

  defp form({kind, meta, _}, env, _forms, emitted) when kind in @module_gaps,
    do: {[form_gap(Atom.to_string(kind), meta, env.file, Atom.to_string(kind), @poc)], emitted}

  defp form({:__block__, _, [x]}, _env, _forms, emitted) when is_lit(x), do: {[], emitted}

  defp form({_, meta, _}, env, _forms, emitted) when is_list(meta),
    do: {[form_gap("module body", meta, env.file, "expression in a module body", @poc)], emitted}

  defp form(_other, env, _forms, emitted),
    do: {[form_gap("module body", [], env.file, "expression in a module body", @poc)], emitted}

  defp form_gap(name, meta, file, construct, note),
    do: {:gap, %{name: name, place: %{file: file, line: line(meta)}, construct: construct, note: note}}

  # T8.10 (a): a function form needs its signature, which only an @spec gives. Without one (or with one that
  # states no type for a part) the whole function is a gap; so is a function whose clause patterns bind a
  # variable that the signature gives no type.
  defp function({name, arity} = key, clauses, env) do
    sig = Map.fetch!(env.sigs, key)
    sent = fname(name, arity, env)
    meta = hd(clauses).meta

    case sig do
      {:none, why} when env.strict ->
        form_gap(sent, meta, env.file, "missing type: function signature",
          "#{name}/#{arity} #{why}, so its parameter and result types cannot be stated (T8.10 a)")

      _ ->
        {clause_idxs, b} = function_nodes(clauses, sig, env)
        # A made function's types are the sender's inference from the calls of it; a source function's are declared.
        strength = if is_map_key(env.gen, key), do: :inferred, else: :declared

        if env.strict and b.untyped != [] do
          form_gap(sent, meta, env.file, "missing type: parameter binding", "#{name}/#{arity}: #{problems_text(b.untyped)} (T8.10 b)")
        else
          function_form(sent, arity, clauses, sig, strength, compact(b, clause_idxs), env)
        end
    end
  end

  # The nodes of a function's clauses, typed against `sig`: {clause indices, builder}.
  defp function_nodes(clauses, sig, env) do
    builder = %{
      nodes: %{}, n: 0, locs: %{}, env: env, scope: Scope.new(variable_names(clauses)), binding: nil, pins: [],
      ty: %{}, vt: %{}, gt: %{}, hints: %{}, untyped: [], expect: nil, strict: env.strict, sig: sig, calls: %{},
      overrides: []
    }

    Enum.map_reduce(clauses, builder, &def_clause/2)
  end

  defp function_form(sent, arity, clauses, sig, strength, {nodes, locations, roots, hints, overrides}, env) do
    {signature, table} =
      case sig do
        {:ok, params, result} ->
          {i, table} = Types.intern({:t_fun, params, result}, Types.new_table())
          {[%{node: -1, type: i, strength: strength, policy: :default}], table}

        {:none, _} ->
          {[], Types.new_table()}
      end

    {stated, table} =
      Enum.map_reduce(hints, table, fn {node, {type, strength}}, table ->
        {i, table} = Types.intern(type, table)
        {%{node: node, type: i, strength: strength, policy: :default}, table}
      end)

    {:function,
     %{
       head: %{name: sent, arity: arity, exported: Enum.any?(clauses, &(&1.kind == :def)), file: env.file},
       code: %{locations: locations, nodes: nodes, clauses: roots},
       types: Types.entries(table),
       notes: %{hints: signature ++ stated, overrides: overrides}
     }}
  end

  # Every variable name the function's source uses, in its sent spelling: a generated name must avoid them.
  defp variable_names(clauses) do
    {_, names} =
      Macro.prewalk(Enum.map(clauses, &{&1.args, &1.guard, &1.body}), [], fn
        {name, _, context} = ast, acc when is_atom(name) and is_atom(context) -> {ast, [name(name) | acc]}
        ast, acc -> {ast, acc}
      end)

    names
  end

  # N4: the sent spelling of a variable or field name.
  defp name(atom) when is_atom(atom), do: Names.ident(Atom.to_string(atom))

  # N4: the sent spelling of a function of this module; `name__arity` when the module defines the name at more
  # than one arity.
  # N6: a function E2s.Split made is sent as <the sent name of the function it was made from><suffix>: main__k1
  # (the first continuation of main), withdraw_from__c1 (a copy of withdraw_from), account__l (the linked copy
  # of account); a fn E2s.Lift made a function is <the function it was written in>__f<n>: add_ten__f1.
  # Names.ident/1 never writes __k, __c, __l or __f, so these names are no source function's.
  defp fname(atom, arity, env) do
    case {env.gen, env.lifted} do
      {%{{^atom, ^arity} => %{base: {base, base_arity}, suffix: suffix}}, _} -> fname(base, base_arity, env) <> suffix
      {_, %{{^atom, ^arity} => %{base: {base, base_arity}, suffix: suffix}}} -> fname(base, base_arity, env) <> suffix
      _ -> Names.function(Atom.to_string(atom), arity, MapSet.member?(env.several, atom))
    end
  end

  # Each clause of a function starts with no variable bound. Its patterns have the signature's parameter types.
  defp def_clause(%{meta: meta, args: args, guard: guard, body: body}, b) do
    b = %{b | scope: Scope.reset(b.scope), vt: %{}}

    types =
      case b.sig do
        {:ok, params, _} -> params
        {:none, why} -> List.duplicate(Types.unknown("the function " <> why), length(args))
      end

    case body do
      [do: expr] -> clause(meta, args, guard, expr, b, types: types, strength: :declared)
      _ -> clause(meta, args, guard, {:gap, "rescue/catch/after in a function body"}, b, types: types, strength: :declared)
    end
  end

  # T8.14 and T8.10: a struct whose fields all have a type is a (:type) form; one with a field that has none
  # cannot be declared, so it is a gap (and every use of it is a gap, see record/5).
  defp struct_form(name, {:defstruct, meta, [_]}, env) do
    type_name = Names.type_name(name)

    case Map.fetch!(env.records, type_name) do
      %{fields: nil} ->
        form_gap(name, meta, env.file, "defstruct", "its fields are not literal names")

      %{untyped: why} when why != nil and env.strict ->
        form_gap(name, meta, env.file, "missing type: struct field", why <> " (T8.14)")

      %{fields: fields} ->
        {pairs, table} =
          Enum.map_reduce(fields, Types.new_table(), fn {field, type}, table ->
            {i, table} = Types.intern(if(Types.known?(type), do: type, else: {:t_basic, :dynamic}), table)
            {{field, i}, table}
          end)

        types = Types.entries(table) ++ [{:t_record, pairs}]

        {:type,
         %{head: %{name: type_name, params: [], exported: true, file: env.file}, at_line: line(meta), types: types,
           root: length(types) - 1}}
    end
  end

  # defstruct [:a, :b] | defstruct a: 0, b: 0 | a mix of both
  defp struct_fields(arg) do
    with fields when is_list(fields) <- unwrap(arg),
         names = Enum.map(fields, &field_name/1),
         true <- Enum.all?(names, &is_atom/1) and nil not in names do
      {:ok, names}
    else
      _ -> :error
    end
  end

  defp field_name({key, _default}), do: field_name(key)
  defp field_name({:__block__, _, [name]}) when is_atom(name), do: name
  defp field_name(_), do: nil

  # @type t :: %__MODULE__{field: type, ...} -> %{field => type} | nil
  defp struct_type({:@, _, [{:type, _, [{:"::", _, [{:t, _, args}, {:%, _, [_, {:%{}, _, fields}]}]}]}]})
       when args in [nil, []] do
    case kw(fields) do
      :error -> nil
      kws -> Map.new(kws)
    end
  end

  defp struct_type(_), do: nil

  # ------------------------------------------------------------------ node tables (contract 9.1)

  # Appends one node. Every node gets its own location entry, so a node's `at` equals its index (T9.3).
  defp emit(tag, meta, fields, %{nodes: nodes, n: n, locs: locs} = b) do
    loc = {line(meta), Keyword.get(meta, :column, 0)}
    {n, %{b | nodes: Map.put(nodes, n, List.to_tuple([tag, n | fields])), n: n + 1, locs: Map.put(locs, n, loc)}}
  end

  defp line(meta), do: Keyword.get(meta, :line, 0)

  defp node(b, i), do: Map.fetch!(b.nodes, i)

  # The place of an already written node, as a meta, for a node that is written because of it.
  defp meta_of(b, i) do
    {line, column} = Map.fetch!(b.locs, i)
    [line: line, column: column]
  end

  # H40: a construct this codex does not translate (T9.10). A gap has no type and needs none.
  defp gap(meta, construct, b), do: gap(meta, construct, @poc, b)

  defp gap(meta, construct, note, b) do
    {i, b} = emit(:gap_node, meta, [construct, note], b)
    {i, typed(b, i, :never, :inferred)}
  end

  # Which fields of each node kind this codex writes are child indices: :i one index (-1 for none), :is a list
  # of them, :pairs a list of {name, index}; :v is a value.
  @fields %{
    int: [:v], float: [:v], text: [:v], bytes: [:v], symbol: [:v], boolean: [:v], tuple: [:is],
    record: [:v, :pairs, :i], field: [:i, :v], var: [:v], wild: [], match: [:i, :i], block: [:is],
    case: [:i, :is], clause: [:is, :i, :i], cond: [:is], op: [:v, :is], call: [:v, :v, :is], apply: [:i, :is],
    apply_mfa: [:i, :i, :is], fun_ref: [:v, :v, :v], lambda: [:is], self: [], spawn: [:i, :is, :v],
    send: [:i, :i], receive: [:is, :i, :i], link: [:i], exit_signal: [:i, :i], fail: [:i], gap_node: [:v, :v],
    sl_call: [:v, :v, :is], register: [:v, :i], send_named: [:v, :i]
  }

  defp children(node) do
    [tag, _at | fields] = Tuple.to_list(node)

    fields
    |> Enum.zip(Map.fetch!(@fields, tag))
    |> Enum.flat_map(fn
      {i, :i} -> if i < 0, do: [], else: [i]
      {is, :is} -> is
      {pairs, :pairs} -> Enum.map(pairs, &elem(&1, 1))
      {_, :v} -> []
    end)
  end

  defp renumber(node, new) do
    [tag, at | fields] = Tuple.to_list(node)

    fields =
      fields
      |> Enum.zip(Map.fetch!(@fields, tag))
      |> Enum.map(fn
        {i, :i} -> if i < 0, do: i, else: Map.fetch!(new, i)
        {is, :is} -> Enum.map(is, &Map.fetch!(new, &1))
        {pairs, :pairs} -> Enum.map(pairs, fn {name, i} -> {name, Map.fetch!(new, i)} end)
        {value, :v} -> value
      end)

    List.to_tuple([tag, Map.fetch!(new, at) | fields])
  end

  # The typing pass writes a node and may then send something else in its place (a gap, a constant). Only the
  # nodes that the function's clauses reach are sent; they keep their order, so children stay before parents.
  defp compact(b, roots) do
    kept = roots |> reach(b.nodes, MapSet.new()) |> Enum.sort()
    new = Map.new(Enum.with_index(kept))

    {Enum.map(kept, &renumber(Map.fetch!(b.nodes, &1), new)), Enum.map(kept, &Map.fetch!(b.locs, &1)),
     Enum.map(roots, &Map.fetch!(new, &1)),
     for({node, hint} <- Enum.sort(b.hints), is_map_key(new, node), do: {Map.fetch!(new, node), hint}),
     for(%{node: node} = override <- Enum.reverse(b.overrides), is_map_key(new, node), do: %{override | node: Map.fetch!(new, node)})}
  end

  defp reach(indices, nodes, seen) do
    Enum.reduce(indices, seen, fn i, seen ->
      if MapSet.member?(seen, i), do: seen, else: reach(children(Map.fetch!(nodes, i)), nodes, MapSet.put(seen, i))
    end)
  end

  # ------------------------------------------------------------------ the typing pass: stated types (T8.9, T8.10)

  # The type of a written node: a type, {:unknown, reason} or :never (E2s.Codex.Types).
  defp t(b, i) do
    case b.ty do
      %{^i => {type, _}} -> type
      _ -> Types.unknown("the codex has no typing rule for this (:#{elem(node(b, i), 0)})")
    end
  end

  defp strength(b, i) do
    case b.ty do
      %{^i => {_, strength}} -> strength
      _ -> :inferred
    end
  end

  defp typed(b, i, type, strength), do: %{b | ty: Map.put(b.ty, i, {type, strength})}

  # Node kinds whose type the node itself fixes (T8.9): a hint adds nothing. (:fail) and gaps have no type.
  @fixed [:int, :float, :text, :bytes, :boolean, :symbol, :var, :op, :fail, :gap_node, :wild, :clause, :sl_call]

  # States the type of node `i` by a hint, when the codex knows it and the node does not fix it itself.
  defp state(b, i) do
    case b.ty do
      %{^i => {type, strength}} ->
        if Types.known?(type) and elem(node(b, i), 0) not in @fixed, do: hint(b, i, type, strength), else: b

      _ ->
        b
    end
  end

  # A node has at most one hint (T8.5).
  defp hint(b, i, type, strength), do: %{b | hints: Map.put_new(b.hints, i, {type, strength})}

  # T8.10: node `i` stands where a type must be stated. Its type is stated; when the codex has none, a gap is
  # sent in its place, whose note says which type is missing and why. `what` names the place.
  defp need(i, what, b) do
    case t(b, i) do
      :never -> {i, b}
      {:unknown, why} -> if b.strict, do: missing(meta_of(b, i), what, why, b), else: {i, b}
      _ -> {i, state(b, i)}
    end
  end

  # A gap for a type the contract requires and the codex cannot state (the sender's own T3101).
  defp missing(meta, what, why, b), do: gap(meta, "missing type: " <> what, why, b)

  # A gap for typing that Elixir allows and one stated type per operand does not (the sender's own T3102).
  defp unruly(meta, what, why, b), do: gap(meta, "type rule: " <> what, why, b)

  # What a construct's patterns left without a type, as the text of a note.
  defp problems_text(problems) do
    problems |> Enum.reverse() |> Enum.uniq() |> Enum.take(3) |> Enum.map_join("; ", fn {what, why} -> "#{what} has no stated type: #{why}" end)
  end

  # Collects the problems of the clauses written by `fun` apart from those of the construct around them.
  defp collecting(b, fun) do
    outer = b.untyped
    {result, b} = fun.(%{b | untyped: []})
    {result, b.untyped, %{b | untyped: outer}}
  end

  # The type a written pattern has by itself: a literal's, a struct's, a variable's once it has one.
  defp intrinsic(i, b) do
    case node(b, i) do
      {:int, _, _} -> Types.int()
      {:float, _, _} -> Types.float()
      {:text, _, _} -> Types.text()
      {:boolean, _, _} -> Types.boolean()
      {:symbol, _, name} -> Types.symbols([name])
      {:var, _, name} -> variable_type(b, name) |> elem(0)
      {:wild, _} -> Types.unknown("`_` takes a value of any type")
      {:tuple, _, elems} -> tuple_type(elems, Enum.map(elems, &intrinsic(&1, b)), b)
      {:record, _, name, _, _} -> record_type(name, b.env)
      {:match, _, left, right} -> Enum.find([intrinsic(left, b)], intrinsic(right, b), &Types.known?/1)
      _ -> Types.unknown("a part of the pattern was sent as a gap")
    end
  end

  defp variable_type(b, sent),
    do: Map.get(b.vt, sent, {Types.unknown("the variable #{sent} is not bound in this function clause"), :inferred})

  # A tuple whose first element is a literal atom is a tagged tuple, as in a @spec.
  defp tuple_type(elems, types, b) do
    tag =
      case elems do
        [first | _] ->
          case node(b, first) do
            {:symbol, _, name} -> name
            _ -> nil
          end

        [] ->
          nil
      end

    Types.tuple(tag, types)
  end

  defp record_type(type_name, env) do
    case env.records do
      %{^type_name => %{untyped: nil}} -> Types.named(type_name)
      %{^type_name => %{untyped: why}} -> Types.unknown(why)
      _ -> Types.unknown("#{type_name} is not a struct declared in this file")
    end
  end

  defp field_type(type_name, field, env) do
    with %{^type_name => %{fields: fields}} when is_list(fields) <- env.records,
         {_, type} <- List.keyfind(fields, field, 0) do
      type
    else
      _ -> Types.unknown("the struct #{type_name} states no type for a field #{field}")
    end
  end

  # T8.10 (b): gives the variables a written pattern binds their types, by taking the pattern apart against the
  # type of what it is matched with, and states each on its (:var) node. A variable the type does not reach
  # takes the type its clause's guard tests (`when is_integer(n)`), if any; otherwise it has none.
  defp assign(i, type, strength, b) do
    case node(b, i) do
      {:var, _, sent} ->
        {had, s} = Map.get(b.vt, sent, {type, strength})

        cond do
          Types.known?(had) -> bind_type(b, i, sent, had, s)
          Types.known?(type) -> bind_type(b, i, sent, type, strength)
          is_map_key(b.gt, sent) -> bind_type(b, i, sent, Map.fetch!(b.gt, sent), :inferred)
          true -> %{b | vt: Map.put(b.vt, sent, {Types.unknown(Types.reason(type)), strength})}
        end

      {:tuple, _, elems} ->
        elems |> Enum.zip(element_types(type, elems, b)) |> Enum.reduce(b, fn {e, type}, b -> assign(e, type, strength, b) end)

      {:record, _, name, fields, _} ->
        Enum.reduce(fields, b, fn {field, e}, b -> assign(e, field_type(name, field, b.env), :declared, b) end)

      {:match, _, left, right} ->
        type = Enum.find([type, intrinsic(left, b)], intrinsic(right, b), &Types.known?/1)
        b = assign(left, type, strength, b)
        assign(right, type, strength, b)

      _ ->
        b
    end
  end

  defp bind_type(b, i, sent, type, strength),
    do: hint(typed(%{b | vt: Map.put(b.vt, sent, {type, strength})}, i, type, strength), i, type, strength)

  # The types of a tuple pattern's elements, from the type of the value.
  defp element_types(type, elems, b) do
    n = length(elems)

    case type do
      {:t_tuple, types} when length(types) == n ->
        types

      {:t_tagged, tag, types} when length(types) == n - 1 ->
        [Types.symbols([tag]) | types]

      {:t_union, alts} ->
        tag = with [first | _] <- elems, {:symbol, _, name} <- node(b, first), do: name, else: (_ -> nil)

        fitting =
          Enum.filter(alts, fn
            {:t_tuple, types} -> length(types) == n
            {:t_tagged, alt_tag, types} -> length(types) == n - 1 and (tag == nil or tag == alt_tag)
            _ -> false
          end)

        case Enum.uniq(Enum.map(fitting, &element_types(&1, elems, b))) do
          [one] -> one
          [] -> List.duplicate(Types.unknown("no alternative of #{Types.show(type)} is a tuple of #{n} elements with this tag"), n)
          _ -> List.duplicate(Types.unknown("more than one alternative of #{Types.show(type)} fits the pattern"), n)
        end

      {:unknown, _} ->
        List.duplicate(type, n)

      :never ->
        List.duplicate(Types.unknown(Types.reason(:never)), n)

      other ->
        List.duplicate(Types.unknown("a tuple pattern of #{n} elements is matched with #{Types.show(other)}"), n)
    end
  end

  # The variables of a written pattern.
  defp pattern_variables(i, b) do
    case node(b, i) do
      {:var, _, sent} -> [sent]
      node -> Enum.flat_map(children(node), &pattern_variables(&1, b))
    end
  end

  # After assign/4: the variables of the patterns that still have no type. With `whole: true` (a receive clause,
  # whose message must have a type, T8.10 e) also a pattern that has none itself.
  defp untyped(patterns, whole, b) do
    variables =
      for p <- patterns, sent <- pattern_variables(p, b), {type, _} = variable_type(b, sent), not Types.known?(type) do
        {"the variable #{sent}", Types.reason(type)}
      end

    if variables == [] and whole do
      for p <- patterns, type = intrinsic(p, b), not Types.known?(type), do: {"the message pattern", Types.reason(type)}
    else
      variables
    end
  end

  # The types a clause's guard gives the variables its patterns bind: `when is_integer(n) and is_pid(from)`.
  @guard_types %{is_integer: Types.int(), is_float: Types.float(), is_binary: Types.text(), is_boolean: Types.boolean(),
                 is_atom: Types.atom(), is_pid: Types.pid()}

  defp guard_types(guard, bound) do
    for {test, _, [{variable, _, context}]} <- conjuncts(guard), is_atom(variable), is_atom(context),
        is_map_key(@guard_types, test), is_map_key(bound, variable), into: %{} do
      {Map.fetch!(bound, variable), Map.fetch!(@guard_types, test)}
    end
  end

  defp conjuncts(nil), do: []
  defp conjuncts({:and, _, [left, right]}), do: conjuncts(left) ++ conjuncts(right)
  defp conjuncts({:__block__, _, [{_, _, _} = one]}), do: conjuncts(one)
  defp conjuncts(other), do: [other]

  # What E2s.Codex.Truthiness asks of the typing pass: is this expression known to be a boolean by its type?
  defp truth(b), do: %{locals: b.env.locals, known: &known_boolean(&1, b)}

  defp known_boolean({name, _, context}, b) when is_atom(name) and is_atom(context) do
    case Scope.lookup(b.scope, name) do
      nil -> false
      sent -> elem(variable_type(b, sent), 0) == Types.boolean()
    end
  end

  defp known_boolean({name, _, args}, b) when is_atom(name) and is_list(args),
    do: match?({:ok, _, {:t_basic, :boolean}}, Map.get(b.env.sigs, {name, length(args)}))

  defp known_boolean(_other, _b), do: false

  # ------------------------------------------------------------------ clauses, guards, matches

  # H29. The patterns, the guard and the body come before the clause (T9.2). What the clause binds is visible in
  # its guard and body and ends with it (see E2s.Codex.Scope); `keep: true` is for `if`, whose condition is not a
  # scope of its own. `types` are the types of what the patterns are matched with, `strength` where those come
  # from; `whole: true` asks that each pattern have a type as a whole. The clause node carries its body's type.
  defp clause(meta, patterns, guard, body, b, opts \\ []) do
    outer = b.scope.vars
    {ps, bound, pins, b} = patterns(patterns, b)
    strength = Keyword.get(opts, :strength, :inferred)

    types =
      case Keyword.get(opts, :types) do
        types when is_list(types) and length(types) == length(ps) -> types
        _ -> List.duplicate(Types.unknown("nothing states the type of what this pattern is matched with"), length(ps))
      end

    b = %{b | gt: guard_types(guard, bound)}
    b = ps |> Enum.zip(types) |> Enum.reduce(b, fn {p, type}, b -> assign(p, type, strength, b) end)
    b = %{b | gt: %{}, untyped: untyped(ps, Keyword.get(opts, :whole, false), b) ++ b.untyped}
    b = if Keyword.get(opts, :whole, false), do: Enum.reduce(ps, b, &state(typed(&2, &1, intrinsic(&1, &2), :inferred), &1)), else: b
    b = show(b, bound)
    {g, b} = pinned_guard(pins, guard, meta, b)

    {bd, b} =
      case body do
        {:gap, construct} -> gap(meta, construct, b)
        expr -> tr(expr, :expr, b)
      end

    {i, b} = emit(:clause, meta, [ps, g, bd], b)
    b = typed(b, i, t(b, bd), strength(b, bd))
    {i, if(opts[:keep], do: b, else: %{b | scope: %{b.scope | vars: outer}})}
  end

  # The patterns of one clause or of one `=`. Returns their nodes, what they bind (source name -> sent name; not
  # visible yet, the caller decides when with show/2) and their pins [{sent name of the stand-in, sent name of the
  # pinned variable, meta}].
  defp patterns(list, b) do
    {ps, b} = Enum.map_reduce(list, %{b | binding: %{}, pins: []}, &tr(&1, :pattern, &2))
    {ps, b.binding, Enum.reverse(b.pins), %{b | binding: nil, pins: []}}
  end

  defp show(b, bound), do: %{b | scope: Scope.show(b.scope, bound)}

  # The pin operator has no node. `^x` in a pattern is sent as a new variable (see tr/3), and the clause's guard
  # gets `that variable =:= x` in front (H29 gives every clause a guard), which selects the same values.
  defp pinned_guard([], guard, _meta, b), do: guard(guard, b)

  defp pinned_guard(pins, guard, meta, b) do
    {tests, b} = Enum.map_reduce(pins, b, &pin_test/2)
    {g, b} = guard(guard, b)
    all(tests ++ if(g == -1, do: [], else: [g]), meta, b)
  end

  defp pin_test({stand_in, pinned, meta}, b) do
    {l, b} = variable(meta, stand_in, b)
    {r, b} = variable(meta, pinned, b)
    typed_op(meta, "=:=", [l, r], b)
  end

  defp all([one], _meta, b), do: {one, b}

  defp all([first, second | rest], meta, b) do
    {i, b} = typed_op(meta, "andalso", [first, second], b)
    all([i | rest], meta, b)
  end

  # `when a when b` holds when either guard does.
  defp guard(nil, b), do: {-1, b}

  defp guard({:when, meta, [left, right]}, b) do
    {l, b} = whole_guard(left, b)
    {r, b} = whole_guard(right, b)
    typed_op(meta, "orelse", [l, r], b)
  end

  # Contract T8.16: a type test that only states the type its variable already has (`when is_integer(n)`: the
  # test is where n's type comes from, T8.10 b) is not sent. The other tests of an `and` are sent as they are; a
  # guard of such tests alone is no guard. (An alternative of `when a when b` is sent whole.)
  defp guard(expr, b) do
    tests = conjuncts(expr)

    case Enum.reject(tests, &states_type?(&1, b)) do
      [] -> {-1, b}
      kept when length(kept) == length(tests) -> tr(expr, :expr, b)
      [first | rest] -> tr(Enum.reduce(rest, first, fn test, so_far -> {:and, elem(first, 1), [so_far, test]} end), :expr, b)
    end
  end

  defp whole_guard({:when, _, _} = both, b), do: guard(both, b)
  defp whole_guard(expr, b), do: tr(expr, :expr, b)

  defp boolean_clause?({:->, _, [[condition], _]}, b), do: Truthiness.boolean?(condition, truth(b))
  defp boolean_clause?(_other, _b), do: true

  defp plain_cond(meta, clauses, b) do
    {cs, b} =
      Enum.map_reduce(clauses, b, fn
        {:->, m, [[condition], then]}, b -> clause(m, [], condition, then, b)
        {_, m, _}, b -> gap(m, "clause", b)
      end)

    branches(:cond, meta, [cs], cs, b)
  end

  defp plain_if(meta, condition, then, otherwise, b) do
    {c1, b} = clause(meta, [], condition, then, b, keep: true)
    {always, b} = literal(true, meta, :expr, b)
    {else_body, b} = tr(otherwise, :expr, b)
    {c2, b} = emit(:clause, meta, [[], always, else_body], b)
    b = typed(b, c2, t(b, else_body), strength(b, else_body))
    branches(:cond, meta, [[c1, c2]], [c1, c2], b)
  end

  # A node whose value is the value of one of its clauses: its type is the one type they have, if they have one.
  defp branches(tag, meta, fields, clauses, b) do
    {i, b} = emit(tag, meta, fields, b)
    {i, typed(b, i, Types.join(Enum.map(clauses, &t(b, &1))), :inferred)}
  end

  # A `->` clause of case, receive or fn: `p1, p2 when guard -> body`.
  defp arrow(clause, b, opts)

  defp arrow({:->, meta, [head, body]}, b, opts) do
    case head do
      [{:when, _, args}] -> clause(meta, Enum.drop(args, -1), List.last(args), body, b, opts)
      patterns -> clause(meta, patterns, nil, body, b, opts)
    end
  end

  defp arrow({_, meta, _}, b, _opts), do: gap(meta, "clause", b)

  defp arrows(clauses, b, opts) when is_list(clauses), do: Enum.map_reduce(clauses, b, &arrow(&1, &2, opts))

  defp exprs(list, ctx, b), do: Enum.map_reduce(list, b, &tr(&1, ctx, &2))

  # A statement of a block that is not its last: the nodes it becomes. A `=` with pins becomes the match, with a
  # stand-in for each pin, then `true = (stand-in =:= pinned)` for each, which fails as the match would (H18).
  defp statement({:=, meta, [pattern, value]}, b) do
    {m, pins, b} = match(meta, pattern, value, b)

    {tests, b} =
      Enum.map_reduce(pins, b, fn {_, _, pin_meta} = pin, b ->
        {t, b} = literal(true, pin_meta, :pattern, b)
        {test, b} = pin_test(pin, b)
        {i, b} = emit(:match, pin_meta, [t, test], b)
        {i, typed(b, i, t(b, test), :inferred)}
      end)

    {[m | tests], b}
  end

  # IO.inspect(x) as a statement: its value (x) is not used, so the lowering ends with :ok instead of x.
  defp statement({{:., _, [module, :inspect]}, meta, [arg]} = expr, b) do
    {i, b} = if module_ref(module, b.env) == {:elixir, "IO"}, do: io(:inspect_dropped, arg, meta, b), else: tr(expr, :expr, b)
    {[i], b}
  end

  defp statement(expr, b) do
    {i, b} = tr(expr, :expr, b)
    {[i], b}
  end

  # (:match, at, pattern, value) and the pins of the pattern. T8.10 (b) and (e): the value must have a type, and
  # from it every variable the pattern binds; otherwise the match is a gap (and the variables have no type).
  defp match(meta, pattern, value, b) do
    {[p], bound, pins, b} = patterns([pattern], b)
    {v, b} = tr(value, :expr, b)
    type = t(b, v)
    b = assign(p, type, strength(b, v), b)
    left = untyped([p], false, b)
    b = show(b, bound)

    cond do
      b.strict and type == :never ->
        {v, [], b}

      b.strict and Types.unknown?(type) ->
        {i, b} = missing(meta, "value of a match (=)", Types.reason(type), b)
        {i, [], b}

      b.strict and left != [] ->
        {i, b} = missing(meta, "variable bound by a match (=)", problems_text(left), b)
        {i, [], b}

      true ->
        {m, b} = emit(:match, meta, [p, v], state(b, v))
        {m, pins, typed(b, m, type, strength(b, v))}
    end
  end

  # ------------------------------------------------------------------ tr/3: Elixir AST -> nodes

  # tr(ast, :expr | :pattern, builder) -> {index, builder}. Patterns use the same nodes as expressions (contract
  # 9.4); the context only decides what has no node in a pattern.

  # --- literals and data (H1..H13)
  defp tr({:__block__, meta, [x]}, ctx, b) when is_lit(x), do: literal(x, meta, ctx, b)
  defp tr({:{}, meta, elems}, ctx, b), do: tuple(meta, elems, ctx, b)
  defp tr({:%, meta, [name, {:%{}, _, fields}]}, ctx, b), do: record(meta, name, fields, ctx, b)
  defp tr({:%{}, meta, _}, _ctx, b), do: gap(meta, "map", b)

  defp tr({:<<>>, meta, parts}, _ctx, b) do
    interpolated = Enum.any?(parts, &(is_binary(&1) or match?({:"::", _, [{{:., _, [Kernel, :to_string]}, _, _}, _]}, &1)))
    gap(meta, if(interpolated, do: "string interpolation", else: "bit syntax"), b)
  end

  # --- blocks, matching and control (H16..H19, H28..H36)
  defp tr({:__block__, meta, []}, _ctx, b), do: literal(nil, meta, :expr, b)
  defp tr({:__block__, _, [one]}, ctx, b), do: tr(one, ctx, b)

  # H19. T8.10 (e): every expression of a block but the last needs a stated type.
  defp tr({:__block__, meta, many}, _ctx, b) do
    {before, b} = Enum.flat_map_reduce(Enum.drop(many, -1), b, &statement/2)
    {before, b} = Enum.map_reduce(before, b, &need(&1, "statement whose value is dropped", &2))
    {last, b} = tr(List.last(many), :expr, b)
    {i, b} = emit(:block, meta, [before ++ [last]], b)
    {i, typed(b, i, t(b, last), strength(b, last))}
  end

  # An alias pattern, `left = right` inside a pattern. The contract has no node of its own for it. This codex
  # sends H18 with both children as patterns, reading contract 9.4 ("patterns use the same node kinds as
  # expressions; which one a node is follows from where it is referenced"): a (:match, …) referenced from a
  # pattern position matches the value against both. The Erlang and Gleam proofs of concept do the same.
  defp tr({:=, meta, [left, right]}, :pattern, b) do
    {l, b} = tr(left, :pattern, b)
    {r, b} = tr(right, :pattern, b)
    emit(:match, meta, [l, r], b)
  end

  # H18. The value is translated before the pattern's bindings become visible: in `x = x + 1` it sees the old x.
  defp tr({:=, meta, [pattern, value]}, :expr, b) do
    case match(meta, pattern, value, b) do
      {m, [], b} -> {m, b}
      {_m, _pins, b} -> gap(meta, "pin operator (^) in a match used for its value", @pin_value, b)
    end
  end

  # ^x in a pattern: a stand-in variable here, and a test against x where the pattern is used (pinned_guard/4 for
  # a clause, statement/2 for a `=`). The stand-in has the pinned variable's type.
  defp tr({:^, meta, [{name, _, context}]}, :pattern, %{binding: binding} = b)
       when is_atom(name) and is_atom(context) and is_map(binding) do
    {stand_in, scope} = Scope.fresh(b.scope, "_pin")
    pinned = Scope.lookup(b.scope, name) || name(name)
    b = %{b | scope: scope, pins: [{stand_in, pinned, meta} | b.pins], vt: Map.put(b.vt, stand_in, variable_type(b, pinned))}
    emit(:var, meta, [stand_in], b)
  end

  defp tr({:^, meta, [_]}, _ctx, b), do: gap(meta, "pin operator (^)", "it pins something that is not a variable", b)

  defp tr({:<>, meta, [_, _]}, :pattern, b), do: gap(meta, "binary pattern (<>)", b)

  # a |> f(b) is f(a, b).
  defp tr({:|>, meta, [left, right]}, ctx, b) do
    piped =
      try do
        {:ok, Macro.pipe(left, right, 0)}
      rescue
        ArgumentError -> :error
      end

    case piped do
      {:ok, call} -> tr(call, ctx, b)
      :error -> gap(meta, "pipe into something that is not a call", b)
    end
  end

  # H28. T8.10 (e): the subject needs a stated type; (b): from it, the variables its clauses bind get theirs.
  defp tr({:case, meta, [subject, body]}, _ctx, b) do
    case kw(body) do
      [do: clauses] when is_list(clauses) ->
        {s, b} = tr(subject, :expr, b)
        type = t(b, s)

        cond do
          b.strict and type == :never ->
            {s, b}

          b.strict and Types.unknown?(type) ->
            missing(meta, "subject of a case", Types.reason(type), b)

          true ->
            {cs, problems, b} = collecting(state(b, s), &arrows(clauses, &1, types: [type], strength: strength(b, s)))

            if b.strict and problems != [],
              do: missing(meta, "variable bound by a case clause", problems_text(problems), b),
              else: branches(:case, meta, [s, cs], cs, b)
        end

      _ ->
        gap(meta, "case", b)
    end
  end

  # H30: clauses with no patterns; the condition is the clause's guard. A condition that is not known to be a
  # boolean is tested for truthiness with a case (E2s.Codex.Truthiness).
  defp tr({:cond, meta, [body]}, ctx, b) do
    case kw(body) do
      [do: clauses] when is_list(clauses) ->
        if Enum.all?(clauses, &boolean_clause?(&1, b)),
          do: plain_cond(meta, clauses, b),
          else: tr(Truthiness.cond_case(clauses, meta, truth(b)), ctx, b)

      _ ->
        gap(meta, "cond", b)
    end
  end

  # if c do a else b end is a two-clause cond when c is known to be a boolean, and a case on c's truthiness
  # otherwise; a missing else gives nil.
  defp tr({:if, meta, [condition, body]}, ctx, b) do
    case kw(body) do
      [{:do, then} | rest] when rest == [] or (length(rest) == 1 and elem(hd(rest), 0) == :else) ->
        otherwise = Keyword.get(rest, :else, {:__block__, meta, []})

        if Truthiness.boolean?(condition, truth(b)),
          do: plain_if(meta, condition, then, otherwise, b),
          else: tr(Truthiness.if_case(condition, then, otherwise, meta), ctx, b)

      _ ->
        gap(meta, "if", b)
    end
  end

  # H36. T8.10 (a): a closure needs a (:t_fun) hint. Elixir writes no type on a fn's parameters, so they have
  # one only when the fn has no parameters or is written directly where a function type is declared (an argument
  # of a function of this module whose @spec gives it: `b.expect`). The result is the type of its body.
  defp tr({:fn, meta, clauses}, _ctx, b) do
    {expect, b} = {b.expect, %{b | expect: nil}}

    arity =
      case clauses do
        [{:->, _, [[{:when, _, args}], _]} | _] -> length(args) - 1
        [{:->, _, [head, _]} | _] -> length(head)
        _ -> 0
      end

    {params, declared} =
      case expect do
        {:t_fun, params, result} when length(params) == arity ->
          {params, result}

        _ ->
          why = "Elixir writes no type on a fn's parameters, and this fn is not an argument of a function of this module whose @spec gives the function type"
          {List.duplicate(Types.unknown(why), arity), nil}
      end

    {cs, problems, b} = collecting(b, &arrows(clauses, &1, types: params, strength: :declared))
    body = Types.join(Enum.map(cs, &t(b, &1)))
    result = if Types.known?(body) or declared == nil, do: body, else: declared

    cond do
      b.strict and problems != [] ->
        missing(meta, "parameter of a fn", problems_text(problems) <> " (T8.10 a)", b)

      b.strict and not Types.known?(result) ->
        missing(meta, "result of a fn", Types.reason(result) <> " (T8.10 a)", b)

      true ->
        {i, b} = emit(:lambda, meta, [cs], b)

        type =
          if Types.known?(result) and Enum.all?(params, &Types.known?/1),
            do: {:t_fun, params, result},
            else: Types.unknown("this fn has no stated function type")

        {i, state(typed(b, i, type, if(declared, do: :declared, else: :inferred)), i)}
    end
  end

  # &name/arity and &Mod.name/arity (H35). A capture with placeholders (&(&1 + 1)) is a gap.
  defp tr({:&, meta, [{:/, _, [target, {:__block__, _, [arity]}]}]}, _ctx, b) when is_integer(arity) do
    case target do
      {name, _, context} when is_atom(name) and is_atom(context) ->
        if MapSet.member?(b.env.locals, {name, arity}) or {name, arity} not in Kernel.__info__(:functions),
          do: fun_ref(meta, "", name, arity, b),
          else: fun_ref(meta, "Kernel", name, arity, b)

      {{:., _, [module, name]}, _, []} when is_atom(name) ->
        case module_ref(module, b.env) do
          {_, module_name} -> fun_ref(meta, module_name, name, arity, b)
          :error -> gap(meta, "capture (&)", b)
        end

      _ ->
        gap(meta, "capture (&)", b)
    end
  end

  defp tr({:&, meta, _}, _ctx, b), do: gap(meta, "capture with placeholders (&1)", b)

  # --- processes and messages (H23). T8.10 (e): the message of each clause needs a type. Elixir declares none
  # for a process's messages, so the type is what the pattern states: its literals, its pinned variables, and
  # the variables its guard tests (`{:add, n} when is_integer(n)`). A clause that binds a variable with no such
  # test, or has a `_`, has no message type, and the receive is a gap.
  defp tr({:receive, meta, [body]}, _ctx, b) do
    case kw(body) do
      :error ->
        gap(meta, "receive", b)

      kws ->
        message = Types.unknown("Elixir declares no type for a received message, and no guard of the clause (is_integer/1, is_pid/1, …) tests it")
        {cs, problems, b} = collecting(b, &arrows(Keyword.get(kws, :do, []), &1, types: [message], whole: true))

        cond do
          b.strict and problems != [] ->
            missing(meta, "message of a receive clause", problems_text(problems) <> " (T8.10 e)", b)

          true ->
            case Keyword.get(kws, :after) do
              nil ->
                branches(:receive, meta, [cs, -1, -1], cs, b)

              [{:->, _, [[timeout], after_body]}] ->
                {t, b} = tr(timeout, :expr, b)
                outer = b.scope.vars
                {a, b} = tr(after_body, :expr, b)
                {i, b} = emit(:receive, meta, [cs, t, a], %{b | scope: %{b.scope | vars: outer}})
                {i, typed(b, i, Types.join(Enum.map(cs ++ [a], &t(b, &1))), :inferred)}

              _ ->
                gap(meta, "receive", b)
            end
        end
    end
  end

  defp tr({:@, meta, _}, _ctx, b), do: gap(meta, "module attribute", b)
  # A module name as a value is the atom Elixir.<full name> (N5).
  defp tr({:__aliases__, meta, _} = alias, _ctx, b) do
    case module_ref(alias, b.env) do
      {:elixir, module} -> symbol(meta, "Elixir." <> module, b)
      _ -> gap(meta, "module name as a value", b)
    end
  end

  # --- variables (H16, H17)
  defp tr({:_, meta, context}, _ctx, b) when is_atom(context), do: emit(:wild, meta, [], b)

  # A variable in a pattern is a new binding and gets a name of its own; anywhere else it is a reference to the
  # binding it sees (E2s.Codex.Scope). A name that nothing binds is sent as written.
  defp tr({name, meta, context}, ctx, b) when is_atom(name) and is_atom(context) do
    cond do
      name in [:__MODULE__, :__ENV__, :__DIR__, :__CALLER__, :__STACKTRACE__] -> gap(meta, Atom.to_string(name), b)
      ctx == :pattern and is_map(b.binding) -> bind(name, meta, b)
      true -> variable(meta, Scope.lookup(b.scope, name) || name(name), b)
    end
  end

  # --- f.(x) (H33), Mod.fun(args) (H32), expr.field (H13), expr.fun(args) (H34)
  defp tr({{:., _, [fun]}, meta, args}, _ctx, b) do
    {f, b} = tr(fun, :expr, b)
    {as, b} = exprs(args, :expr, b)
    {i, b} = emit(:apply, meta, [f, as], b)

    type =
      case t(b, f) do
        {:t_fun, params, result} when length(params) == length(as) -> result
        :never -> :never
        other -> Types.unknown("the function value called here has no stated function type of #{length(as)} parameters: #{Types.reason(other)} (T8.10 d)")
      end

    {i, state(typed(b, i, type, strength(b, f)), i)}
  end

  defp tr({{:., dot_meta, [left, name]}, meta, args}, _ctx, b) when is_atom(name) do
    case module_ref(left, b.env) do
      :error ->
        if Keyword.get(meta, :no_parens, false) and args == [] do
          {r, b} = tr(left, :expr, b)
          {i, b} = emit(:field, meta, [r, name(name)], b)

          # T8.9: a field's type is the field's in the record's stated type, so the record needs one.
          case t(b, r) do
            {:t_named, type_name, _} ->
              {i, typed(state(b, r), i, field_type(type_name, name(name), b.env), :declared)}

            :never ->
              {i, typed(b, i, :never, :inferred)}

            other ->
              why = "the value whose field #{name} is read is not known to be a struct of this file: #{Types.reason(other)}"
              if b.strict, do: missing(meta, "struct of a field access", why <> " (T8.9)", b), else: {i, typed(b, i, Types.unknown(why), :inferred)}
          end
        else
          {m, b} = tr(left, :expr, b)
          {f, b} = symbol(dot_meta, Atom.to_string(name), b)
          {as, b} = exprs(args, :expr, b)
          {i, b} = emit(:apply_mfa, meta, [m, f, as], b)
          {i, typed(b, i, Types.unknown("a call whose module is computed has no result type the codex can state (T8.10 d)"), :inferred)}
        end

      module ->
        remote(module, name, args, meta, b)
    end
  end

  # --- operators (Appendix B)
  defp tr({:-, meta, [{:__block__, _, [n]}]}, _ctx, b) when is_number(n), do: literal(-n, meta, :expr, b)
  defp tr({:+, _, [one]}, ctx, b), do: tr(one, ctx, b)
  defp tr({:-, meta, [one]}, _ctx, b), do: op(meta, "neg", [one], b)
  defp tr({:not, meta, [one]}, _ctx, b), do: op(meta, "not", [one], b)
  # !, && and ||: Appendix B's operators when the operands are known to be booleans, a case on truthiness
  # otherwise (E2s.Codex.Truthiness).
  defp tr({:!, meta, [one]}, ctx, b) do
    if Truthiness.boolean?(one, truth(b)), do: op(meta, "not", [one], b), else: tr(Truthiness.not_case(one, meta), ctx, b)
  end

  defp tr({name, meta, [l, r]}, ctx, b) when name in [:&&, :||] do
    cond do
      Truthiness.boolean?(l, truth(b)) and Truthiness.boolean?(r, truth(b)) ->
        op(meta, if(name == :&&, do: "andalso", else: "orelse"), [l, r], b)

      name == :&& ->
        tr(Truthiness.and_case(l, r, meta), ctx, b)

      true ->
        tr(Truthiness.or_case(l, r, meta), ctx, b)
    end
  end
  defp tr({name, meta, [l, r]}, _ctx, b) when is_map_key(@binary_ops, name), do: op(meta, @binary_ops[name], [l, r], b)

  # --- what E2s.Split and the lowering of IO write for the codex: a construct the split does not cut (a gap
  #     with its note), and one L1 call of a Silica print builtin (contract T9.16)
  defp tr({:"$e2s_gap", meta, [{:__block__, _, [construct]}, {:__block__, _, [note]}]}, _ctx, b), do: gap(meta, construct, note, b)

  # What E2s.Sup read of a supervisor start: one static child.
  defp tr({:"$e2s_static_child", meta, [name, restart, strategy, function, args]}, _ctx, b),
    do: static_child(meta, unwrap(name), unwrap(restart), unwrap(strategy), unwrap(function), unwrap(args), b)

  defp tr({:"$e2s_print", meta, [builtin, arg]}, _ctx, b) when is_binary(builtin) do
    {a, b} = tr(arg, :expr, b)
    {i, b} = emit(:sl_call, meta, ["", builtin, [a]], state(b, a))
    {i, typed(b, i, if(builtin == "atom_name", do: Types.text(), else: Types.atom()), :inferred)}
  end

  # --- local calls, the process built-ins and Kernel
  defp tr({name, meta, args}, _ctx, b) when is_atom(name) and is_list(args) do
    arity = length(args)

    cond do
      MapSet.member?(b.env.locals, {name, arity}) ->
        local(meta, name, args, b)

      Macro.operator?(name, arity) ->
        gap(meta, "operator #{name}", b)

      true ->
        case builtin(name, args, meta, Atom.to_string(name), b) do
          nil -> kernel(name, args, meta, b)
          done -> done
        end
    end
  end

  # --- everything else is outside the proof of concept
  defp tr({_, meta, _}, _ctx, b) when is_list(meta), do: gap(meta, "expression", b)
  defp tr(_other, _ctx, b), do: gap([], "expression", b)

  # A variable that occurs twice in the patterns of one clause is one binding.
  defp bind(name, meta, b) do
    case b.binding do
      %{^name => sent} ->
        emit(:var, meta, [sent], b)

      binding ->
        {sent, scope} = Scope.bind(b.scope, name(name))
        emit(:var, meta, [sent], %{b | scope: scope, binding: Map.put(binding, name, sent)})
    end
  end

  # H16 as a value: its stated type is its binding's (T8.9).
  defp variable(meta, sent, b) do
    {i, b} = emit(:var, meta, [sent], b)
    {type, strength} = variable_type(b, sent)
    {i, typed(b, i, type, strength)}
  end

  defp symbol(meta, text, b) do
    {i, b} = emit(:symbol, meta, [text], b)
    {i, typed(b, i, Types.symbols([text]), :inferred)}
  end

  defp literal(n, meta, _ctx, b) when is_integer(n) do
    if n >= -0x8000_0000_0000_0000 and n <= 0x7FFF_FFFF_FFFF_FFFF do
      {i, b} = emit(:int, meta, [n], b)
      {i, typed(b, i, Types.int(), :inferred)}
    else
      gap(meta, "integer beyond 64 bits", b)
    end
  end

  # H2: decimal text that reads back to the same value.
  defp literal(f, meta, _ctx, b) when is_float(f) do
    {i, b} = emit(:float, meta, [:erlang.float_to_binary(f, [:short])], b)
    {i, typed(b, i, Types.float(), :inferred)}
  end

  defp literal(bool, meta, _ctx, b) when is_boolean(bool) do
    {i, b} = emit(:boolean, meta, [bool], b)
    {i, typed(b, i, Types.boolean(), :inferred)}
  end

  # nil is the atom nil in Elixir; the contract's (:nil, at) is the empty list, so it is not used here.
  defp literal(atom, meta, _ctx, b) when is_atom(atom), do: symbol(meta, Atom.to_string(atom), b)

  defp literal(text, meta, _ctx, b) when is_binary(text) do
    if String.valid?(text) do
      {i, b} = emit(:text, meta, [text], b)
      {i, typed(b, i, Types.text(), :inferred)}
    else
      emit(:bytes, meta, [text], b)
    end
  end

  defp literal({left, right}, meta, ctx, b), do: tuple(meta, [left, right], ctx, b)

  defp literal(list, meta, _ctx, b) when is_list(list) do
    keyword = list != [] and Enum.all?(list, &match?({{:__block__, _, [k]}, _} when is_atom(k), &1))
    gap(meta, if(keyword, do: "keyword list", else: "list"), b)
  end

  # H8. As a value its type is the tuple of its elements' types (T8.9); a pattern gets its type in assign/4.
  defp tuple(meta, elems, ctx, b) do
    {is, b} = exprs(elems, ctx, b)
    {i, b} = emit(:tuple, meta, [is], b)
    # Stated by a hint whenever it is known, so that a tuple inside a tuple has the type its parent's hint says.
    {i, if(ctx == :expr, do: state(typed(b, i, tuple_type(is, Enum.map(is, &t(b, &1)), b), :inferred), i), else: b)}
  end

  # H12: a struct construction, update (base /= -1) or pattern. Field order is the source's. T8.10 (e): a
  # construction states its type, the struct's declaration; a field's value must fit the field's declared type.
  defp record(meta, name_ast, fields, ctx, b) do
    {base, fields} =
      case fields do
        [{:|, _, [base, updates]}] -> {base, updates}
        fields -> {nil, fields}
      end

    case {module_ref(name_ast, b.env), kw(fields)} do
      {{:elixir, name}, kws} when is_list(kws) and not (ctx == :pattern and base != nil) ->
        type_name = Names.type_name(name)
        type = record_type(type_name, b.env)

        if b.strict and Types.unknown?(type) do
          missing(meta, "struct", Types.reason(type) <> " (T8.14)", b)
        else
          {base_idx, b} = if base == nil, do: {-1, b}, else: tr(base, :expr, b)

          {pairs, b} =
            Enum.map_reduce(kws, b, fn {field, value}, b ->
              {i, b} = tr(value, ctx, b)
              {i, b} = if ctx == :expr, do: fit(i, field_type(type_name, name(field), b.env), "value of the field #{field} of #{name}", b), else: {i, b}
              {{name(field), i}, b}
            end)

          {i, b} = emit(:record, meta, [type_name, pairs, base_idx], b)
          {i, if(ctx == :expr, do: state(typed(b, i, type, :declared), i), else: b)}
        end

      _ ->
        gap(meta, "struct with a computed name or keys", b)
    end
  end

  # A value written where a type is declared (an argument, a field): Elixir converts nothing there, so a value
  # of another type is sent as a gap rather than as Silica that cannot be typed.
  defp fit(i, declared, what, b) do
    if Types.fits?(t(b, i), declared) do
      {i, b}
    else
      unruly(meta_of(b, i), what, "it is #{Types.show(t(b, i))} where #{Types.show(declared)} is declared; Elixir passes the value as it is, and no conversion exists to send (T8.11, T8.12)", b)
    end
  end

  # ------------------------------------------------------------------ operators: types and conversions (T8.11, T8.12, T8.15)

  defp op(meta, name, args, b) do
    {is, b} = exprs(args, :expr, b)
    typed_op(meta, name, is, b)
  end

  @arithmetic ~w(+ - *)
  @comparison ~w(== /= < =< > >= =:= =/=)
  @logic ~w(andalso orelse not)
  @integer_only ~w(div rem band bor bxor bnot bsl bsr)

  # An operator over written operands. T8.10 (c): every operand needs a stated type; an operand without one
  # makes the operator a gap. Then Elixir's rule for the operator decides the result type and what is converted.
  defp typed_op(meta, name, is, b) do
    types = Enum.map(is, &t(b, &1))

    cond do
      :never in types ->
        plain(meta, name, is, :never, b)

      unknown = Enum.find(types, &Types.unknown?/1) ->
        if b.strict,
          do: missing(meta, "operand of #{name}", Types.reason(unknown) <> " (T8.10 c)", b),
          else: plain(meta, name, is, if(name in @comparison or name in @logic, do: Types.boolean(), else: unknown), b)

      true ->
        ruled(meta, name, is, types, b)
    end
  end

  # Writes the operator with its operands as they are; their types are stated (T8.10 c).
  defp plain(meta, name, is, type, b) do
    {i, b} = emit(:op, meta, [name, is], Enum.reduce(is, b, &state(&2, &1)))
    {i, typed(b, i, type, :inferred)}
  end

  # + - *: integers give an integer, floats a float; an integer next to a float is converted, as Elixir does.
  defp ruled(meta, name, [l, r], types, b) when name in @arithmetic do
    case Enum.map(types, &Types.num/1) do
      [:int, :int] -> plain(meta, name, [l, r], Types.int(), b)
      [:float, :float] -> plain(meta, name, [l, r], Types.float(), b)
      [:int, :float] -> with({l, b} <- to_float(l, meta, b), do: plain(meta, name, [l, r], Types.float(), b))
      [:float, :int] -> with({r, b} <- to_float(r, meta, b), do: plain(meta, name, [l, r], Types.float(), b))
      _ -> not_numbers(meta, name, types, b)
    end
  end

  # /: always a float in Elixir. Both operands are converted, and a zero divisor fails (T8.15).
  defp ruled(meta, "/", [l, r], types, b) do
    if Enum.all?(types, &Types.num/1) do
      {l, b} = if Types.num(t(b, l)) == :int, do: to_float(l, meta, b), else: {l, b}
      {r, b} = if Types.num(t(b, r)) == :int, do: to_float(r, meta, b), else: {r, b}
      division(meta, l, r, b)
    else
      not_numbers(meta, "/", types, b)
    end
  end

  # div, rem and the bitwise operators take integers only; Elixir raises ArithmeticError for a float.
  defp ruled(meta, name, is, types, b) when name in @integer_only do
    if Enum.all?(types, &(Types.num(&1) == :int)),
      do: plain(meta, name, is, Types.int(), b),
      else: unruly(meta, "operands of #{name}", "#{name} on #{shown(types)}: it takes integers only (T8.11)", b)
  end

  defp ruled(meta, "neg", [x], [type], b) do
    if Types.num(type), do: plain(meta, "neg", [x], type, b), else: not_numbers(meta, "-", [type], b)
  end

  defp ruled(meta, name, is, types, b) when name in @logic do
    if Enum.all?(types, &(&1 == Types.boolean())),
      do: plain(meta, name, is, Types.boolean(), b),
      else: unruly(meta, "operands of #{name}", "#{name} on #{shown(types)}: Appendix B gives it boolean operands only", b)
  end

  defp ruled(meta, "<>", is, types, b) do
    if Enum.all?(types, &(&1 == Types.text())),
      do: plain(meta, "<>", is, Types.text(), b),
      else: unruly(meta, "operands of <>", "<> on #{shown(types)}: it takes two strings (Appendix B)", b)
  end

  # Comparisons (T8.11: both operands of one stated type). An integer next to a float is converted for == and
  # the order operators, as Elixir compares numbers by value; === and !== between an integer and a float, and
  # any equality between types that share no value, is false (or true) whatever the values (Appendix B, note).
  defp ruled(meta, name, [l, r], [lt, rt], b) when name in @comparison do
    strict_equality = name in ["=:=", "=/="]
    equality = strict_equality or name in ["==", "/="]

    case {Types.num(lt), Types.num(rt)} do
      {:int, :float} when not strict_equality ->
        with {l, b} <- to_float(l, meta, b), do: plain(meta, name, [l, r], Types.boolean(), b)

      {:float, :int} when not strict_equality ->
        with {r, b} <- to_float(r, meta, b), do: plain(meta, name, [l, r], Types.boolean(), b)

      _ ->
        cond do
          one_type?(l, r, b) ->
            plain(meta, name, [l, r], Types.boolean(), b)

          equality and Types.disjoint?(lt, rt) ->
            static(meta, name in ["/=", "=/="], [l, r], b)

          true ->
            unruly(meta, "operands of #{name}", "#{Types.show(lt)} #{name} #{Types.show(rt)}: the operands are of two types (T8.11), and comparing across types by Elixir's term order has no operator (Appendix B, open)", b)
        end
    end
  end

  defp ruled(meta, name, is, _types, b), do: plain(meta, name, is, Types.unknown("the codex has no typing rule for the operator #{name}"), b)

  defp shown(types), do: Enum.map_join(types, " and ", &Types.show/1)

  defp not_numbers(meta, name, types, b),
    do: unruly(meta, "operands of #{name}", "#{name} on #{shown(types)}: it takes two integers or two floats (T8.11)", b)

  # T8.11's "the same stated type": equal types, or a literal atom next to a type it belongs to (T8.9: a symbol
  # takes the symbol type its place states).
  defp one_type?(l, r, b) do
    lt = t(b, l)
    rt = t(b, r)
    lt == rt or atom_of?(l, rt, b) or atom_of?(r, lt, b)
  end

  defp atom_of?(i, type, b) do
    case {node(b, i), type} do
      {{:symbol, _, name}, {:t_symbols, names}} -> name in names
      {{:symbol, _, _}, {:t_basic, :symbol}} -> true
      _ -> false
    end
  end

  # T8.12: integer to float, where Elixir converts. An integer literal is rewritten as the float literal of the
  # same value (T8.11); anything else gets the conversion operator.
  defp to_float(i, meta, b) do
    case node(b, i) do
      {:int, at, n} ->
        {i, typed(%{b | nodes: Map.put(b.nodes, i, {:float, at, :erlang.float_to_binary(n * 1.0, [:short])})}, i, Types.float(), :inferred)}

      _ ->
        plain(meta, "to_float", [i], Types.float(), b)
    end
  end

  # T8.15. Elixir's `/` raises ArithmeticError on a zero divisor; Silica's float division does not fail
  # (limitation observed, Appendix B). So the division is sent under a guard:
  #
  #     cond do divisor == 0.0 -> (:fail, badarith); true -> dividend / divisor end
  #
  # Each operand is evaluated once: one that is not a variable or a literal is bound first (`_div_1 = …`), in a
  # block around the cond. A literal divisor other than zero needs no guard.
  defp division(meta, l, r, b) do
    case node(b, r) do
      {:float, _, text} ->
        if String.to_float(text) == 0.0, do: guarded_division(meta, l, r, b), else: plain(meta, "/", [l, r], Types.float(), b)

      _ ->
        guarded_division(meta, l, r, b)
    end
  end

  defp guarded_division(meta, l, r, b) do
    {l, bound_l, b} = once(l, meta, b)
    {r, bound_r, b} = once(r, meta, b)
    {zero, b} = literal(0.0, meta, :expr, b)
    {is_zero, b} = plain(meta, "==", [r, zero], Types.boolean(), b)
    {reason, b} = symbol(meta, "badarith", b)
    {fail, b} = emit(:fail, meta, [reason], b)
    {c1, b} = emit(:clause, meta, [[], is_zero, fail], typed(b, fail, :never, :inferred))
    {otherwise, b} = literal(true, meta, :expr, b)
    {r_again, b} = again(r, meta, b)
    {quotient, b} = plain(meta, "/", [l, r_again], Types.float(), b)
    {c2, b} = emit(:clause, meta, [[], otherwise, quotient], b)
    {guarded, b} = emit(:cond, meta, [[c1, c2]], b)
    b = hint(typed(b, guarded, Types.float(), :inferred), guarded, Types.float(), :inferred)

    case bound_l ++ bound_r do
      [] ->
        {guarded, b}

      bindings ->
        {block, b} = emit(:block, meta, [bindings ++ [guarded]], b)
        {block, hint(typed(b, block, Types.float(), :inferred), block, Types.float(), :inferred)}
    end
  end

  # An operand that may be written twice without being evaluated twice: a variable, a literal, or the
  # conversion of one. Anything else is bound to a new variable first; the binding is returned.
  defp once(i, meta, b) do
    if repeatable?(i, b) do
      {i, [], b}
    else
      {sent, scope} = Scope.fresh(b.scope, "_div")
      type = t(b, i)
      {p, b} = emit(:var, meta, [sent], %{b | scope: scope})
      b = bind_type(b, p, sent, type, :inferred)
      {m, b} = emit(:match, meta, [p, i], state(b, i))
      b = hint(typed(b, m, type, :inferred), m, type, :inferred)
      {v, b} = variable(meta, sent, b)
      {v, [m], b}
    end
  end

  defp repeatable?(i, b) do
    case node(b, i) do
      {:var, _, _} -> true
      {:float, _, _} -> true
      {:op, _, "to_float", [x]} -> repeatable?(x, b)
      _ -> false
    end
  end

  # A second copy of a repeatable operand (a node is referenced from one parent only).
  defp again(i, meta, b) do
    case node(b, i) do
      {:var, _, sent} -> variable(meta, sent, b)
      {:float, _, text} -> with({j, b} <- emit(:float, meta, [text], b), do: {j, typed(b, j, Types.float(), :inferred)})
      {:op, _, "to_float", [x]} -> with({x, b} <- again(x, meta, b), do: plain(meta, "to_float", [x], Types.float(), b))
    end
  end

  # A comparison whose answer the two types decide: the constant, after the operands if evaluating them could
  # do anything (Appendix B, note).
  defp static(meta, value, [l, r], b) do
    if pure?(l, b) and pure?(r, b) do
      literal(value, meta, :expr, b)
    else
      {v, b} = literal(value, meta, :expr, b)
      {i, b} = emit(:block, meta, [[l, r, v]], b |> state(l) |> state(r))
      {i, typed(b, i, Types.boolean(), :inferred)}
    end
  end

  defp pure?(i, b), do: elem(node(b, i), 0) in [:var, :int, :float, :text, :boolean, :symbol]

  # trunc/1 and round/1 (T8.12): the conversion operator on a float; an integer is already the answer.
  # floor/1 and ceil/1 have no conversion operator, so on a float they are gaps.
  defp conversion(meta, name, arg, b) do
    {x, b} = tr(arg, :expr, b)
    type = t(b, x)

    cond do
      type == :never -> {x, b}
      Types.unknown?(type) and b.strict -> missing(meta, "operand of #{name}", Types.reason(type) <> " (T8.12)", b)
      Types.unknown?(type) -> with({i, b} <- emit(:call, meta, ["Kernel", name, [x]], b), do: {i, typed(b, i, Types.int(), :inferred)})
      Types.num(type) == :int -> {x, b}
      Types.num(type) == :float and name in ["trunc", "round"] -> plain(meta, name, [x], Types.int(), b)
      Types.num(type) == :float -> unruly(meta, "conversion #{name}", "#{name}/1 on a float has no conversion operator (T8.12 has to_float, trunc and round)", b)
      true -> unruly(meta, "operand of #{name}", "#{name} on #{Types.show(type)}: it takes a number (T8.12)", b)
    end
  end

  # ------------------------------------------------------------------ calls (H32, H35)

  # A call to a function of this module. Its result type is the callee's @spec's (T8.10 d): the codex sees the
  # whole module. A fn written as an argument takes its type from the parameter's declared function type.
  defp local(meta, name, args, b) do
    arity = length(args)
    label = "#{name}/#{arity}"

    made = is_map_key(b.env.gen, {name, arity})

    {params, type} =
      case Map.get(b.env.sigs, {name, arity}) do
        {:ok, params, result} ->
          {params, result}

        # a made function whose parameters are still being collected (made_sigs/2): its result is known
        {:none, why} when made and b.env.collecting ->
          {nil, made_result({name, arity}, b.env) || Types.unknown("the local call #{label}: #{label} #{why} (T8.10 d)")}

        # a made function that got no signature is sent as a gap form: so is a call of it, with the reason
        {:none, why} when made and b.strict ->
          {:gap, "#{label} #{why}"}

        {:none, why} ->
          {nil, Types.unknown("the local call #{label}: #{label} #{why}, so its result type cannot be stated (T8.10 d)")}

        nil ->
          {nil, Types.unknown("the call #{label}: no function #{label} is defined in this module, so its result type cannot be stated (T8.10 d)")}
      end

    if params == :gap do
      gap(meta, "call of a function this sender made and could not type", type, b)
    else
      {as, b} =
        args
        |> Enum.zip(params || List.duplicate(nil, arity))
        |> Enum.with_index(1)
        |> Enum.map_reduce(b, fn {{arg, param}, n}, b ->
          {i, b} = tr(arg, :expr, %{b | expect: if(match?({:fn, _, _}, arg), do: param)})
          if param && not made, do: fit(i, param, "argument #{n} of #{label}", %{b | expect: nil}), else: {i, %{b | expect: nil}}
        end)

      # A function E2s.Split made: this call's arguments say what its parameters are (made_sigs/2).
      b =
        if made do
          types = Enum.map(as, &t(b, &1))
          %{b | calls: Map.update(b.calls, {name, arity}, types, &merge_all(&1, types))}
        else
          b
        end

      {i, b} = emit(:call, meta, ["", fname(name, arity, b.env), as], b)
      {i, state(typed(b, i, type, :declared), i)}
    end
  end

  # H32 for another module. `module` is the module's name as written (N2).
  defp call(meta, module, name, args, b) do
    {as, b} = exprs(args, :expr, b)
    {i, b} = emit(:call, meta, [module, name(name), as], b)
    {i, state(typed(b, i, stdlib(module, name, as, b), :inferred), i)}
  end

  # The result types the codex knows of functions outside the module: a few of Elixir's standard library, by
  # Elixir's documentation. Any other call into another module has no type the codex can state.
  defp stdlib(module, name, as, b) do
    types = Enum.map(as, &t(b, &1))

    case {module, name, types} do
      {"IO", :puts, [_]} -> Types.symbols(["ok"])
      {"IO", :inspect, [type]} -> type
      {"String", :length, [_]} -> Types.int()
      {"String", fun, [_]} when fun in [:upcase, :downcase, :trim, :capitalize, :reverse] -> Types.text()
      {m, :to_string, [_]} when m in ["Integer", "Float", "Atom"] -> Types.text()
      {m, fun, types} when m in ["Kernel", "erlang"] -> kernel_type(fun, types)
      _ -> Types.unknown("the call #{module}.#{name}/#{length(as)}: it is in another module, whose @spec the codex does not see, so its result type cannot be stated (T8.10 d)")
    end
  end

  # Kernel's functions, by Elixir's rules.
  defp kernel_type(name, types) do
    cond do
      String.starts_with?(Atom.to_string(name), "is_") ->
        Types.boolean()

      name == :abs and match?([_], types) and Types.num(hd(types)) != nil ->
        hd(types)

      name in [:max, :min] and match?([same, same], types) and Types.num(hd(types)) != nil ->
        hd(types)

      name in [:byte_size, :tuple_size, :length, :map_size] ->
        Types.int()

      true ->
        Types.unknown("the call Kernel.#{name}/#{length(types)}: the codex has no typing rule for it, so its result type cannot be stated (T8.10 d)")
    end
  end

  # H35. A function of this module has the function type its @spec gives.
  defp fun_ref(meta, module, name, arity, b) do
    own = module in ["", b.env.module] and (module == "" or MapSet.member?(b.env.locals, {name, arity}))
    {i, b} = emit(:fun_ref, meta, [module, if(own, do: fname(name, arity, b.env), else: name(name)), arity], b)

    type =
      case own && Map.get(b.env.sigs, {name, arity}) do
        {:ok, params, result} -> {:t_fun, params, result}
        _ -> Types.unknown("the function #{name}/#{arity} has no @spec the codex sees, so its function type cannot be stated")
      end

    {i, state(typed(b, i, type, :declared), i)}
  end

  # Kernel's type tests on a variable. A stated type answers the test (the variable of `when is_integer(n)` has
  # the type the test gave it, T8.10 b; the hint's policy is what checks the value); only a type that does not
  # decide it leaves the call.
  @type_tests %{is_integer: :int, is_float: :float, is_number: :number, is_binary: :text, is_boolean: :boolean,
                is_atom: :atom, is_pid: :pid, is_tuple: :tuple}

  # True when the guard test is a type test on a variable whose stated type answers it with true (T8.16).
  defp states_type?({test, _, [{variable, _, context}]}, b)
       when is_map_key(@type_tests, test) and is_atom(variable) and is_atom(context) do
    case Scope.lookup(b.scope, variable) do
      nil -> false
      sent -> Types.test(Map.fetch!(@type_tests, test), elem(variable_type(b, sent), 0)) == true
    end
  end

  defp states_type?(_test, _b), do: false

  # What Kernel and :erlang share: the process built-ins get their own nodes (H20..H22, H26). `label` names the
  # call in a gap. Returns nil when the name is not one of them.
  defp builtin(test, [{variable, _, context} = arg], meta, _label, b)
       when is_map_key(@type_tests, test) and is_atom(variable) and is_atom(context) do
    {v, b} = tr(arg, :expr, b)

    case Types.test(Map.fetch!(@type_tests, test), t(b, v)) do
      :unknown ->
        {i, b} = emit(:call, meta, ["Kernel", name(test), [v]], b)
        {i, state(typed(b, i, Types.boolean(), :inferred), i)}

      answer ->
        literal(answer, meta, :expr, b)
    end
  end

  defp builtin(:self, [], meta, _label, b) do
    {i, b} = emit(:self, meta, [], b)
    {i, state(typed(b, i, Types.pid(), :inferred), i)}
  end

  defp builtin(spawn, [fun], meta, _label, b) when spawn in [:spawn, :spawn_link] do
    {f, b} = tr(fun, :expr, b)
    spawned(meta, f, [], spawn == :spawn_link, b)
  end

  defp builtin(spawn, [module, fun, args], meta, label, b) when spawn in [:spawn, :spawn_link] do
    with {_, module_name} <- module_ref(module, b.env),
         {:__block__, _, [name]} when is_atom(name) <- fun,
         {:__block__, _, [list]} when is_list(list) <- args,
         false <- Enum.any?(list, &match?({:|, _, _}, &1)) do
      {f, b} = fun_ref(meta, module_name, name, length(list), b)
      {as, b} = exprs(list, :expr, b)
      spawned(meta, f, as, spawn == :spawn_link, b)
    else
      _ -> gap(meta, "#{label}/3 with a computed module, function or argument list", b)
    end
  end

  defp builtin(spawn, args, meta, label, b)
       when spawn in [:spawn, :spawn_link, :spawn_monitor, :spawn_opt, :spawn_request],
       do: gap(meta, "#{label}/#{length(args)}", "spawn on another node or with options is outside the proof of concept", b)

  # H22. T8.10 (e): the message needs a stated type. The value of a send is the message.
  defp builtin(:send, [to, message], meta, _label, b) do
    case to do
      {:__block__, _, [{_, _}]} ->
        gap(meta, "send to a process on another node", @inter_node, b)

      # H39: a send to a registered name. Its value is the message, as a send's is (T9.14c).
      {:__block__, _, [name]} when is_atom(name) ->
        {m, b} = tr(message, :expr, b)
        {m, b} = need(m, "message of a send", b)
        {i, b} = emit(:send_named, meta, [Atom.to_string(name), m], b)
        {i, typed(b, i, t(b, m), strength(b, m))}

      _ ->
        {t, b} = tr(to, :expr, b)
        {m, b} = tr(message, :expr, b)
        {m, b} = need(m, "message of a send", b)
        {i, b} = emit(:send, meta, [t, m], state(b, t))
        {i, typed(b, i, t(b, m), strength(b, m))}
    end
  end

  defp builtin(:exit, [reason], meta, _label, b), do: fail(meta, reason, b)

  # is_nil(x) is a Kernel macro for x == nil.
  defp builtin(:is_nil, [value], meta, _label, b), do: op(meta, "=:=", [value, {:__block__, meta, [nil]}], b)

  defp builtin(name, [_, _] = args, meta, _label, b) when name in [:div, :rem], do: op(meta, Atom.to_string(name), args, b)

  defp builtin(name, [arg], meta, _label, b) when name in [:trunc, :round, :floor, :ceil],
    do: conversion(meta, Atom.to_string(name), arg, b)

  defp builtin(name, args, meta, label, b)
       when name in [:node, :nodes, :monitor_node, :disconnect_node, :is_alive, :set_cookie, :get_cookie],
       do: gap(meta, "#{label}/#{length(args)}", @inter_node, b)

  defp builtin(_name, _args, _meta, _label, _b), do: nil

  # H21. A spawn's value is the new process.
  defp spawned(meta, f, as, link, b) do
    {i, b} = emit(:spawn, meta, [f, as, link], b)
    {i, state(typed(b, i, Types.pid(), :inferred), i)}
  end

  # A static child (contract T9.14b): a (:register) of a (:spawn) whose arguments are literals. The transpiler
  # writes it into the child list its unit's supervisor has from its start, registered under `name`. The child's
  # own restart policy and its supervisor's strategy, AS THE ELIXIR SOURCE WRITES THEM (E2s.Sup), are an A4.4
  # override on the (:spawn) (T7.6). The spawn is not linked: the child is under a supervisor, which is what the
  # link of a supervisor's child is for. Its value is `true`, as Process.register/2's is.
  defp static_child(meta, name, restart, strategy, function, args, b0) do
    arity = length(args)
    {f, b} = fun_ref(meta, b0.env.module, function, arity, b0)
    {as, b} = exprs(args, :expr, b)

    case t(b, f) do
      {:t_fun, params, _} ->
        if Enum.all?(Enum.zip(as, params), fn {a, param} -> Types.fits?(t(b, a), param) end) do
          {s, b} = spawned(meta, f, as, false, b)

          override = %{
            node: s, requirement: :a4_4, choice: :chosen,
            detail: %{params: [{"restart", Atom.to_string(restart)}, {"strategy", Atom.to_string(strategy)}],
                      note: "the child specification and the strategy of Supervisor.init/2"}
          }

          {i, b} = emit(:register, meta, [Atom.to_string(name), s], %{b | overrides: [override | b.overrides]})
          {i, typed(b, i, Types.boolean(), :inferred)}
        else
          gap(meta, "a supervisor's static child",
            "the child #{name} runs #{function}/#{arity}, and an argument its specification gives is of another type than the @spec of #{function}/#{arity} declares (T9.14)", b0)
        end

      _ ->
        gap(meta, "a supervisor's static child",
          "the child #{name} runs #{function}/#{arity}, which is no function of this module with an @spec that types its parameters (T9.14)", b0)
    end
  end

  # H26. It has no value (and so no type).
  defp fail(meta, reason, b) do
    {r, b} = tr(reason, :expr, b)
    {i, b} = emit(:fail, meta, [r], b)
    {i, typed(b, i, :never, :inferred)}
  end

  # A name that is not defined in this module and is not a built-in: a Kernel function is a remote call to
  # Kernel, a Kernel macro or special form is a gap, anything else is taken as a local call.
  defp kernel(name, args, meta, b) do
    arity = length(args)

    cond do
      is_map_key(@named_gaps, name) -> gap(meta, @named_gaps[name], b)
      String.starts_with?(Atom.to_string(name), "sigil_") -> gap(meta, "sigil", b)
      {name, arity} in Kernel.__info__(:functions) -> call(meta, "Kernel", name, args, b)
      {name, arity} in Kernel.__info__(:macros) -> gap(meta, "Kernel.#{name}/#{arity} (a macro)", b)
      {name, arity} in Kernel.SpecialForms.__info__(:macros) -> gap(meta, "#{name}/#{arity} (a special form)", b)
      true -> local(meta, name, args, b)
    end
  end

  # Mod.fun(args) with a module known at compile time.
  defp remote({kind, module_name} = module, name, args, meta, b) do
    arity = length(args)
    label = call_name(module, name)

    cond do
      module_class(module) == :distribution ->
        gap(meta, "#{label}/#{arity}", @inter_node, b)

      module_class(module) == :otp ->
        gap(meta, "#{label}/#{arity}", @otp, b)

      # Kernel.+(a, b) is a + b.
      module == {:elixir, "Kernel"} and arity == 2 and is_map_key(@binary_ops, name) ->
        op(meta, @binary_ops[name], args, b)

      module in [{:elixir, "Kernel"}, {:erlang, "erlang"}] ->
        case builtin(name, args, meta, label, b) do
          nil -> if kind == :erlang, do: erlang(name, args, meta, label, b), else: call(meta, module_name, name, args, b)
          done -> done
        end

      module == {:elixir, "Process"} ->
        process(name, args, meta, label, b)

      module == {:elixir, "Bitwise"} and is_map_key(@bitwise, {name, arity}) ->
        op(meta, @bitwise[{name, arity}], args, b)

      # This module, written out: a local call.
      module == {:elixir, b.env.module} and MapSet.member?(b.env.locals, {name, arity}) ->
        local(meta, name, args, b)

      module == {:elixir, "IO"} and name in [:puts, :inspect] and arity == 1 ->
        io(name, hd(args), meta, b)

      true ->
        call(meta, module_name, name, args, b)
    end
  end

  # ------------------------------------------------------------------ IO.puts/1, IO.inspect/1 (contract T9.16)

  # Elixir's own output is this sender's business: a call into IO is a call outside the session, which the
  # transpiler does not write (T9.9). So IO.puts(x) and IO.inspect(x) are sent as what they do: x is evaluated
  # (and bound to a variable of the codex when it is not one), then one L1 call of a Silica print builtin for
  # each piece of the text, chosen by x's STATED type, then the call's value (:ok for puts, x for inspect).
  #
  #   IO.puts      a string: println. An atom: its name. An integer, a float, a boolean: its text and a line end.
  #   IO.inspect   (then a line end; its value is x, or :ok where the call is a statement whose value is dropped)
  #                an integer, a float, a boolean; an atom as Elixir writes it (:ok, true, nil, :"two words") when
  #                the type names the atoms, `:` and the name otherwise; a string between double quotes; a tuple
  #                as `{a, b}` of such values; a union of tagged tuples and atoms by a case over its alternatives.
  #
  # Anything else (a struct, a pid, a list, a value with no stated type, IO.inspect/2 with options) is a gap
  # that says which. NOT ELIXIR'S OUTPUT: a float is printed by Silica's print_float64 (at most 15 decimal
  # places, cut and not rounded, where Elixir writes the shortest text that reads back; contract T9.16); a string is not escaped by IO.inspect (a `"` or a
  # control character inside it is written as it is); an atom whose type is atom() is written `:name` even when
  # Elixir would write true, false, nil or quote the name.
  @io_var :e2s_io

  defp io(kind, arg, meta, b) do
    {v, b} = tr(arg, :expr, b)
    type = t(b, v)
    label = if kind == :puts, do: "IO.puts/1", else: "IO.inspect/1"
    # a literal is written where it is printed; anything else is evaluated once and printed from a variable
    literal = match?({:__block__, _, [x]} when is_number(x) or is_binary(x) or is_atom(x), arg)
    x = if literal, do: arg, else: {@io_var, meta, nil}

    cond do
      type == :never ->
        {v, b}

      Types.unknown?(type) and not b.strict ->
        {i, b} = emit(:call, meta, ["IO", if(kind == :puts, do: "puts", else: "inspect"), [v]], b)
        {i, typed(b, i, if(kind == :puts, do: Types.symbols(["ok"]), else: type), :inferred)}

      Types.unknown?(type) ->
        gap(meta, label, "its argument has no stated type, so no print builtin can be chosen for it (T9.16): " <> Types.reason(type), b)

      true ->
        plan =
          if kind == :puts,
            do: puts_ast(type, x, meta),
            else: with({:ok, statements, n} <- inspect_ast(type, x, meta, 1), do: {:ok, statements ++ [print("println", quoted("", meta), meta)], n})

        case plan do
          {:error, why} -> gap(meta, label, why, b)
          {:ok, statements, _n} -> io_block(kind, v, type, merge_prints(statements), meta, label, literal, b)
        end
    end
  end

  # (:block, [the binding of x], the prints, the value).
  defp io_block(kind, v, type, statements, meta, label, literal, b) do
    outer = b.scope.vars

    {sent, binds, b} =
      case node(b, v) do
        _ when literal ->
          {nil, [], b}

        {:var, _, sent} ->
          {sent, [], b}

        _ ->
          {sent, scope} = Scope.fresh(b.scope, "_io")
          {p, b} = emit(:var, meta, [sent], %{b | scope: scope})
          b = bind_type(b, p, sent, type, strength(b, v))
          {m, b} = emit(:match, meta, [p, v], state(b, v))
          {sent, [m], hint(typed(b, m, type, :inferred), m, type, :inferred)}
      end

    b = if sent, do: show(b, %{@io_var => sent}), else: b

    {prints, b} =
      Enum.map_reduce(statements, b, fn statement, b ->
        {i, b} = tr(statement, :expr, b)
        need(i, "statement of the lowered #{label}", b)
      end)

    {last, b} =
      cond do
        kind != :inspect -> symbol(meta, "ok", b)
        literal -> {v, b}
        true -> variable(meta, sent, b)
      end

    {i, b} = emit(:block, meta, [binds ++ prints ++ [last]], %{b | scope: %{b.scope | vars: outer}})
    {i, state(typed(b, i, t(b, last), strength(b, last)), i)}
  end

  defp print(builtin, arg, meta), do: {:"$e2s_print", meta, [builtin, arg]}
  defp quoted(x, meta), do: {:__block__, meta, [x]}
  defp atom_text(name), do: inspect(String.to_atom(name))

  # Adjacent pieces of fixed text are one print.
  defp merge_prints([{:"$e2s_print", m, ["print", {:__block__, _, [a]}]}, {:"$e2s_print", _, [builtin, {:__block__, _, [b]}]} | rest])
       when is_binary(a) and is_binary(b) and builtin in ["print", "println"],
       do: merge_prints([print(builtin, quoted(a <> b, m), m) | rest])

  defp merge_prints([first | rest]), do: [first | merge_prints(rest)]
  defp merge_prints([]), do: []

  # IO.puts(x): {:ok, statements, _} | {:error, why}
  defp puts_ast(type, x, meta) do
    case type do
      {:t_basic, :text} -> {:ok, [print("println", x, meta)], 0}
      {:t_int, _} -> {:ok, [print("print_int64", x, meta), print("println", quoted("", meta), meta)], 0}
      {:t_float, _} -> {:ok, [print("print_float64", x, meta), print("println", quoted("", meta), meta)], 0}
      {:t_basic, :boolean} -> {:ok, [print("print_boolean", x, meta), print("println", quoted("", meta), meta)], 0}
      {:t_symbols, ["nil"]} -> {:ok, [print("println", quoted("", meta), meta)], 0}
      {:t_symbols, [name]} -> {:ok, [print("println", quoted(name, meta), meta)], 0}
      {:t_basic, :symbol} -> {:ok, [print("println", print("atom_name", x, meta), meta)], 0}
      {:t_symbols, names} when is_list(names) -> if("nil" in names, do: puts_error(type), else: {:ok, [print("println", print("atom_name", x, meta), meta)], 0})
      _ -> puts_error(type)
    end
  end

  defp puts_error(type),
    do: {:error, "IO.puts of a value of the type #{Types.show(type)} is not lowered to print builtins (a string, an atom other than nil in a union, an integer, a float, a boolean are: T9.16)"}

  # IO.inspect(x), without the line end: the statements that print the value of the variable `x` of this type,
  # and the next free number for a variable of the lowering.
  defp inspect_ast(type, x, meta, n) do
    case type do
      {:t_int, _} ->
        {:ok, [print("print_int64", x, meta)], n}

      {:t_float, _} ->
        {:ok, [print("print_float64", x, meta)], n}

      {:t_basic, :boolean} ->
        {:ok, [print("print_boolean", x, meta)], n}

      {:t_basic, :text} ->
        {:ok, [print("print", quoted("\"", meta), meta), print("print", x, meta), print("print", quoted("\"", meta), meta)], n}

      {:t_symbols, [name]} ->
        {:ok, [print("print", quoted(atom_text(name), meta), meta)], n}

      {:t_symbols, names} ->
        clauses = for name <- names, do: {:->, meta, [[quoted(String.to_atom(name), meta)], print("print", quoted(atom_text(name), meta), meta)]}
        {:ok, [{:case, meta, [x, [{quoted(:do, meta), clauses}]]}], n}

      {:t_basic, :symbol} ->
        {:ok, [print("print", quoted(":", meta), meta), print("print", print("atom_name", x, meta), meta)], n}

      {:t_tuple, types} ->
        with {:ok, pattern, statements, n} <- inspect_tuple(nil, types, meta, n), do: {:ok, [{:=, meta, [pattern, x]} | statements], n}

      {:t_tagged, _, _} ->
        inspect_ast({:t_union, [type]}, x, meta, n)

      {:t_union, alts} ->
        keys = Enum.flat_map(alts, fn
          {:t_tagged, tag, types} -> [{tag, length(types)}]
          {:t_symbols, names} -> names
          _ -> [:other]
        end)

        if :other in keys or keys != Enum.uniq(keys) do
          inspect_error(type)
        else
          result =
            Enum.reduce_while(alts, {:ok, [], n}, fn
              {:t_symbols, names}, {:ok, clauses, n} ->
                more = for name <- names, do: {:->, meta, [[quoted(String.to_atom(name), meta)], print("print", quoted(atom_text(name), meta), meta)]}
                {:cont, {:ok, clauses ++ more, n}}

              {:t_tagged, tag, types}, {:ok, clauses, n} ->
                case inspect_tuple(tag, types, meta, n) do
                  {:ok, pattern, statements, n} -> {:cont, {:ok, clauses ++ [{:->, meta, [[pattern], {:__block__, meta, merge_prints(statements)}]}], n}}
                  error -> {:halt, error}
                end
            end)

          with {:ok, clauses, n} <- result, do: {:ok, [{:case, meta, [x, [{quoted(:do, meta), clauses}]]}], n}
        end

      _ ->
        inspect_error(type)
    end
  end

  # `{:tag, a, b}` (tag nil: `{a, b}`): the pattern that takes it apart and the statements that print it.
  defp inspect_tuple(tag, types, meta, n) do
    result =
      Enum.reduce_while(types, {:ok, [], [], n}, fn type, {:ok, vars, pieces, n} ->
        v = {String.to_atom("e2s_i#{n}"), meta, nil}

        case inspect_ast(type, v, meta, n + 1) do
          {:ok, statements, n} -> {:cont, {:ok, vars ++ [v], pieces ++ [statements], n}}
          error -> {:halt, error}
        end
      end)

    with {:ok, vars, pieces, n} <- result do
      text = fn s -> [print("print", quoted(s, meta), meta)] end
      head = if tag, do: [text.(atom_text(tag))], else: []
      inner = Enum.intersperse(head ++ pieces, text.(", "))
      pattern = {:{}, meta, if(tag, do: [quoted(String.to_atom(tag), meta)], else: []) ++ vars}
      {:ok, pattern, List.flatten([text.("{"), inner, text.("}")]), n}
    end
  end

  defp inspect_error(type),
    do: {:error, "IO.inspect of a value of the type #{Types.show(type)} is not lowered to print builtins (integers, floats, booleans, atoms, strings, tuples of them and unions of tagged tuples and atoms are: T9.16)"}

  # Process.link/1 (H24), Process.exit/2 (H25). Nothing else of Process is in the subset: Process.flag/2 has no
  # node in the contract and travels as a gap.
  defp process(:link, [pid], meta, _label, b), do: link(meta, pid, b)
  defp process(:exit, [pid, reason], meta, _label, b), do: exit_signal(meta, pid, reason, b)

  defp process(name, args, meta, label, b) when name in [:register, :unregister, :whereis, :registered],
    do: gap(meta, "#{label}/#{length(args)}", @registered, b)

  defp process(_name, args, meta, label, b), do: gap(meta, "#{label}/#{length(args)}", b)

  # :erlang.fun(args) beyond the shared built-ins.
  defp erlang(:link, [pid], meta, _label, b), do: link(meta, pid, b)
  defp erlang(:exit, [pid, reason], meta, _label, b), do: exit_signal(meta, pid, reason, b)
  defp erlang(:error, [reason], meta, _label, b), do: fail(meta, reason, b)

  # :erlang.float/1 is the integer-to-float conversion (T8.12); a float is already the answer.
  defp erlang(:float, [arg], meta, _label, b) do
    {x, b} = tr(arg, :expr, b)
    type = t(b, x)

    cond do
      type == :never or Types.num(type) == :float -> {x, b}
      Types.num(type) == :int -> to_float(x, meta, b)
      Types.unknown?(type) and b.strict -> missing(meta, "operand of to_float", Types.reason(type) <> " (T8.12)", b)
      Types.unknown?(type) -> with({i, b} <- emit(:call, meta, ["erlang", "float", [x]], b), do: {i, typed(b, i, Types.float(), :inferred)})
      true -> unruly(meta, "operand of to_float", ":erlang.float/1 on #{Types.show(type)}: it takes a number (T8.12)", b)
    end
  end

  defp erlang(name, args, meta, label, b) when name in [:register, :unregister, :whereis, :registered],
    do: gap(meta, "#{label}/#{length(args)}", @registered, b)

  defp erlang(name, args, meta, label, b)
       when name in [:process_flag, :monitor, :demonitor, :unlink, :throw, :apply],
       do: gap(meta, "#{label}/#{length(args)}", b)

  defp erlang(name, args, meta, _label, b), do: call(meta, "erlang", name, args, b)

  # Process.link/1 and Process.exit/2 return true.
  defp link(meta, pid, b) do
    {p, b} = tr(pid, :expr, b)
    {i, b} = emit(:link, meta, [p], state(b, p))
    {i, typed(b, i, Types.boolean(), :inferred)}
  end

  defp exit_signal(meta, pid, reason, b) do
    {p, b} = tr(pid, :expr, b)
    {r, b} = tr(reason, :expr, b)
    {i, b} = emit(:exit_signal, meta, [p, r], state(b, p))
    {i, typed(b, i, Types.boolean(), :inferred)}
  end

  defp call_name({:elixir, module}, name), do: "#{module}.#{name}"
  defp call_name({:erlang, module}, name), do: ":#{module}.#{name}"

  defp module_class({:elixir, name}) do
    cond do
      name in @distribution_elixir -> :distribution
      name in @otp_elixir or String.starts_with?(name, ["Task.", "Supervisor.", "GenServer."]) -> :otp
      true -> :plain
    end
  end

  defp module_class({:erlang, name}) do
    cond do
      name in @distribution_erlang -> :distribution
      name in @otp_erlang -> :otp
      true -> :plain
    end
  end

  # A module named in the source: an alias (resolved through `alias` and nested modules), __MODULE__, or an
  # Erlang module's atom. -> {:elixir, "My.Mod"} | {:erlang, "lists"} | :error
  defp module_ref({:__aliases__, _, [{:__MODULE__, _, context} | rest]}, env) when is_atom(context) do
    if Enum.all?(rest, &is_atom/1), do: {:elixir, Enum.join([env.module | rest], ".")}, else: :error
  end

  defp module_ref({:__aliases__, _, [first | rest] = parts}, env) do
    if Enum.all?(parts, &is_atom/1),
      do: {:elixir, Enum.join([Map.get(env.aliases, first, Atom.to_string(first)) | rest], ".")},
      else: :error
  end

  defp module_ref({:__MODULE__, _, context}, env) when is_atom(context), do: {:elixir, env.module}

  defp module_ref({:__block__, _, [atom]}, _env) when is_atom(atom) and not is_boolean(atom) and atom != nil,
    do: {:erlang, Atom.to_string(atom)}

  defp module_ref(_other, _env), do: :error

  # A keyword list as the parser writes it with the literal encoder: keys are wrapped atoms.
  defp kw({:__block__, _, [list]}) when is_list(list), do: kw(list)

  defp kw(list) when is_list(list) do
    Enum.reduce_while(list, [], fn
      {{:__block__, _, [key]}, value}, acc when is_atom(key) -> {:cont, [{key, value} | acc]}
      _, _ -> {:halt, :error}
    end)
    |> case do
      :error -> :error
      acc -> Enum.reverse(acc)
    end
  end

  defp kw(_), do: :error

  defp unwrap({:__block__, _, [x]}) when is_lit(x), do: unwrap(x)
  defp unwrap(x), do: x
end
