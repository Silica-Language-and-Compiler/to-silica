defmodule E2s.Lift do
  @moduledoc """
  Elixir's `fn`, lowered by the sender BEFORE anything is split, typed or sent (quoted forms in, quoted forms
  out). The transpiler prints no closure (a Silica function literal captures only integer literals: limitation
  observed), and what a `fn` is in Elixir is this sender's business (contract 1). A `fn` that uses no variable
  of the function around it is a function of the module in all but name, so it is sent as one:

      @spec twice((integer() -> integer()), integer()) :: integer()
      def twice(f, x), do: f.(f.(x))

      @spec add_ten(integer()) :: integer()                 @spec add_ten(integer()) :: integer()
      def add_ten(n),                                        def add_ten(n), do: twice(&add_ten__f1/1, n)
        do: twice(fn x -> add(x, 5) end, n)
                                                             @spec add_ten__f1(integer()) :: integer()
                                                             defp add_ten__f1(x), do: add(x, 5)

  WHICH `fn` IS LIFTED: one written directly as an argument of a call of a function of this module whose `@spec`
  declares a function type of the fn's arity for that parameter (Elixir writes no type on a fn's parameters, so
  that `@spec` is what gives the made function its own `@spec`), and that captures nothing. Every clause of the
  fn becomes a clause of the function, with its guard.

  WHICH IS NOT, and stays a `fn` for the codex (a `(:lambda)`, H36, which the transpiler answers with a gap unless
  it is the function of a spawn): a fn that uses a variable of the function around it (a closure); a fn bound to
  a variable or returned; an argument of a piped call or of a call into another module.

  "Captures nothing" is decided by names, on the safe side: a variable of a fn clause's body or guard that is
  not in that clause's parameters, and whose name the function around the fn also uses, counts as captured.

  `forms/1` answers `{forms, lifted}`; `lifted` says for each made function what it is made from, for its sent
  name (README, N6): `{name, arity} => %{base: {name, arity}, suffix: "__f<n>"}`. The made functions are named
  `:"add_ten/1-f1"` here, a name no source function has.
  """

  defguardp is_lit(x)
            when is_number(x) or is_atom(x) or is_binary(x) or is_list(x) or (is_tuple(x) and tuple_size(x) == 2)

  @special_vars [:_, :__MODULE__, :__ENV__, :__DIR__, :__CALLER__, :__STACKTRACE__]

  @doc "The forms of a module body with every fn that can be lifted made a function of the module."
  def forms(forms) do
    specs =
      Enum.reduce(forms, %{}, fn
        {:@, _, [{:spec, _, [{:"::", _, [{fun, _, args}, _ret]}]}]}, acc when is_atom(fun) ->
          args = if is_list(args), do: args, else: []
          Map.update(acc, {fun, length(args)}, [args], &(&1 ++ [args]))

        _, acc ->
          acc
      end)

    {out, st} = Enum.flat_map_reduce(forms, %{specs: specs, counts: %{}, lifted: %{}}, &form/2)
    {out, st.lifted}
  end

  defp form({kind, meta, [head, [{{:__block__, _, [:do]} = key, body}]]} = form, st) when kind in [:def, :defp] do
    case head_key(head) do
      nil ->
        {[form], st}

      base ->
        outer = fn hole -> vars({head, hole}) end
        {body1, {made, st}} = walk(body, &outer.(replace(body, &1)), base, {[], st})
        if made == [], do: {[form], st}, else: {[{kind, meta, [head, [{key, body1}]]} | Enum.reverse(made)], st}
    end
  end

  defp form(form, st), do: {[form], st}

  defp head_key({:when, _, [call, _]}), do: head_key(call)
  defp head_key({name, _, args}) when is_atom(name), do: {name, if(is_list(args), do: length(args), else: 0)}
  defp head_key(_), do: nil

  # Walks an expression; `outer_without.(fn)` gives the variable names of the function around a fn, the fn
  # itself left out.
  defp walk({:__block__, _, [x]} = literal, _outer, _base, acc) when is_lit(x) and not is_list(x) and not is_tuple(x),
    do: {literal, acc}

  defp walk({name, meta, args}, outer, base, {made, st}) when is_atom(name) and is_list(meta) and is_list(args) do
    params =
      case st.specs[{name, length(args)}] do
        [params] -> params
        _ -> List.duplicate(nil, length(args))
      end

    {args, acc} =
      args
      |> Enum.zip(params)
      |> Enum.map_reduce({made, st}, fn {arg, param}, {made, st} = acc ->
        with {:fn, fn_meta, clauses} <- arg,
             {:ok, types, ret} <- fun_type(param),
             true <- clauses != [] and Enum.all?(clauses, &(clause_arity(&1) == length(types))),
             true <- captures(clauses, outer.(arg)) == [] do
          {made_name, st} = fresh(base, length(types), st)
          spec = {:@, fn_meta, [{:spec, fn_meta, [{:"::", fn_meta, [{made_name, fn_meta, types}, ret]}]}]}
          defs = Enum.map(clauses, &define(made_name, &1))
          # a fn inside the made function is looked at in its turn
          {defs, st} = Enum.flat_map_reduce(defs, st, &form/2)
          ref = {:&, fn_meta, [{:/, fn_meta, [{made_name, fn_meta, nil}, {:__block__, fn_meta, [length(types)]}]}]}
          {ref, {Enum.reverse([spec | defs]) ++ made, st}}
        else
          _ -> walk(arg, outer, base, acc)
        end
      end)

    {{name, meta, args}, acc}
  end

  defp walk({a, meta, args}, outer, base, acc) when is_list(meta) do
    {a, acc} = if is_tuple(a), do: walk(a, outer, base, acc), else: {a, acc}
    {args, acc} = if is_list(args), do: Enum.map_reduce(args, acc, &walk(&1, outer, base, &2)), else: {args, acc}
    {{a, meta, args}, acc}
  end

  defp walk({a, b}, outer, base, acc) do
    {a, acc} = walk(a, outer, base, acc)
    {b, acc} = walk(b, outer, base, acc)
    {{a, b}, acc}
  end

  defp walk(list, outer, base, acc) when is_list(list), do: Enum.map_reduce(list, acc, &walk(&1, outer, base, &2))
  defp walk(other, _outer, _base, acc), do: {other, acc}

  # (a, b -> r) in an @spec, as the literal encoder gives it.
  defp fun_type({:__block__, _, [[{:->, _, [args, ret]}]]}) when is_list(args), do: {:ok, args, ret}
  defp fun_type(_other), do: :no

  defp clause_arity({:->, _, [[{:when, _, args}], _body]}), do: length(args) - 1
  defp clause_arity({:->, _, [head, _body]}), do: length(head)

  defp define(name, {:->, meta, [head, body]}) do
    call =
      case head do
        [{:when, when_meta, args}] -> {:when, when_meta, [{name, meta, Enum.drop(args, -1)}, List.last(args)]}
        args -> {name, meta, args}
      end

    {:defp, meta, [call, [{{:__block__, [], [:do]}, body}]]}
  end

  # The variables of the fn's clauses that the function around it may give a value.
  defp captures(clauses, outer) do
    Enum.flat_map(clauses, fn {:->, _, [head, body]} ->
      {params, guard} =
        case head do
          [{:when, _, args}] -> {Enum.drop(args, -1), List.last(args)}
          args -> {args, nil}
        end

      (vars({guard, body}) -- vars(params)) |> Enum.filter(&(&1 in outer))
    end)
  end

  defp vars(ast) do
    {_, names} =
      Macro.prewalk(ast, [], fn
        {name, meta, context} = node, acc when is_atom(name) and is_list(meta) and is_atom(context) and name not in @special_vars ->
          {node, [name | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(names)
  end

  # The expression with one sub-expression (the fn, by identity of its meta and shape) taken out.
  defp replace(ast, hole) do
    Macro.prewalk(ast, fn
      ^hole -> nil
      node -> node
    end)
  end

  defp fresh({name, arity} = base, fn_arity, st) do
    n = Map.get(st.counts, base, 0) + 1
    made = :"#{name}/#{arity}-f#{n}"
    {made, %{st | counts: Map.put(st.counts, base, n), lifted: Map.put(st.lifted, {made, fn_arity}, %{base: base, suffix: "__f#{n}"})}}
  end
end
