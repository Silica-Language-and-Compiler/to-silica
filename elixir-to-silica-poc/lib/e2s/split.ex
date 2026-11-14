defmodule E2s.Split do
  @moduledoc """
  Elixir's process semantics, lowered by the sender BEFORE anything is typed or sent (quoted forms in, quoted
  forms out). The transpiler prints what it is told: it writes a receive only in tail position of its function
  (contract T9.13, T9.13a) and knows nothing of what Elixir does around one. What Elixir does is this sender's
  business, exactly as every type is (contract 8.6):

      code before a receive      runs once, in the new process, when it starts          -> stays where it is
      code after a receive       runs in the same process, with the variables it had    -> a CONTINUATION function
      several receives           one after the other in the same process                -> one continuation for each
      a call of a function that  the caller goes on with its value when it returns      -> a COPY of the callee whose
      receives, not in tail pos.                                                           every end calls the continuation
      such a call, or a receive, Elixir evaluates it before the call around it          -> bound to a variable first,
      as an argument                                                                       then cut as above
      trap_exit + spawn_link     the parent receives {:EXIT, child, reason}             -> a LINKED COPY of the child's
                                                                                           function that sends it

  So after this pass every receive, and every call of a function that receives, stands in tail position, and the
  codex (`E2s.Codex`) sends the pieces as ordinary functions with the contract's high-level nodes. The variables
  that are live across the cut are the parameters of the continuation.

      def main do                                        def main do
        spawn(Actors, :supervisor, [self()])               spawn(Actors, :supervisor, [self()])
        account = receive do                               receive do
          {:account, pid} when is_pid(pid) -> pid            {:account, pid} when is_pid(pid) -> main__k1(pid)
        end                                                end
        send(account, {:deposit, 40})                    end
        IO.inspect(withdraw_from(account, 100))          defp main__k1(account) do
        ...                                                send(account, {:deposit, 40})
                                                           withdraw_from__c1(account, 100, account)
                                                         end
                                                         defp withdraw_from__c1(account, amount, e2s_k2) do
                                                           send(account, {:withdraw, amount, self()})
                                                           withdraw_from__c1__k1(e2s_k2)     # keeps only e2s_k2
                                                         end
                                                         defp withdraw_from__c1__k1(e2s_k2) do
                                                           receive do
                                                             {:withdrawn, b} when is_integer(b) -> main__k2(e2s_k2, {:ok, b})
                                                             ...
                                                         defp main__k2(account, e2s_h1) do
                                                           IO.inspect(e2s_h1)
                                                           ...

  What this pass makes is Elixir: compiled in place of the module it behaves as the module does (the test "the
  split forms of examples/actors.ex run as Elixir" holds it to that; `to_elixir/1` gives the forms the compiler
  takes). The made functions are named `:"main/0-k1"` here and sent as `main__k1` (README, N6).

  `forms/2` answers `{forms, gen}`. `gen` says, for each function this pass made, what it is made from:

      {name, arity} => %{base: {name, arity},    the function (or made function) it continues or copies
                         suffix: binary,          what the codex appends to the base's sent name: __k1, __c1, __l
                         result: {name, arity},   the source function whose @spec result is this function's result
                         what: binary}            for diagnostics

  A made function has no `@spec`: the codex takes its parameter types from the calls of it (`E2s.Codex`,
  "made functions").

  Elixir's own rules that this pass keeps: a variable may be bound again, so the value of `x = receive … end` is
  the continuation's parameter `x` whatever `x` was before; a binding made inside a clause of `case`, `cond`,
  `if` or `receive` ends with the clause, so only what is bound at the top of the function body is passed on; a
  pinned variable is a use.

  WHAT IS NOT ELIXIR'S BEHAVIOUR (README, "Processes: what this sender splits"):
    * a receive, or a call of a function that receives, inside an expression is bound first only when everything
      Elixir evaluates before it is a variable or a literal (an argument after other calls, an operand of `&&`,
      a struct field, a list element are not): otherwise it becomes this sender's own gap;
    * the linked copy tells the parent only of an end the source writes: a value (reason :normal) or `exit(atom)`
      in tail position. A failure the runtime raises sends nothing, the link's other direction (the parent ends,
      so the child ends) is not kept, and neither is an exit request's reason.
  """

  defguardp is_lit(x)
            when is_number(x) or is_atom(x) or is_binary(x) or is_list(x) or (is_tuple(x) and tuple_size(x) == 2)

  @special_vars [:_, :__MODULE__, :__ENV__, :__DIR__, :__CALLER__, :__STACKTRACE__]

  # Forms whose arguments Elixir does not simply evaluate left to right before the form itself.
  @no_hoist [:fn, :receive, :case, :cond, :if, :unless, :__block__, :=, :&, :^, :|>, :and, :or, :&&, :||, :for,
             :with, :try, :quote, :unquote, :%, :%{}, :<<>>, :., :__aliases__, :when, :->, :"::", :@, :\\]

  @gap "$e2s_gap"

  @doc "The name of the call this pass writes for a construct it does not cut; the codex sends it as a gap."
  def gap_call, do: String.to_atom(@gap)

  @doc """
  The forms of a module body (as `Code.string_to_quoted/2` gives them with the codex's literal encoder) with
  every receive in tail position, and what each made function is made from. `module` is the module's full name.
  """
  def forms(forms, module) do
    indexed = Enum.with_index(forms)
    parsed = for {form, i} <- indexed, {:ok, key, clause} <- [parse(form)], do: {i, key, clause}
    keys = parsed |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    st0 = %{module: module, funs: %{}, blocking: MapSet.new(), counts: %{}, gen: %{}, out: [], copies: %{},
            used: MapSet.new(collect(forms, [])), cur: nil, idx: 0, tight: false}

    {parsed1, st1} =
      Enum.map_reduce(parsed, st0, fn {i, key, clause}, st ->
        {clause, st} = literals(%{clause | body: unpipe(clause.body)}, st)
        {{i, key, clause}, st}
      end)

    {parsed2, {linked, st2}} =
      Enum.map_reduce(parsed1, {[], %{st1 | funs: group(parsed1)}}, fn {i, key, clause}, acc ->
        {clause, acc} = trap(clause, acc)
        {{i, key, clause}, acc}
      end)

    funs = group(parsed2)
    st3 = %{st2 | funs: funs}
    st4 = %{st3 | blocking: blocking(funs, st3)}

    {groups, st5} = Enum.map_reduce(keys, st4, fn key, st -> split_function(key, Map.fetch!(funs, key), key in linked, st) end)
    by_key = Map.new(Enum.zip(keys, groups))
    original = Map.new(parsed, fn {i, _key, clause} -> {i, clause} end)

    # Where each clause of each function stands: its form's index -> {key, which clause, is it the last}.
    places =
      parsed
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
      |> Enum.flat_map(fn {key, is} -> for {i, n} <- Enum.with_index(is), do: {i, {key, n, n == length(is) - 1}} end)
      |> Map.new()

    out =
      Enum.flat_map(indexed, fn {form, i} ->
        case places do
          %{^i => {key, n, last}} ->
            {clauses, made} = Map.fetch!(by_key, key)
            clause = Enum.at(clauses, n)
            # A function this pass did not touch is sent as it was parsed.
            [if(clause == Map.fetch!(original, i), do: form, else: build(elem(key, 0), clause))] ++ if(last, do: made, else: [])

          _ ->
            [form]
        end
      end)

    {out, st5.gen}
  end

  @doc """
  Forms in the shape Elixir's compiler takes: the literal encoder's wrapping (`{:__block__, meta, [literal]}`)
  taken off. `Macro.to_string/1` of the result is the split module as source.
  """
  def to_elixir({:__block__, _, [x]}) when is_lit(x), do: plain_literal(x)
  def to_elixir({a, meta, args}) when is_list(meta), do: {to_elixir(a), meta, to_elixir(args)}
  def to_elixir({a, b}), do: {to_elixir(a), to_elixir(b)}
  def to_elixir(list) when is_list(list), do: Enum.map(list, &to_elixir/1)
  def to_elixir(other), do: other

  defp plain_literal(list) when is_list(list), do: Enum.map(list, &to_elixir/1)
  defp plain_literal({a, b}), do: {to_elixir(a), to_elixir(b)}
  defp plain_literal(x), do: x

  # ------------------------------------------------------------------ functions as clauses

  # def/defp with literal parameters and a plain `do` body: {:ok, {name, arity}, clause}. Anything else (default
  # arguments, rescue/after, a computed name) is left as it is; the codex sends it as a gap.
  defp parse({kind, meta, [head, body]}) when kind in [:def, :defp] do
    {call, guard, when_meta} =
      case head do
        {:when, when_meta, [call, guard]} -> {call, guard, when_meta}
        call -> {call, nil, []}
      end

    with {name, head_meta, args} when is_atom(name) and (is_list(args) or is_atom(args)) <- call,
         args = if(is_list(args), do: args, else: []),
         false <- Enum.any?(args, &match?({:\\, _, _}, &1)),
         [do: expr] <- kw(body) do
      {:ok, {name, length(args)},
       %{kind: kind, meta: meta, head_meta: head_meta, when_meta: when_meta, args: args, guard: guard, body: expr}}
    else
      _ -> :error
    end
  end

  defp parse(_form), do: :error

  defp build(name, %{kind: kind, meta: meta, head_meta: head_meta, when_meta: when_meta, args: args, guard: guard, body: body}) do
    call = {name, head_meta, args}
    head = if guard == nil, do: call, else: {:when, when_meta, [call, guard]}
    {kind, meta, [head, [{{:__block__, [], [:do]}, body}]]}
  end

  defp group(parsed), do: Enum.reduce(parsed, %{}, fn {_i, key, clause}, acc -> Map.update(acc, key, [clause], &(&1 ++ [clause])) end)

  # One source function: its clauses, and the forms of the functions made while it was split.
  defp split_function(key, clauses, linked, st0) do
    st1 = %{st0 | out: [], cur: key, tight: false}

    {clauses1, st2} =
      if MapSet.member?(st1.blocking, key) do
        Enum.map_reduce(clauses, st1, fn clause, st ->
          {body, st} = split_body(stmts(clause.body), pvars(clause.args), st)
          {%{clause | body: block(body)}, st}
        end)
      else
        {clauses, st1}
      end

    st3 = if linked, do: elem(copy(key, {:notify, nil}, st2), 1), else: st2
    {{clauses1, st3.out |> Enum.sort() |> Enum.map(&elem(&1, 1))}, st3}
  end

  # ------------------------------------------------------------------ which functions receive

  # A function BLOCKS when it holds a receive, or calls (outside a fn) a function of the module that blocks.
  defp blocking(funs, st) do
    first = for {key, clauses} <- funs, blocks?(Enum.map(clauses, & &1.body), st), into: MapSet.new(), do: key
    blocking(funs, st, first)
  end

  defp blocking(funs, st, set) do
    st = %{st | blocking: set}
    next = for {key, clauses} <- funs, blocks?(Enum.map(clauses, & &1.body), st), into: MapSet.new(), do: key
    if MapSet.size(next) == MapSet.size(set), do: set, else: blocking(funs, st, next)
  end

  # Does this expression (or list of them) wait for a message somewhere inside it? A fn's body runs when the fn
  # is called, which is not here.
  defp blocks?({:receive, _, _}, _st), do: true
  defp blocks?({:fn, _, _}, _st), do: false
  defp blocks?({:&, _, _}, _st), do: false

  defp blocks?({a, meta, args} = ast, st) when is_list(meta),
    do: blocking_call?(ast, st) or (is_tuple(a) and blocks?(a, st)) or (is_list(args) and blocks?(args, st))

  defp blocks?({a, b}, st), do: blocks?(a, st) or blocks?(b, st)
  defp blocks?(list, st) when is_list(list), do: Enum.any?(list, &blocks?(&1, st))
  defp blocks?(_other, _st), do: false

  defp blocking_call?(call, st) do
    case callee(call, st) do
      {:ok, key} -> MapSet.member?(st.blocking, key)
      :no -> false
    end
  end

  # The function of this module a call names: {:ok, {name, arity}} | :no.
  defp callee({name, meta, args}, st) when is_atom(name) and is_list(meta) and is_list(args),
    do: if(is_map_key(st.funs, {name, length(args)}), do: {:ok, {name, length(args)}}, else: :no)

  defp callee({{:., _, [module, name]}, _, args}, st) when is_atom(name) and is_list(args),
    do: if(own_module?(module, st) and is_map_key(st.funs, {name, length(args)}), do: {:ok, {name, length(args)}}, else: :no)

  defp callee(_other, _st), do: :no

  defp own_module?({:__MODULE__, _, context}, _st) when is_atom(context), do: true
  defp own_module?({:__aliases__, _, parts}, st), do: Enum.all?(parts, &is_atom/1) and Enum.join(parts, ".") == st.module
  defp own_module?(_other, _st), do: false

  # ------------------------------------------------------------------ the cut

  # A body whose last expression is in tail position of its function. `bound`: the variables that have a value
  # when the body starts. The first statement that waits is where the function is cut: the statements after it
  # become a continuation function, and the statement becomes the body's last expression.
  defp split_body([e], bound, st), do: split_tail(e, bound, st)

  defp split_body([e | rest], bound, st) do
    cond do
      not blocks?(e, st) -> keep(e, rest, bound, st)
      shape = shape(e, st) -> cut(elem(shape, 0), elem(shape, 1), rest, bound, st)
      true -> hoist_or_gap(e, rest, bound, st)
    end
  end

  defp keep(e, rest, bound, st) do
    {rest, st} = split_body(rest, bound ++ binders(e), st)
    {[e | rest], st}
  end

  # A statement that waits and is not `p = b` or `b` with b something that can be cut: the part that waits is
  # bound to a variable first, when Elixir evaluates nothing but variables and literals before it; otherwise the
  # statement is this sender's gap.
  defp hoist_or_gap(e, rest, bound, st) do
    case hoist(e, st) do
      {:ok, before, e, st} -> split_body(before ++ [e | rest], bound, st)
      :no when rest == [] -> {[unsplit(e, st)], st}
      :no -> keep(unsplit(e, st), rest, bound, st)
    end
  end

  # What can be cut: `p = b` or `b` alone, where b waits and its value is the value of its own tail positions.
  defp shape({:=, _, [p, b]}, st), do: if(not blocks?(p, st) and cuttable?(b, st), do: {p, b})
  defp shape(b, st), do: if(cuttable?(b, st), do: {nil, b})

  defp cuttable?({:receive, _, [_]} = e, st), do: not blocks?(timeout(e), st)
  defp cuttable?({:case, _, [subject, body]}, st), do: not blocks?(subject, st) and not heads_block?(body, st)
  defp cuttable?({:cond, _, [body]}, st), do: not heads_block?(body, st)
  defp cuttable?({:if, _, [condition, _]}, st), do: not blocks?(condition, st)
  defp cuttable?({:__block__, _, [x]}, _st) when is_lit(x), do: false
  defp cuttable?({:__block__, _, [_ | _]}, _st), do: true
  defp cuttable?({_, _, args} = call, st) when is_list(args), do: blocking_call?(call, st) and not blocks?(args, st)
  defp cuttable?(_other, _st), do: false

  defp timeout({:receive, _, [body]}) do
    case kw(body) do
      :error -> nil
      kws -> with [{:->, _, [[timeout], _]}] <- Keyword.get(kws, :after), do: timeout, else: (_ -> nil)
    end
  end

  # A clause head (a guard, a cond's condition) that waits: nothing this pass cuts.
  defp heads_block?(body, st) do
    case kw(body) do
      :error -> true
      kws ->
        Enum.any?(List.wrap(Keyword.get(kws, :do, [])), fn
          {:->, _, [head, _body]} -> blocks?(head, st)
          _other -> true
        end)
    end
  end

  # The last expression of a body: nothing of the function runs after it, so a receive may stand here. Its own
  # bodies are bodies in tail position too.
  defp split_tail(e, bound, st) do
    cond do
      not blocks?(e, st) ->
        {[e], st}

      match?({:receive, _, [_]}, e) and cuttable?(e, st) ->
        # The state a waiting process keeps is the sender's business too: the transpiler keeps every variable
        # that has a value at the receive. In a piece this pass made, a receive that does not use all of them
        # is put in a function of its own, whose parameters are the variables it does use.
        used = vars(e)
        all = Enum.uniq(bound)
        live = Enum.filter(all, &(&1 in used))

        if st.tight and length(live) < length(all) do
          meta = meta(e)
          {name, st} = new_name(st.cur, "k", length(live), "the receive of #{fa(st.cur)} at line #{line(meta)}", st)
          {body, st} = tail_bodies(e, live, st)
          params = Enum.map(live, &var(&1, meta))
          {[{name, meta, params}], push(name, length(live), defp_form(name, meta, params, body), st)}
        else
          tail_bodies(e, bound, st)
        end

      match?({tag, _, _} when tag in [:case, :cond, :if, :__block__], e) and cuttable?(e, st) ->
        tail_bodies(e, bound, st)

      match?({:=, _, [_, _]}, e) ->
        case shape(e, st) do
          {p, b} -> cut(p, b, [], bound, st)
          nil -> hoist_or_gap(e, [], bound, st)
        end

      # a tail call of a function that receives is what the contract asks for (T9.13)
      cuttable?(e, st) ->
        {[e], st}

      true ->
        hoist_or_gap(e, [], bound, st)
    end
  end

  defp tail_bodies(e, bound, st) do
    {:ok, e, st} = tails(e, st, fn body, bound_here, st -> split_body(body, bound ++ bound_here, st) end)
    {[e], st}
  end

  # `p = b; rest` (p nil: `b; rest`): b becomes the last expression, every value b can have is passed to the
  # continuation k, and k is `k(live..., value) do p = value; rest end`. Live: the variables rest uses that have
  # a value where b ends. In Elixir nothing bound inside b is visible after it, and `x = b` binds x whatever x
  # was before, so the value is the parameter x itself.
  defp cut(p, b, rest, bound, st0) do
    meta = meta(b)

    {value, kbody, st1} =
      case p do
        nil ->
          {nil, rest, st0}

        {:_, _, context} when is_atom(context) and rest != [] ->
          {nil, rest, st0}

        {name, _, context} when is_atom(name) and is_atom(context) and name not in @special_vars ->
          {name, if(rest == [], do: [p], else: rest), st0}

        _pattern ->
          {v, st} = fresh("v", st0)
          {v, [{:=, meta, [p, var(v, meta)]} | rest], st}
      end

    in_k = vars(kbody)
    live = for v <- Enum.uniq(bound), v in in_k, v != value, do: v
    params = live ++ if(value, do: [value], else: [])
    {name, st2} = new_name(st1.cur, "k", length(params), "the code of #{fa(st1.cur)} after line #{line(meta)}", st1)
    k = {:cont, name, Enum.map(live, &var(&1, meta)), value != nil}
    {b1, st3} = wrap_last(b, k, st2)
    {b2, st4} = split_body(b1, bound, st3)
    {kbody1, st5} = split_body(kbody, params, %{st4 | tight: true})
    form = defp_form(name, meta, Enum.map(params, &var(&1, meta)), kbody1)
    {b2, push(name, length(params), form, %{st5 | tight: st4.tight})}
  end

  # A receive this pass does not cut: it stands inside an expression. It is sent as this sender's own gap.
  defp unsplit(e, _st) do
    meta = meta(e)
    what = if has_receive?(e), do: "receive inside an expression", else: "call of a function that receives, inside an expression"

    note =
      "this sender cuts a function at a receive, or at a call of a function that receives, that is a statement, " <>
        "the right side of =, a case subject, or an argument evaluated after nothing but variables and literals " <>
        "(contract T9.13a): bind its value to a variable with = first"

    {gap_call(), meta, [lit(what, meta), lit(note, meta)]}
  end

  defp has_receive?({:receive, _, _}), do: true
  defp has_receive?({:fn, _, _}), do: false
  defp has_receive?({a, meta, args}) when is_list(meta), do: has_receive?(a) or has_receive?(args)
  defp has_receive?({a, b}), do: has_receive?(a) or has_receive?(b)
  defp has_receive?(list) when is_list(list), do: Enum.any?(list, &has_receive?/1)
  defp has_receive?(_other), do: false

  # ------------------------------------------------------------------ binding a waiting argument first

  # {:ok, statements to put before, the expression without the part that waits, st} | :no
  defp hoist({:=, m, [p, v]}, st) do
    with {:ok, before, v, st} <- lift(v, st), do: {:ok, before, {:=, m, [p, v]}, st}
  end

  defp hoist({tag, m, [first, body]}, st) when tag in [:case, :if] do
    if blocks?(first, st) do
      with {:ok, before, first, st} <- lift(first, st), do: {:ok, before, {tag, m, [first, body]}, st}
    else
      :no
    end
  end

  # a two-element tuple, as the literal encoder writes it
  defp hoist({:__block__, m, [{a, b}]}, st) do
    with {:ok, before, [a, b], st} <- hoist_args([a, b], st), do: {:ok, before, {:__block__, m, [{a, b}]}, st}
  end

  defp hoist({f, m, args}, st) when is_atom(f) and f not in @no_hoist and is_list(m) and is_list(args) do
    with {:ok, before, args, st} <- hoist_args(args, st), do: {:ok, before, {f, m, args}, st}
  end

  defp hoist({{:., _, [left, name]} = f, m, args}, st) when is_atom(name) and is_list(args) do
    if blocks?(left, st) do
      :no
    else
      with {:ok, before, args, st} <- hoist_args(args, st), do: {:ok, before, {f, m, args}, st}
    end
  end

  defp hoist(_other, _st), do: :no

  defp hoist_args(args, st) do
    case Enum.split_while(args, &(not blocks?(&1, st))) do
      {before, [x | rest]} ->
        if Enum.all?(before, &simple?/1) do
          with {:ok, statements, x, st} <- lift(x, st), do: {:ok, statements, before ++ [x | rest], st}
        else
          :no
        end

      _ ->
        :no
    end
  end

  defp lift(x, st) do
    if cuttable?(x, st) do
      {v, st} = fresh("h", st)
      meta = meta(x)
      {:ok, [{:=, meta, [var(v, meta), x]}], var(v, meta), st}
    else
      hoist(x, st)
    end
  end

  # ------------------------------------------------------------------ passing a value on

  # The expression e is the last of a body; k says what happens with its value:
  #   {:cont, name, args, true}    name(args..., value)          a continuation that uses the value
  #   {:cont, name, args, false}   value; name(args...)          a continuation that does not
  #   {:notify, parent}            send(parent, {:EXIT, self(), :normal}); value     the end of a linked child
  # Answers the expressions that take e's place.
  defp wrap_last(e, k, st) do
    e = with {:if, m, [c, body]} <- e, do: {:if, m, [c, with_else(body, meta(e))]}

    case tails(e, st, fn body, _bound, st -> wrap_body(body, k, st) end) do
      {:ok, e, st} ->
        {[e], st}

      :no ->
        cond do
          match?({_, _, args} when is_list(args), e) and blocking_call?(e, st) and not blocks?(elem(e, 2), st) ->
            # the callee receives: a copy of it goes on in k when it ends
            {:ok, key} = callee(e, st)
            {name, st} = copy(key, k, st)
            {[{name, meta(e), elem(e, 2) ++ kargs(k)}], st}

          fail_call?(e) ->
            {failing(e, k), st}

          true ->
            value(e, k, st)
        end
    end
  end

  defp wrap_body(body, k, st) do
    {last, st} = wrap_last(List.last(body), k, st)
    {Enum.drop(body, -1) ++ last, st}
  end

  defp kargs({:cont, _, args, _}), do: args
  defp kargs({:notify, parent}), do: [parent]

  defp value(e, {:cont, name, args, true}, st), do: {[{name, meta(e), args ++ [e]}], st}

  defp value(e, {:cont, name, args, false}, st) do
    call = {name, meta(e), args}
    {if(simple?(e), do: [call], else: [e, call]), st}
  end

  defp value(e, {:notify, parent}, st) do
    meta = meta(e)
    send = exit_message(meta, parent, lit(:normal, meta))

    if simple?(e) do
      {[send, e], st}
    else
      {v, st} = fresh("r", st)
      {[{:=, meta, [var(v, meta), e]}, send, var(v, meta)], st}
    end
  end

  # exit(reason), raise, throw: the process ends here, no continuation runs. A linked child tells its parent the
  # reason when it is written as an atom.
  defp failing({_, meta, [{:__block__, _, [reason]} = r]} = e, {:notify, parent}) when is_atom(reason),
    do: [exit_message(meta, parent, r), e]

  defp failing(e, _k), do: [e]

  defp fail_call?({name, _, [_ | _]}) when name in [:exit, :raise, :reraise, :throw], do: true
  defp fail_call?({{:., _, [{:__block__, _, [:erlang]}, name]}, _, [_]}) when name in [:exit, :error, :throw], do: true
  defp fail_call?({{:., _, [{:__aliases__, _, [:Kernel]}, name]}, _, [_ | _]}) when name in [:exit, :raise, :throw], do: true
  defp fail_call?(_other), do: false

  defp exit_message(meta, parent, reason),
    do: {:send, meta, [parent, {:{}, meta, [lit(:EXIT, meta), {:self, meta, []}, reason]}]}

  defp simple?({:__block__, _, [x]}) when is_number(x) or is_atom(x) or is_binary(x), do: true
  defp simple?({name, _, context}) when is_atom(name) and is_atom(context), do: true
  defp simple?(_other), do: false

  # ------------------------------------------------------------------ copies

  # The copy of the function `key` whose every end goes on as k says. Its extra parameters carry what k needs
  # (the continuation's live variables, or the parent of a linked child). One copy for each (function, k): a
  # function that loops calls its own copy.
  defp copy({_g, n} = key, k, st0) do
    memo = {key, with({:cont, kname, _, _} <- k, do: kname, else: (_ -> :notify))}

    case st0.copies do
      %{^memo => name} ->
        {name, st0}

      _ ->
        {extra, st1} = Enum.map_reduce(kargs(k), st0, fn _, st -> fresh("k", st) end)
        arity = n + length(extra)

        {name, st2} =
          case k do
            {:cont, kname, _, _} -> new_name(key, "c", arity, "#{fa(key)} going on in #{what(kname, st1)}", st1)
            {:notify, _} -> {linked_name(key), linked_gen(key, st1)}
          end

        st3 = %{st2 | copies: Map.put(st2.copies, memo, name)}

        {clauses, st4} =
          Enum.map_reduce(Map.fetch!(st3.funs, key), %{st3 | cur: {name, arity}, tight: true}, fn clause, st ->
            extra_vars = Enum.map(extra, &var(&1, clause.head_meta))

            k1 =
              case k do
                {:cont, kname, _, uses} -> {:cont, kname, extra_vars, uses}
                {:notify, _} -> {:notify, hd(extra_vars)}
              end

            {b1, st} = wrap_body(stmts(clause.body), k1, st)
            {b2, st} = split_body(b1, pvars(clause.args) ++ extra, st)
            {build(name, %{clause | kind: :defp, args: clause.args ++ extra_vars, body: block(b2)}), st}
          end)

        {name, push(name, arity, clauses, %{st4 | cur: st3.cur, tight: st3.tight})}
    end
  end

  defp linked_name({g, n}), do: String.to_atom("#{g}/#{n}-l")

  defp linked_gen({_, n} = key, st) do
    info = %{base: key, suffix: "__l", result: key, idx: st.idx,
             what: "#{fa(key)} as a linked child (it sends its parent {:EXIT, self(), reason} when it ends)"}

    %{st | idx: st.idx + 1, gen: Map.put(st.gen, {linked_name(key), n + 1}, info)}
  end

  # ------------------------------------------------------------------ names

  defp new_name({n, ar} = base, letter, arity, what, st) do
    count = Map.get(st.counts, {base, letter}, 0) + 1
    name = String.to_atom("#{n}/#{ar}-#{letter}#{count}")
    # the result is the @spec result of the source function all this is cut from: for a copy, the one its
    # continuation belongs to
    from = if letter == "c", do: st.cur, else: base

    result =
      case st.gen do
        %{^from => %{result: result}} -> result
        _ -> from
      end

    info = %{base: base, suffix: "__#{letter}#{count}", result: result, idx: st.idx, what: what}
    {name, %{st | counts: Map.put(st.counts, {base, letter}, count), gen: Map.put(st.gen, {name, arity}, info), idx: st.idx + 1}}
  end

  # A made function's forms take their place by the order in which the functions were named.
  defp push(name, arity, forms, st) do
    %{idx: i} = Map.fetch!(st.gen, {name, arity})
    forms = List.wrap(forms)
    %{st | out: (for {form, j} <- Enum.with_index(forms), do: {{i, j}, form}) ++ st.out}
  end

  defp defp_form(name, meta, params, body),
    do: {:defp, meta, [{name, meta, params}, [{{:__block__, [], [:do]}, block(body)}]]}

  defp what(name, st) do
    case for({{n, _}, %{what: what}} <- st.gen, n == name, do: what) do
      [what | _] -> what
      [] -> Atom.to_string(name)
    end
  end

  defp fa({n, a}), do: "#{n}/#{a}"
  defp line(meta), do: Keyword.get(meta, :line, 0)

  # A variable of this pass: e2s_<letter><n>, a name no variable of the module has.
  defp fresh(letter, st, n \\ 1) do
    v = String.to_atom("e2s_#{letter}#{n}")
    if MapSet.member?(st.used, v), do: fresh(letter, st, n + 1), else: {v, %{st | used: MapSet.put(st.used, v)}}
  end

  # ------------------------------------------------------------------ the quoted forms

  defp var(name, meta), do: {name, Keyword.take(meta, [:line, :column]), nil}
  defp lit(x, meta), do: {:__block__, Keyword.take(meta, [:line, :column]), [x]}

  defp meta({_, meta, _}) when is_list(meta), do: Keyword.take(meta, [:line, :column])
  defp meta(_other), do: []

  # The statements of a body, and a body of statements.
  defp stmts({:__block__, _, [x]} = literal) when is_lit(x), do: [literal]
  defp stmts({:__block__, meta, []}), do: [lit(nil, meta)]
  defp stmts({:__block__, _, list}), do: list
  defp stmts(e), do: [e]

  defp block([one]), do: one
  defp block(many), do: {:__block__, [], many}

  # Every variable that occurs in a term, in order of first occurrence.
  defp vars(ast), do: ast |> collect([]) |> Enum.reverse() |> Enum.uniq()

  defp collect({name, meta, context}, acc) when is_atom(name) and is_atom(context) and is_list(meta),
    do: if(name in @special_vars, do: acc, else: [name | acc])

  defp collect({a, meta, args}, acc) when is_list(meta), do: collect(args, if(is_tuple(a), do: collect(a, acc), else: acc))
  defp collect({a, b}, acc), do: collect(b, collect(a, acc))
  defp collect(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect/2)
  defp collect(_other, acc), do: acc

  # The variables a pattern binds: a pinned variable is a use, not a binding.
  defp pvars(ast), do: ast |> unpinned() |> vars()

  defp unpinned({:^, _, [_]}), do: nil
  defp unpinned(ast), do: descend(ast, &unpinned/1)

  # The variables a statement leaves bound for the statements after it: those of its `=` patterns. What is
  # bound inside a clause of case, cond, if, receive or fn ends with the clause.
  defp binders({:=, _, [p, v]}), do: pvars(p) ++ binders(v)
  defp binders({:case, _, [subject, _]}), do: binders(subject)
  defp binders({tag, _, _}) when tag in [:receive, :cond, :if, :unless, :fn, :for, :with, :try, :&, :quote], do: []
  defp binders({:__block__, _, [x]}) when is_lit(x) and not is_tuple(x), do: []
  defp binders({a, meta, args}) when is_list(meta), do: if(is_tuple(a), do: binders(a), else: []) ++ binders(args)
  defp binders({a, b}), do: binders(a) ++ binders(b)
  defp binders(list) when is_list(list), do: Enum.flat_map(list, &binders/1)
  defp binders(_other), do: []

  defp descend({a, meta, args}, f) when is_list(meta),
    do: {if(is_tuple(a), do: f.(a), else: a), meta, if(is_list(args), do: Enum.map(args, f), else: args)}

  defp descend({a, b}, f), do: {f.(a), f.(b)}
  defp descend(list, f) when is_list(list), do: Enum.map(list, f)
  defp descend(other, _f), do: other

  defp descend({a, meta, args}, acc, f) when is_list(meta) do
    {a, acc} = if is_tuple(a), do: f.(a, acc), else: {a, acc}
    {args, acc} = if is_list(args), do: Enum.map_reduce(args, acc, f), else: {args, acc}
    {{a, meta, args}, acc}
  end

  defp descend({a, b}, acc, f) do
    {a, acc} = f.(a, acc)
    {b, acc} = f.(b, acc)
    {{a, b}, acc}
  end

  defp descend(list, acc, f) when is_list(list), do: Enum.map_reduce(list, acc, f)
  defp descend(other, acc, _f), do: {other, acc}

  # a |> f(b) is f(a, b), as the codex reads it: the call that waits is then the one that is written last.
  defp unpipe({:|>, _, [left, right]} = ast) do
    piped =
      try do
        {:ok, Macro.pipe(unpipe(left), right, 0)}
      rescue
        ArgumentError -> :error
      end

    case piped do
      {:ok, {f, meta, args}} -> {f, meta, Enum.map(args, &unpipe/1)}
      :error -> descend(ast, &unpipe/1)
    end
  end

  defp unpipe(ast), do: descend(ast, &unpipe/1)

  # The bodies in tail position of a control construct: `fun.(statements, variables its clause binds, st)` gives
  # the statements that take each body's place. {:ok, construct, st} | :no for anything else.
  defp tails({:receive, m, [body]}, st, fun) do
    {body, st} =
      kw_map(body, st, fn
        :do, clauses, st when is_list(clauses) ->
          Enum.map_reduce(clauses, st, &arrow_tail(&1, &2, fun))

        :after, [{:->, am, [[timeout], after_body]}], st ->
          {b, st} = fun.(stmts(after_body), [], st)
          {[{:->, am, [[timeout], block(b)]}], st}

        _key, value, st ->
          {value, st}
      end)

    {:ok, {:receive, m, [body]}, st}
  end

  defp tails({:case, m, [subject, body]}, st, fun) do
    {body, st} = kw_map(body, st, &clauses_tail(&1, &2, &3, fun))
    {:ok, {:case, m, [subject, body]}, st}
  end

  defp tails({:cond, m, [body]}, st, fun) do
    {body, st} = kw_map(body, st, &clauses_tail(&1, &2, &3, fun))
    {:ok, {:cond, m, [body]}, st}
  end

  defp tails({:if, m, [condition, body]}, st, fun) do
    {body, st} =
      kw_map(body, st, fn _key, value, st ->
        {b, st} = fun.(stmts(value), [], st)
        {block(b), st}
      end)

    {:ok, {:if, m, [condition, body]}, st}
  end

  defp tails({:__block__, _, [x]}, _st, _fun) when is_lit(x), do: :no

  defp tails({:__block__, m, [_ | _] = many}, st, fun) do
    {b, st} = fun.(many, [], st)
    {:ok, {:__block__, m, b}, st}
  end

  defp tails(_other, _st, _fun), do: :no

  defp clauses_tail(:do, clauses, st, fun) when is_list(clauses), do: Enum.map_reduce(clauses, st, &arrow_tail(&1, &2, fun))
  defp clauses_tail(_key, value, st, _fun), do: {value, st}

  defp arrow_tail({:->, m, [head, body]}, st, fun) do
    {b, st} = fun.(stmts(body), head_vars(head), st)
    {{:->, m, [head, block(b)]}, st}
  end

  defp arrow_tail(other, st, _fun), do: {other, st}

  defp head_vars([{:when, _, args}]), do: pvars(Enum.drop(args, -1))
  defp head_vars(patterns), do: pvars(patterns)

  # `if c do a end` has the value nil when c does not hold.
  defp with_else(body, meta) do
    case kw(body) do
      [do: _] ->
        pair = {{:__block__, [], [:else]}, lit(nil, meta)}

        case body do
          {:__block__, m, [list]} -> {:__block__, m, [list ++ [pair]]}
          list -> list ++ [pair]
        end

      _ ->
        body
    end
  end

  # A keyword list as the parser writes it with the literal encoder (keys are wrapped atoms; `do: x` after a
  # comma is itself wrapped), each value replaced by `fun.(key, value, st)`.
  defp kw_map({:__block__, m, [list]}, st, fun) when is_list(list) do
    {list, st} = kw_map(list, st, fun)
    {{:__block__, m, [list]}, st}
  end

  defp kw_map(list, st, fun) when is_list(list) do
    Enum.map_reduce(list, st, fn
      {{:__block__, _, [key]} = k, value}, st when is_atom(key) ->
        {value, st} = fun.(key, value, st)
        {{k, value}, st}

      other, st ->
        {other, st}
    end)
  end

  defp kw_map(other, st, _fun), do: {other, st}

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

  defp kw(_other), do: :error

  # ------------------------------------------------------------------ trapping exits

  # Process.flag(:trap_exit, true) as a statement of a function body, and after it in that body:
  #   spawn_link(fn -> g(args) end)       -> (e2s_s1 = self(); spawn(fn -> g__l(args, e2s_s1) end))
  #   spawn_link(Mod, :g, [args])            (the parent is bound first; the arguments are evaluated by the
  #                                           spawner: T9.14)
  #   receive do {:EXIT, p, r} -> ...     -> the pattern's variables get the types of the message the linked copy
  #                                          sends (a pid and an atom) as type-test guards; `_` becomes a variable
  #                                          so that it can have one. A pinned variable stays pinned (the codex
  #                                          sends the pin as a guard test).
  # The statement itself is dropped. A Process.flag anywhere else stays, and is a gap.
  defp trap(clause, {linked0, st0} = acc) do
    case Enum.split_while(stmts(clause.body), &(not trap_flag?(&1))) do
      {_, []} ->
        {clause, acc}

      # its value is the function's: left as it is
      {_, [_flag]} ->
        {clause, acc}

      {before, [_flag | rest]} ->
        {rest, {linked, st}} = rewrite(rest, {linked0, st0})
        {%{clause | body: block(before ++ rest)}, {Enum.uniq(linked), st}}
    end
  end

  defp trap_flag?({{:., _, [module, name]}, _, [{:__block__, _, [:trap_exit]}, {:__block__, _, [true]}]}),
    do: {module, name} |> flag_function?()

  defp trap_flag?(_other), do: false

  defp flag_function?({{:__aliases__, _, [:Process]}, :flag}), do: true
  defp flag_function?({{:__block__, _, [:erlang]}, :process_flag}), do: true
  defp flag_function?(_other), do: false

  defp spawn_link?(:spawn_link), do: true
  defp spawn_link?({:., _, [{:__aliases__, _, [:Kernel]}, :spawn_link]}), do: true
  defp spawn_link?({:., _, [{:__block__, _, [:erlang]}, :spawn_link]}), do: true
  defp spawn_link?(_other), do: false

  defp rewrite({f, m, [{:fn, fm, [{:->, am, [[], body]}]}]} = e, {linked, st} = acc) do
    with true <- spawn_link?(f), [call] <- stmts(body), {:ok, g} <- callee(call, st) do
      {spawn, st} = linked_spawn(m, fm, am, g, elem(call, 2), st)
      {spawn, {[g | linked], st}}
    else
      _ -> descend(e, acc, &rewrite/2)
    end
  end

  defp rewrite({f, m, [module, {:__block__, _, [g]}, {:__block__, _, [args]}]} = e, {linked, st} = acc)
       when is_atom(g) and is_list(args) do
    if spawn_link?(f) and own_module?(module, st) and is_map_key(st.funs, {g, length(args)}) and
         not Enum.any?(args, &match?({:|, _, _}, &1)) do
      {spawn, st} = linked_spawn(m, m, m, {g, length(args)}, args, st)
      {spawn, {[{g, length(args)} | linked], st}}
    else
      descend(e, acc, &rewrite/2)
    end
  end

  defp rewrite({:receive, m, [body]}, acc) do
    {body, acc} =
      kw_map(body, acc, fn
        :do, clauses, acc when is_list(clauses) -> Enum.map_reduce(clauses, acc, &exit_clause/2)
        _key, value, acc -> {value, acc}
      end)

    descend({:receive, m, [body]}, acc, &rewrite/2)
  end

  defp rewrite(e, acc), do: descend(e, acc, &rewrite/2)

  # The parent is bound before the spawn: inside the fn, self() would be the child in Elixir (the contract's
  # spawn evaluates the call's arguments in the spawner, T9.14; written this way both mean the same).
  defp linked_spawn(m, fm, am, g, args, st0) do
    {v, st1} = fresh("s", st0)
    call = {linked_name(g), am, args ++ [var(v, am)]}
    {{:__block__, [], [{:=, m, [var(v, m), {:self, m, []}]}, {:spawn, m, [{:fn, fm, [{:->, am, [[], call]}]}]}]}, st1}
  end

  defp exit_clause({:->, m, [head, body]} = clause, {linked, st0}) do
    {pattern, guard, when_meta} =
      case head do
        [{:when, wm, [pattern, guard]}] -> {pattern, guard, wm}
        [pattern] -> {pattern, nil, []}
        _ -> {nil, nil, []}
      end

    case pattern do
      {:{}, tm, [{:__block__, _, [:EXIT]} = tag, p1, p2]} ->
        {q1, t1, st1} = exit_part(p1, :is_pid, st0)
        {q2, t2, st2} = exit_part(p2, :is_atom, st1)
        pattern = {:{}, tm, [tag, q1, q2]}

        head =
          case Enum.reject(t1 ++ t2, &(strip(&1) in guard_tests(guard))) do
            [] -> if(guard == nil, do: [pattern], else: [{:when, when_meta, [pattern, guard]}])
            tests -> [{:when, when_meta, [pattern, and_guard(tests, guard)]}]
          end

        {{:->, m, [head, body]}, {linked, st2}}

      _ ->
        {clause, {linked, st0}}
    end
  end

  defp exit_clause(other, acc), do: {other, acc}

  # One element of an {:EXIT, pid, reason} pattern: {pattern, guard tests, st}.
  defp exit_part({:_, m, context}, test, st0) when is_atom(context) do
    {v, st1} = fresh("x", st0)
    {var(v, m), [{test, Keyword.take(m, [:line, :column]), [var(v, m)]}], st1}
  end

  defp exit_part({name, m, context} = p, test, st) when is_atom(name) and is_atom(context) do
    # `_reason` is `_` with a name: a guard may not use it, so it becomes a variable of this pass too
    if String.starts_with?(Atom.to_string(name), "_"),
      do: exit_part({:_, m, context}, test, st),
      else: {p, [{test, Keyword.take(m, [:line, :column]), [p]}], st}
  end

  defp exit_part(p, _test, st), do: {p, [], st}

  defp guard_tests(nil), do: []
  defp guard_tests({:and, _, [a, b]}), do: guard_tests(a) ++ guard_tests(b)
  defp guard_tests(test), do: [strip(test)]

  defp strip({a, meta, args}) when is_list(meta), do: {strip(a), [], strip(args)}
  defp strip({a, b}), do: {strip(a), strip(b)}
  defp strip(list) when is_list(list), do: Enum.map(list, &strip/1)
  defp strip(other), do: other

  # tests and the guard; `when a when b` holds when either does.
  defp and_guard(tests, nil), do: conj(tests)
  defp and_guard(tests, {:when, m, [a, b]}), do: {:when, m, [and_guard(tests, a), and_guard(tests, b)]}
  defp and_guard(tests, guard), do: conj(tests ++ [guard])

  defp conj([one]), do: one
  defp conj([first | rest]), do: Enum.reduce(rest, first, fn test, so_far -> {:and, meta(first), [so_far, test]} end)

  # ------------------------------------------------------------------ literals in struct patterns

  # def f(%S{a: 0}), do: ...   becomes   def f(%S{a: e2s_p1}) when e2s_p1 === 0, do: ...   in the clauses of
  # functions, case and receive: the transpiler prints a record pattern whose fields are variables (it reads
  # them from the matched value), and a pattern literal is Elixir's exact comparison.
  defp literals(clause, st0) do
    {args, {tests, st1}} = lit_patterns(clause.args, {[], st0})
    {body, st2} = lit_body(clause.body, st1)

    case tests do
      [] -> {%{clause | body: body}, st2}
      _ -> {%{clause | args: args, guard: and_guard(Enum.reverse(tests), clause.guard), body: body}, st2}
    end
  end

  defp lit_patterns({:%, m, [name, {:%{}, m2, fields}]}, acc0) when is_list(fields) do
    {fields, acc} =
      Enum.map_reduce(fields, acc0, fn
        {key, value}, {tests, st} = acc ->
          if literal?(value) do
            {v, st} = fresh("p", st)
            vm = meta(value)
            {{key, var(v, vm)}, {[{:===, vm, [var(v, vm), value]} | tests], st}}
          else
            {value, acc} = lit_patterns(value, acc)
            {{key, value}, acc}
          end

        other, acc ->
          {other, acc}
      end)

    {{:%, m, [name, {:%{}, m2, fields}]}, acc}
  end

  defp lit_patterns(ast, acc), do: descend(ast, acc, &lit_patterns/2)

  defp literal?({:__block__, _, [x]}) when is_number(x) or is_atom(x) or is_binary(x), do: true
  defp literal?({:-, _, [{:__block__, _, [x]}]}) when is_number(x), do: true
  defp literal?(_other), do: false

  # The case and receive expressions inside a body (not inside a fn: its clauses are typed by the place it is
  # passed to).
  defp lit_body({:fn, _, _} = f, st), do: {f, st}

  defp lit_body({tag, m, args}, st) when tag in [:case, :receive] and is_list(args) do
    {args, st} = Enum.map_reduce(args, st, &lit_body/2)
    {body, st} = kw_map(List.last(args), st, fn
      :do, clauses, st when is_list(clauses) -> Enum.map_reduce(clauses, st, &lit_arrow/2)
      _key, value, st -> {value, st}
    end)

    {{tag, m, Enum.drop(args, -1) ++ [body]}, st}
  end

  defp lit_body(ast, st), do: descend(ast, st, &lit_body/2)

  defp lit_arrow({:->, m, [head, body]}, st0) do
    {patterns, guard, when_meta} =
      case head do
        [{:when, wm, args}] -> {Enum.drop(args, -1), List.last(args), wm}
        patterns -> {patterns, nil, []}
      end

    case lit_patterns(patterns, {[], st0}) do
      {_, {[], st}} -> {{:->, m, [head, body]}, st}
      {patterns, {tests, st}} -> {{:->, m, [[{:when, when_meta, patterns ++ [and_guard(Enum.reverse(tests), guard)]}], body]}, st}
    end
  end

  defp lit_arrow(other, st), do: {other, st}
end
