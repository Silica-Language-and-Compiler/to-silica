defmodule E2s.Codex.Truthiness do
  @moduledoc """
  The truthiness lowering. In Elixir every value but `false` and `nil` counts as true in `if`, `cond`, `&&`, `||`
  and `!`; the contract's `(:cond, …)` takes the first clause whose guard is true (H30) and Appendix B's boolean
  operators take booleans. So:

    * a condition that is **boolean by its syntax** (`boolean?/2`) is sent as it is: `if`/`cond` as `(:cond, …)`,
      `&&`, `||`, `!` as `andalso`, `orelse`, `not`;
    * any other condition is rewritten, as Elixir's own macros do, to a `case` that tests the value once:

          if c, do: a, else: b    case c do t when t === false or t === nil -> b; _ -> a end
          a && b                  case a do t when t === false or t === nil -> t; _ -> b end
          a || b                  case a do t when t === false or t === nil -> b; t -> t end
          !a                      case a do t when t === false or t === nil -> true; _ -> false end
          cond do c -> a; … end   case c do t when t === false or t === nil -> (the rest of the cond); _ -> a end

  The functions here return Elixir AST; the codex translates it like any other `case`. `t` is the variable
  `_truthy`.
  """

  @comparisons [:==, :!=, :<, :<=, :>, :>=, :===, :!==]

  @doc """
  True when the expression is known to give `true` or `false`: by its syntax (a boolean literal, a comparison,
  `not`, `!`, `and`/`or`/`&&`/`||` whose operands are, a call to one of Kernel's `is_*` tests that the module does
  not define itself), or by its type, which the codex's typing pass answers through `ctx.known` (a variable whose
  stated type is `boolean()`, a call to a function of the module whose `@spec` returns `boolean()`).

  `ctx` is `%{locals: MapSet of {name, arity} the module defines, known: (ast -> boolean)}`.
  """
  def boolean?({:__block__, _, [literal]}, _locals) when is_boolean(literal), do: true
  def boolean?({:__block__, _, [{_, _, _} = one]}, locals), do: boolean?(one, locals)
  def boolean?({op, _, [_, _]}, _locals) when op in @comparisons, do: true
  def boolean?({op, _, [_]}, _locals) when op in [:not, :!], do: true
  # `and` and `or` fail unless their left operand is a boolean, so the right operand decides.
  def boolean?({op, _, [_, right]}, locals) when op in [:and, :or], do: boolean?(right, locals)
  def boolean?({op, _, [left, right]}, locals) when op in [:&&, :||], do: boolean?(left, locals) and boolean?(right, locals)

  def boolean?({name, _, args} = call, ctx) when is_atom(name) and is_list(args) do
    arity = length(args)

    (String.starts_with?(Atom.to_string(name), "is_") and not MapSet.member?(ctx.locals, {name, arity}) and
       ({name, arity} in Kernel.__info__(:functions) or {name, arity} in Kernel.__info__(:macros))) or ctx.known.(call)
  end

  def boolean?(other, ctx), do: ctx.known.(other)

  @doc "`if condition, do: then, else: otherwise` for a condition that is not boolean by its syntax."
  def if_case(condition, then, otherwise, meta), do: test(condition, otherwise, then, meta)

  @doc "`left && right`."
  def and_case(left, right, meta), do: test(left, truthy(meta), right, meta)

  @doc "`left || right`."
  def or_case(left, right, meta) do
    case_of(left, [falsy_clause(right, meta), {:->, meta, [[truthy(meta)], truthy(meta)]}], meta)
  end

  @doc "`!value`."
  def not_case(value, meta), do: test(value, literal(true, meta), literal(false, meta), meta)

  @doc """
  A `cond` with at least one condition that is not boolean by its syntax: the clauses up to it stay a `cond`, whose
  last clause (`true ->`) tests that condition with a `case`; the clauses after it are the `cond` of the falsy
  branch. When no clause is left, the falsy branch fails with `:cond_clause`, as Elixir raises `CondClauseError`.
  """
  def cond_case(clauses, meta, locals)

  def cond_case([], meta, _locals), do: {{:., meta, [literal(:erlang, meta), :error]}, meta, [literal(:cond_clause, meta)]}

  def cond_case(clauses, meta, locals) do
    {plain, rest} = Enum.split_while(clauses, fn {:->, _, [[c], _]} -> boolean?(c, locals) end)

    case rest do
      [] ->
        cond_of(plain, meta)

      [{:->, m, [[condition], body]} | more] ->
        tested = test(condition, cond_case(more, m, locals), body, m)
        if plain == [], do: tested, else: cond_of(plain ++ [{:->, m, [[literal(true, m)], tested]}], meta)
    end
  end

  # case value do t when t === false or t === nil -> if_falsy; _ -> if_truthy end
  defp test(value, if_falsy, if_truthy, meta) do
    case_of(value, [falsy_clause(if_falsy, meta), {:->, meta, [[{:_, meta, nil}], if_truthy]}], meta)
  end

  defp falsy_clause(body, meta) do
    t = truthy(meta)
    falsy = {:or, meta, [{:===, meta, [t, literal(false, meta)]}, {:===, meta, [t, literal(nil, meta)]}]}
    {:->, meta, [[{:when, meta, [t, falsy]}], body]}
  end

  defp truthy(meta), do: {:_truthy, meta, nil}

  # The AST shapes below are the parser's, with literals wrapped as the codex's literal encoder wraps them.
  defp literal(value, meta), do: {:__block__, meta, [value]}
  defp case_of(subject, clauses, meta), do: {:case, meta, [subject, [{literal(:do, meta), clauses}]]}
  defp cond_of(clauses, meta), do: {:cond, meta, [[{literal(:do, meta), clauses}]]}
end
