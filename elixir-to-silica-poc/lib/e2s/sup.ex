defmodule E2s.Sup do
  @moduledoc """
  Elixir's `Supervisor`, read by the sender BEFORE anything is split, typed or sent (quoted forms in, quoted
  forms out). A supervisor is Elixir's (OTP's) own construct: what `use Supervisor`, `init/1`,
  `Supervisor.init/2`, a child specification and a start function mean is this sender's business (contract 1,
  "What you own"), and the transpiler knows none of it. What the sender sends instead is the contract's STATIC
  CHILD (T9.14b): a `(:register)` of a `(:spawn)` with literal arguments, which the transpiler writes into the
  child list its unit's supervisor has from its start.

      use Supervisor
      def start_sup do                                          def start_sup do
        {:ok, _sup} =                                             <static child :tally, :transient, :one_for_one,
          Supervisor.start_link(__MODULE__, [], name: Demo.Sup)      counter(0)>
        :ok                                                         :ok
      end                                                         end
      def init([]) do
        children = [                                              (init/1 and start_tally/1 are not sent: what
          %{id: :tally, restart: :transient,                       they say is in the static child)
            start: {__MODULE__, :start_tally, [0]}}
        ]
        Supervisor.init(children, strategy: :one_for_one)
      end
      def start_tally(start) do
        pid = spawn_link(__MODULE__, :counter, [start])
        Process.register(pid, :tally)
        {:ok, pid}
      end

  The static child is written as a call of `:"$e2s_static_child"`, which is no function: it is a mark the codex
  turns into nodes (`E2s.Codex`, "a static child").

  WHAT IS READ, and what makes this pass leave a gap in place of the start (its note says which):

    * **the module** has `use Supervisor` and one `init/1` clause without a guard.
    * **the start**: `{:ok, _} = Supervisor.start_link(ThisModule, arg)` or `… start_link(ThisModule, arg, opts)`
      as a statement of a function body, the variable `_` or one that starts with `_`; or the call alone as a
      statement that is not the last. `arg` is literal data. A start whose value is used stays a call (the
      supervisor's own pid has no node), which the codex sends as a gap.
    * **init/1** is read, not run: its parameter is matched against `arg`; its body is `name = literal data`
      statements and then `Supervisor.init(children, opts)`. `opts` must write `strategy:` (Elixir's
      `Supervisor.init/2` raises without it); `max_restarts:` and `max_seconds:` are read and not carried.
    * **a child specification** is a map `%{id: …, start: {ThisModule, :function, [literal, …]}}` with an
      optional `restart:` (`:permanent` when it is not written, as in OTP) and `type: :worker`; or
      `{ThisModule, arg}` / `ThisModule` when the module writes a `child_spec/1` of one clause whose body is such
      a map (it is read with `arg`, `[]` for the bare module).
    * **the start function** has one clause, variables as parameters, and the body `{:ok, spawn_link(…)}` or
      `pid = spawn_link(…)`, an optional `Process.register(pid, :name)` (or `true = Process.register(…)`),
      `{:ok, pid}`; the `spawn_link` is `spawn_link(ThisModule, :g, [a, …])` or `spawn_link(fn -> g(a, …) end)`
      and each `a` is an integer, a float or an atom, or a parameter that the child specification gives one.
    * **the child's name** is the name its start function registers it under; with none, the `id` of its
      specification.

  WHAT IS NOT ELIXIR'S BEHAVIOUR (README, "A static supervisor").
  """

  defguardp is_lit(x)
            when is_number(x) or is_atom(x) or is_binary(x) or is_list(x) or (is_tuple(x) and tuple_size(x) == 2)

  @mark :"$e2s_static_child"
  @strategies [:one_for_one, :one_for_all, :rest_for_one]
  @restarts [:permanent, :transient, :temporary]

  @doc "The name of the call this pass writes for a static child; the codex turns it into nodes."
  def mark, do: @mark

  @doc """
  The forms of a module body with every supervisor start that can be read replaced by its static children, and
  `use Supervisor`, `init/1` and the start functions (which nothing else calls) taken out. A start that cannot
  be read is replaced by the gap call of `E2s.Split` with the reason. A module without `use Supervisor` is
  answered as it is.
  """
  def forms(forms, module) do
    if Enum.any?(forms, &use_supervisor?/1) do
      {forms1, used} = Enum.map_reduce(forms, [], &form(&1, forms, module, &2))
      if used == [], do: forms1, else: remove(forms1, Enum.uniq(used))
    else
      forms
    end
  end

  defp use_supervisor?({:use, _, [{:__aliases__, _, [:Supervisor]} | _]}), do: true
  defp use_supervisor?(_form), do: false

  # Only the top level of a function body is looked at.
  defp form({kind, meta, [head, body]} = form, forms, module, used) when kind in [:def, :defp] do
    case body do
      [{{:__block__, do_meta, [:do]}, expr}] ->
        stmts = stmts(expr)

        {out, used} =
          stmts
          |> Enum.with_index()
          |> Enum.flat_map_reduce(used, fn {stmt, i}, used ->
            case start(stmt, i < length(stmts) - 1) do
              {:ok, call_meta, args} ->
                case read(forms, module, args) do
                  {:ok, children} ->
                    {Enum.map(children, &mark(call_meta, &1)), Enum.flat_map(children, & &1.gone) ++ [{:init, 1} | used]}

                  {:no, why} ->
                    {[gap(call_meta, why)], used}
                end

              :no ->
                {[stmt], used}
            end
          end)

        if out == stmts, do: {form, used}, else: {{kind, meta, [head, [{{:__block__, do_meta, [:do]}, block(out)}]]}, used}

      _ ->
        {form, used}
    end
  end

  defp form(form, _forms, _module, used), do: {form, used}

  defp stmts({:__block__, _, [x]} = literal) when is_lit(x), do: [literal]
  defp stmts({:__block__, _, stmts}), do: stmts
  defp stmts(expr), do: [expr]

  defp block([one]), do: one
  defp block(many), do: {:__block__, [], many}

  # Is this statement a supervisor start whose value is not used? `not_last`: other statements follow it.
  defp start({:=, _, [{:__block__, _, [{{:__block__, _, [:ok]}, {var, _, context}}]}, call]}, _not_last)
       when is_atom(var) and is_atom(context) do
    if String.starts_with?(Atom.to_string(var), "_"), do: start_call(call), else: :no
  end

  defp start(call, true), do: start_call(call)
  defp start(_stmt, _not_last), do: :no

  defp start_call({{:., _, [{:__aliases__, _, [:Supervisor]}, :start_link]}, meta, [module, arg | opts]})
       when length(opts) <= 1,
       do: {:ok, meta, {module, arg}}

  defp start_call(_call), do: :no

  defp mark(meta, %{name: name, restart: restart, strategy: strategy, function: function, args: args}) do
    lit = &{:__block__, meta, [&1]}
    {@mark, meta, [lit.(name), lit.(restart), lit.(strategy), lit.(function), lit.(Enum.map(args, lit))]}
  end

  defp gap(meta, why) do
    lit = &{:__block__, meta, [&1]}

    {E2s.Split.gap_call(), meta,
     [lit.("Supervisor.start_link"),
      lit.("a supervisor is sent only as its static children (contract T9.14b), and this one could not be read: " <>
             why <> " (README, \"A static supervisor\")")]}
  end

  # init/1, each start function and child_spec/1 that no other code of the module calls, their @spec and @impl,
  # and `use Supervisor`: the behaviour has been read.
  defp remove(forms, used) do
    gone = for key <- used, key == {:init, 1} or not called?(key, forms, used), do: key

    forms
    |> Enum.chunk_every(2, 1, [nil])
    |> Enum.reject(fn [form, next] -> gone?(form, next, gone) end)
    |> Enum.map(&hd/1)
  end

  defp gone?({kind, _, [head | _]}, _next, gone) when kind in [:def, :defp], do: head_key(head) in gone
  defp gone?({:@, _, [{:spec, _, [{:"::", _, [head, _]}]}]}, _next, gone), do: head_key(head) in gone
  defp gone?({:@, _, [{:impl, _, _}]}, {kind, _, [head | _]}, gone) when kind in [:def, :defp], do: head_key(head) in gone
  defp gone?(form, _next, _gone), do: use_supervisor?(form)

  defp head_key({:when, _, [call, _]}), do: head_key(call)
  defp head_key({name, _, args}) when is_atom(name), do: {name, if(is_list(args), do: length(args), else: 0)}
  defp head_key(_), do: nil

  # Is the function called (or captured) by a function that stays?
  defp called?({name, arity} = key, forms, used) do
    Enum.any?(forms, fn
      {kind, _, [head, body]} when kind in [:def, :defp] ->
        head_key(head) not in used and head_key(head) != key and calls?(body, name, arity)

      _ ->
        false
    end)
  end

  defp calls?({name, _, args}, name, arity) when is_list(args) and length(args) == arity, do: true
  defp calls?({{:., _, [_, name]}, _, args}, name, arity) when is_list(args) and length(args) == arity, do: true
  defp calls?({:/, _, [{name, _, _}, {:__block__, _, [arity]}]}, name, arity), do: true
  defp calls?({:/, _, [{{:., _, [_, name]}, _, _}, {:__block__, _, [arity]}]}, name, arity), do: true
  defp calls?({a, _, args}, name, arity), do: calls?(a, name, arity) or calls?(args, name, arity)
  defp calls?({a, b}, name, arity), do: calls?(a, name, arity) or calls?(b, name, arity)
  defp calls?(list, name, arity) when is_list(list), do: Enum.any?(list, &calls?(&1, name, arity))
  defp calls?(_other, _name, _arity), do: false

  # ------------------------------------------------------------------ reading a supervisor

  @doc """
  The children of the supervisor that `Supervisor.start_link(module_ast, arg_ast)` starts, read from the forms of
  the module `module`: `{:ok, [child]}` or `{:no, why}`. A child is `%{name:, restart:, strategy:, function:,
  args: [integer | float | atom], gone: [{name, arity}]}` (`gone`: the functions that only describe it).
  """
  def read(forms, module, {module_ast, arg_ast}) do
    try do
      data(module_ast, %{}, module, "the callback module is not a module name") == {:module, module} or
        no("the callback module is another module")

      arg = data(arg_ast, %{}, module, "the argument of init/1 is not literal data")
      {strategy, specs} = init(forms, module, arg)
      {:ok, Enum.map(specs, &child(&1, strategy, forms, module))}
    catch
      {:no, why} -> {:no, why}
    end
  end

  defp no(why), do: throw({:no, why})

  # init/1 read with the argument of the start: {strategy, child specifications}.
  defp init(forms, module, arg) do
    {param, body} = one_clause(forms, :init, 1, "init/1")
    bound = bind(param, arg, %{}, "the parameter of init/1 does not match the argument of the start")
    {last, bound} = statements(body, bound, module, "init/1")

    case last do
      {{:., _, [{:__aliases__, _, [:Supervisor]}, :init]}, _, [children, opts]} ->
        specs = data(children, bound, module, "the child list of Supervisor.init/2 is not literal data")
        opts = data(opts, bound, module, "the options of Supervisor.init/2 are not literal data")
        (is_list(specs) and Keyword.keyword?(opts)) or no("Supervisor.init/2 is not given a list of children and a keyword list")

        strategy =
          case Keyword.fetch(opts, :strategy) do
            {:ok, strategy} when strategy in @strategies -> strategy
            {:ok, _} -> no("a strategy the contract has no value for (A4.4)")
            :error -> no("Supervisor.init/2 is given no strategy: (Elixir raises there)")
          end

        {strategy, specs}

      _ ->
        no("init/1 does not end with Supervisor.init(children, options)")
    end
  end

  # The one clause of name/arity: {parameters (one, or the list), statements}.
  defp one_clause(forms, name, arity, label) do
    clauses =
      for {kind, _, [head, body]} <- forms, kind in [:def, :defp], head_key(head) == {name, arity}, do: {head, body}

    case clauses do
      [{{^name, _, args}, [{{:__block__, _, [:do]}, expr}]}] ->
        args = if is_list(args), do: args, else: []
        {if(arity == 1, do: hd(args), else: args), stmts(expr)}

      [] ->
        no("the module has no #{label}")

      _ ->
        no("#{label} is not a function of one clause without a guard")
    end
  end

  # `name = literal data` statements, then the last statement: {last, bindings}.
  defp statements(stmts, bound, module, label) do
    {before, [last]} = Enum.split(stmts, -1)

    bound =
      Enum.reduce(before, bound, fn
        {:=, _, [{var, _, context}, value]}, bound when is_atom(var) and is_atom(context) ->
          Map.put(bound, var, data(value, bound, module, "#{label} binds #{var} to something that is not literal data"))

        _, _ ->
          no("#{label} has a statement that is not `name = literal data`: its child list is not read")
      end)

    {last, bound}
  end

  # A parameter matched against a value: a variable is bound, `_` takes anything, literal data must be equal.
  defp bind({:_, _, context}, _value, bound, _why) when is_atom(context), do: bound
  defp bind({var, _, context}, value, bound, _why) when is_atom(var) and is_atom(context), do: Map.put(bound, var, value)

  defp bind(pattern, value, bound, why) do
    if data(pattern, %{}, "", why) == value, do: bound, else: no(why)
  end

  # Literal data: numbers, atoms, strings, lists, tuples, maps, module names, and variables bound to them.
  defp data(ast, bound, module, why) do
    data(ast, bound, module)
  catch
    :not_data -> no(why)
  end

  defp data({:__block__, _, [x]}, bound, module) when is_lit(x) do
    cond do
      is_list(x) -> Enum.map(x, &data(&1, bound, module))
      is_tuple(x) -> {data(elem(x, 0), bound, module), data(elem(x, 1), bound, module)}
      true -> x
    end
  end

  # the keyword list that ends a call's arguments is written without brackets, so it is no wrapped literal
  defp data(list, bound, module) when is_list(list), do: Enum.map(list, &data(&1, bound, module))
  # a keyword pair inside a list or a map
  defp data({key, value}, bound, module), do: {data(key, bound, module), data(value, bound, module)}
  defp data({:{}, _, elems}, bound, module), do: elems |> Enum.map(&data(&1, bound, module)) |> List.to_tuple()
  defp data({:%{}, _, pairs}, bound, module) when is_list(pairs), do: Map.new(pairs, &data(&1, bound, module))
  defp data({:-, _, [{:__block__, _, [n]}]}, _bound, _module) when is_number(n), do: -n
  defp data({:__MODULE__, _, context}, _bound, module) when is_atom(context), do: {:module, module}

  defp data({:__aliases__, _, [{:__MODULE__, _, context} | rest]}, _bound, module) when is_atom(context),
    do: if(Enum.all?(rest, &is_atom/1), do: {:module, Enum.join([module | rest], ".")}, else: throw(:not_data))

  defp data({:__aliases__, _, parts}, _bound, _module),
    do: if(Enum.all?(parts, &is_atom/1), do: {:module, Enum.join(parts, ".")}, else: throw(:not_data))

  defp data({var, _, context}, bound, _module) when is_atom(var) and is_atom(context) do
    case bound do
      %{^var => value} -> value
      _ -> throw(:not_data)
    end
  end

  defp data(_other, _bound, _module), do: throw(:not_data)

  # One child: its specification, then its start function read with the specification's arguments.
  defp child(spec, strategy, forms, module) do
    {spec, gone} = specification(spec, forms, module)

    {id, start, restart} =
      case spec do
        %{id: id, start: start} ->
          Map.get(spec, :type, :worker) == :worker or no("a child that is a supervisor is not read")
          restart = Map.get(spec, :restart, :permanent)
          restart in @restarts or no("a restart the contract has no value for (A4.4)")
          {id, start, restart}

        _ ->
          no("a child specification is not a map with id: and start:, or {Module, argument} with a child_spec/1 that is one")
      end

    {function, args} =
      case start do
        {{:module, ^module}, function, args} when is_atom(function) and is_list(args) -> {function, args}
        {{:module, _}, _, _} -> no("a child's start function is in another module")
        _ -> no("a child's start is not {Module, :function, [arguments]}")
      end

    {params, body} = one_clause(forms, function, length(args), "the start function #{function}/#{length(args)}")
    params = if length(args) == 1, do: [params], else: params

    bound =
      params
      |> Enum.zip(args)
      |> Map.new(fn
        {{var, _, context}, value} when is_atom(var) and is_atom(context) -> {var, value}
        _ -> no("a parameter of a child's start function is not a variable")
      end)

    {spawn, registered} = start_body(body)
    {run, run_args} = spawned(spawn, module)
    name = registered || id
    (is_atom(name) and not is_nil(name) and not is_boolean(name)) or no("a child has no name: its id is not an atom and it is not registered")

    %{name: name, restart: restart, strategy: strategy, function: run, args: Enum.map(run_args, &scalar(&1, bound)),
      gone: [{function, length(args)} | gone]}
  end

  # A child as the list writes it -> {the map of its specification, the functions that only describe it}.
  defp specification(%{} = spec, _forms, _module), do: {spec, []}
  defp specification({:module, _} = m, forms, module), do: specification({m, []}, forms, module)

  defp specification({{:module, name}, arg}, forms, module) do
    name == module or no("a child is another module: its child_spec/1 is not read")
    {param, body} = one_clause(forms, :child_spec, 1, "child_spec/1 (a child is written as {Module, argument})")
    bound = bind(param, arg, %{}, "the parameter of child_spec/1 does not match the child's argument")
    {last, bound} = statements(body, bound, module, "child_spec/1")

    case data(last, bound, module, "child_spec/1 does not end with a map of literal data") do
      %{} = spec -> {spec, [{:child_spec, 1}]}
      _ -> no("child_spec/1 does not end with a map")
    end
  end

  defp specification(_other, _forms, _module),
    do: no("a child specification is not a map with id: and start:, or {Module, argument} with a child_spec/1 that is one")

  # The body of a start function -> {the spawn_link call, the registered name | nil}.
  defp start_body([{:__block__, _, [{{:__block__, _, [:ok]}, {_, _, args} = spawn}]}]) when is_list(args), do: {spawn, nil}

  defp start_body([{:=, _, [{var, _, c1}, spawn]}, {:__block__, _, [{{:__block__, _, [:ok]}, {var, _, c2}}]}])
       when is_atom(var) and is_atom(c1) and is_atom(c2),
       do: {spawn, nil}

  defp start_body([{:=, _, [{var, _, c1}, spawn]}, register, {:__block__, _, [{{:__block__, _, [:ok]}, {var, _, c2}}]}])
       when is_atom(var) and is_atom(c1) and is_atom(c2),
       do: {spawn, registered(register, var)}

  defp start_body(_body),
    do: no("a child's start function is not spawn_link, an optional Process.register, {:ok, pid}")

  defp registered({:=, _, [{:__block__, _, [true]}, call]}, var), do: registered(call, var)

  defp registered({{:., _, [{:__aliases__, _, [:Process]}, :register]}, _, [{var, _, context}, {:__block__, _, [name]}]}, var)
       when is_atom(context) and is_atom(name),
       do: name

  defp registered(_other, _var),
    do: no("the second statement of a child's start function is not Process.register(pid, :name)")

  # -> {the function the child runs, its arguments as written}
  defp spawned({:spawn_link, _, [module_ast, {:__block__, _, [run]}, {:__block__, _, [args]}]}, module)
       when is_atom(run) and is_list(args) do
    why = "a child's start function does not spawn_link a function of this module"
    data(module_ast, %{}, module, why) == {:module, module} or no(why)

    {run, args}
  end

  defp spawned({:spawn_link, _, [{:fn, _, [{:->, _, [[], {run, _, args}]}]}]}, _module) when is_atom(run) and is_list(args),
    do: {run, args}

  defp spawned(_other, _module), do: no("a child's start function does not spawn_link a function of this module")

  # An argument of the child's function: a literal, or a parameter of the start function (then the literal the
  # child specification gives for it). The child list is fixed when the supervisor starts: nothing else can be
  # in it.
  defp scalar({:__block__, _, [x]}, _bound) when is_number(x) or is_atom(x), do: x
  defp scalar({:-, _, [{:__block__, _, [n]}]}, _bound) when is_number(n), do: -n

  defp scalar({var, _, context}, bound) when is_atom(var) and is_atom(context) do
    case bound do
      %{^var => value} when is_number(value) or is_atom(value) -> value
      %{^var => _} -> no("an argument of a child's function is not an integer, a float or an atom")
      _ -> no("an argument of a child's function is a variable that is no parameter of its start function")
    end
  end

  defp scalar(_other, _bound), do: no("an argument of a child's function is not an integer, a float or an atom")
end
