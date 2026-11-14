defmodule E2s.Codex.Types do
  @moduledoc """
  The types of the codex's typing pass (contract 8.6: the sender decides every type).

  A type is held nested, in the vocabulary of contract 8.5, and is written into a form's flat type table only at
  the end (`intern/2`):

      {:t_int, :i64}  {:t_float, :f64}  {:t_basic, :boolean | :text | :symbol | :dynamic}  {:t_symbols, [name]}
      {:t_tuple, [type]}  {:t_tagged, tag, [type]}  {:t_union, [type]}  {:t_fun, [type], type}  {:t_actor, type}
      {:t_named, name, []}

  Two more values exist only inside the codex and are never sent:

    * `{:unknown, reason}`: the codex could not work the type out; `reason` is the sentence a gap's note carries;
    * `:never`: the node has no value to type (a `(:fail)`, a gap).

  This module knows Elixir's types and nothing about node tables: `from_spec/2` reads `@spec` and `@type` syntax,
  the rest are the questions the codex asks of two types (are they one type, can they share a value, does a value
  of one fit where the other is declared).
  """

  @int {:t_int, :i64}
  @float {:t_float, :f64}
  @boolean {:t_basic, :boolean}
  @text {:t_basic, :text}

  def int, do: @int
  def float, do: @float
  def boolean, do: @boolean
  def text, do: @text
  def atom, do: {:t_basic, :symbol}
  def symbols(names), do: {:t_symbols, names}
  @doc "Elixir's pid(): a process reference. Elixir does not type a process's messages, so the message is dynamic."
  def pid, do: {:t_actor, {:t_basic, :dynamic}}
  def named(name), do: {:t_named, name, []}
  def unknown(reason), do: {:unknown, reason}

  def known?(:never), do: false
  def known?({:unknown, _}), do: false
  def known?(_), do: true

  def unknown?({:unknown, _}), do: true
  def unknown?(_), do: false

  def reason({:unknown, reason}), do: reason
  def reason(:never), do: "it was sent as a gap, so it has no type"
  def reason(type), do: "its type is " <> show(type)

  @doc ":int, :float or nil."
  def num({:t_int, _}), do: :int
  def num({:t_float, _}), do: :float
  def num(_), do: nil

  @doc """
  The type of a tuple from its elements' types. A tuple whose first element is a literal atom (`tag` is its text)
  is a tagged tuple, as `from_spec/2` reads `{:ok, integer()}`. A part without a type leaves the whole without.
  """
  def tuple(tag, types) do
    case first_unusable(types) do
      nil -> if tag, do: {:t_tagged, tag, tl(types)}, else: {:t_tuple, types}
      bad -> bad
    end
  end

  defp first_unusable(types), do: Enum.find(types, &unknown?/1) || Enum.find(types, &(&1 == :never))

  @doc """
  The one type of the branches of a `case`, `cond`, `if` or `receive`: the type they all have, or the union of
  their atoms. Branches that have no value (`:never`) do not count. Anything else has no one type.
  """
  def join(types) do
    case Enum.uniq(Enum.reject(types, &(&1 == :never))) do
      [] ->
        :never

      [one] ->
        one

      many ->
        cond do
          bad = Enum.find(many, &unknown?/1) -> bad
          Enum.all?(many, &match?({:t_symbols, _}, &1)) -> {:t_symbols, many |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq()}
          true -> unknown("its branches have different types (#{Enum.map_join(many, ", ", &show/1)})")
        end
    end
  end

  @doc """
  The type of a parameter that is given a value of type `a` by one call and of type `b` by another (the
  parameters of the functions `E2s.Split` made): the type both have, the union of their atoms, or the union of
  the two. A call that gives no type (it passes on a parameter whose type is still being collected, or a gap)
  says nothing: the other calls decide.
  """
  def merge(a, a), do: a
  def merge({:unknown, _}, b), do: if(b == :never, do: unknown(reason(:never)), else: b)
  def merge(a, {:unknown, _}), do: if(a == :never, do: unknown(reason(:never)), else: a)
  def merge(:never, b), do: b
  def merge(a, :never), do: a
  def merge({:t_symbols, as}, {:t_symbols, bs}), do: {:t_symbols, Enum.uniq(as ++ bs)}
  def merge({:t_symbols, _}, {:t_basic, :symbol} = b), do: b
  def merge({:t_basic, :symbol} = a, {:t_symbols, _}), do: a

  def merge(a, b) do
    alts = fn
      {:t_union, alts} -> alts
      one -> [one]
    end

    {:t_union, Enum.uniq(alts.(a) ++ alts.(b))}
  end

  @doc """
  True when a value of type `a` may stand where `p` is declared (an argument against an `@spec`, a field value
  against the struct's `@type`). Lenient where either side says nothing.
  """
  def fits?(a, p) do
    cond do
      a == p or not known?(a) or not known?(p) -> true
      a == {:t_basic, :dynamic} or p == {:t_basic, :dynamic} -> true
      match?({:t_union, _}, a) -> Enum.all?(elem(a, 1), &fits?(&1, p))
      match?({:t_union, _}, p) -> Enum.any?(elem(p, 1), &fits?(a, &1))
      true -> fits_plain?(a, p)
    end
  end

  defp fits_plain?({:t_symbols, as}, {:t_symbols, ps}), do: as -- ps == []
  defp fits_plain?({:t_symbols, _}, {:t_basic, :symbol}), do: true
  defp fits_plain?({:t_basic, :boolean}, {:t_basic, :symbol}), do: true
  defp fits_plain?({:t_tuple, as}, {:t_tuple, ps}), do: all_fit?(as, ps)
  defp fits_plain?({:t_tagged, tag, as}, {:t_tagged, tag, ps}), do: all_fit?(as, ps)
  defp fits_plain?({:t_actor, _}, {:t_actor, _}), do: true
  defp fits_plain?({:t_fun, as, _}, {:t_fun, ps, _}), do: length(as) == length(ps)
  defp fits_plain?(_, _), do: false

  defp all_fit?(as, ps), do: length(as) == length(ps) and Enum.all?(Enum.zip(as, ps), fn {a, p} -> fits?(a, p) end)

  @doc """
  True when no Elixir value has both types, so `==` and `===` between them is false whatever the values. (An
  integer and a float count as disjoint here; the codex treats `==` between those two first, by converting.)
  Conservative: false when it cannot tell.
  """
  def disjoint?({:t_union, alts}, b), do: Enum.all?(alts, &disjoint?(&1, b))
  def disjoint?(a, {:t_union, alts}), do: Enum.all?(alts, &disjoint?(a, &1))

  def disjoint?(a, b) do
    case {class(a), class(b)} do
      {:any, _} -> false
      {_, :any} -> false
      {:boolean, {:atoms, names}} -> no_boolean?(names)
      {{:atoms, names}, :boolean} -> no_boolean?(names)
      {{:atoms, :any}, {:atoms, _}} -> false
      {{:atoms, _}, {:atoms, :any}} -> false
      {{:atoms, x}, {:atoms, y}} -> x -- y == x
      {{:tuple, n, x}, {:tuple, m, y}} -> n != m or (x != nil and y != nil and x != y)
      {{:record, x}, {:record, y}} -> x != y
      {same, same} -> false
      _ -> true
    end
  end

  defp no_boolean?(:any), do: false
  defp no_boolean?(names), do: "true" not in names and "false" not in names

  defp class({:t_int, _}), do: :int
  defp class({:t_float, _}), do: :float
  defp class({:t_basic, :boolean}), do: :boolean
  defp class({:t_basic, :text}), do: :text
  defp class({:t_basic, :bytes}), do: :text
  defp class({:t_basic, :symbol}), do: {:atoms, :any}
  defp class({:t_symbols, names}), do: {:atoms, names}
  defp class({:t_tuple, ts}), do: {:tuple, length(ts), nil}
  defp class({:t_tagged, tag, ts}), do: {:tuple, length(ts) + 1, tag}
  defp class({:t_named, name, _}), do: {:record, name}
  defp class({:t_fun, _, _}), do: :fun
  defp class({:t_actor, _}), do: :pid
  defp class(_), do: :any

  @doc """
  What one of Kernel's type tests (`is_integer/1` and the like, as `kind`) gives for a value of a stated type:
  `true`, `false`, or `:unknown` when the type does not decide it.
  """
  def test(_kind, {:t_union, _}), do: :unknown
  def test(_kind, {:t_basic, :dynamic}), do: :unknown

  def test(kind, type) do
    if known?(type) do
      case {kind, class(type)} do
        {:number, c} -> c in [:int, :float]
        {:atom, c} -> c == :boolean or match?({:atoms, _}, c)
        {:boolean, {:atoms, :any}} -> :unknown
        {:boolean, {:atoms, names}} -> if no_boolean?(names), do: false, else: :unknown
        {:tuple, c} -> match?({:tuple, _, _}, c)
        {kind, c} -> kind == c
      end
    else
      :unknown
    end
  end

  @doc "The type as Elixir would write it, for the notes of gaps."
  def show({:t_int, _}), do: "integer()"
  def show({:t_float, _}), do: "float()"
  def show({:t_basic, :boolean}), do: "boolean()"
  def show({:t_basic, :text}), do: "String.t()"
  def show({:t_basic, :symbol}), do: "atom()"
  def show({:t_basic, :dynamic}), do: "term()"
  def show({:t_basic, kind}), do: Atom.to_string(kind)
  def show({:t_symbols, names}), do: Enum.map_join(names, " | ", &if(&1 == "nil", do: "nil", else: ":" <> &1))
  def show({:t_tuple, ts}), do: "{" <> Enum.map_join(ts, ", ", &show/1) <> "}"
  def show({:t_tagged, tag, ts}), do: "{" <> Enum.join([":" <> tag | Enum.map(ts, &show/1)], ", ") <> "}"
  def show({:t_union, ts}), do: Enum.map_join(ts, " | ", &show/1)
  def show({:t_fun, ps, r}), do: "(" <> Enum.map_join(ps, ", ", &show/1) <> " -> " <> show(r) <> ")"
  def show({:t_actor, _}), do: "pid()"
  def show({:t_named, name, _}), do: "the struct " <> name
  def show(:never), do: "no value"
  def show({:unknown, _}), do: "an unknown type"

  @doc """
  Writes a nested type into a flat type table (contract 8.5: children before their parent) and returns its
  index. `table` is `{entries, index of each nested type already written}`; a type is written once.
  """
  def new_table, do: {[], %{}}

  def intern(type, {_, memo} = table) when is_map_key(memo, type), do: {Map.fetch!(memo, type), table}

  def intern(type, table) do
    {wire, {entries, memo}} =
      case type do
        {:t_tuple, ts} -> with_children(ts, table, &{:t_tuple, &1})
        {:t_tagged, tag, ts} -> with_children(ts, table, &{:t_tagged, tag, &1})
        {:t_union, ts} -> with_children(ts, table, &{:t_union, &1})
        {:t_actor, m} -> with_children([m], table, fn [i] -> {:t_actor, i} end)
        {:t_named, name, args} -> with_children(args, table, &{:t_named, name, &1})
        {:t_fun, ps, r} -> with_children(ps ++ [r], table, &{:t_fun, Enum.drop(&1, -1), List.last(&1)})
        leaf -> {leaf, table}
      end

    {length(entries), {entries ++ [wire], Map.put(memo, type, length(entries))}}
  end

  defp with_children(types, table, build) do
    {is, table} = Enum.map_reduce(types, table, &intern/2)
    {build.(is), table}
  end

  @doc "The entries of a table, in order."
  def entries({entries, _}), do: entries

  # ------------------------------------------------------------------ @spec and @type syntax

  # A literal as the codex's literal encoder wraps it.
  defguardp is_lit(x) when is_number(x) or is_atom(x) or is_binary(x) or is_list(x) or (is_tuple(x) and tuple_size(x) == 2)

  @doc """
  The type an Elixir type expression states, or `{:unknown, reason}` when it states none this codex can send:
  `term()`, `any()`, `number()`, lists, maps and user types.

  `env` needs `:module` (for `t()`), `:structs` (the modules of the file that declare a struct), `:aliases`, and
  may have `:records` (to refuse a struct whose fields are not all typed). `type_name` spells a struct's type name
  (N3) and `module_ref` resolves a module's syntax; both are the codex's.
  """
  def from_spec({:"::", _, [_name, t]}, env), do: from_spec(t, env)

  def from_spec({:__block__, _, [x]} = ast, env) when is_lit(x) do
    case x do
      b when is_boolean(b) -> @boolean
      a when is_atom(a) -> {:t_symbols, [Atom.to_string(a)]}
      n when is_integer(n) -> @int
      {a, b} -> tuple_spec([a, b], env)
      [{:->, _, [args, ret]}] -> fun_spec(args, ret, env)
      _ -> outside(ast)
    end
  end

  def from_spec({:{}, _, elems}, env), do: tuple_spec(elems, env)

  def from_spec({:|, _, _} = union, env) do
    alts = union_alts(union)
    atoms = for {:__block__, _, [a]} when is_atom(a) <- alts, do: a

    cond do
      length(atoms) != length(alts) -> all(Enum.map(alts, &from_spec(&1, env)), &{:t_union, &1})
      Enum.sort(atoms) == [false, true] -> @boolean
      true -> {:t_symbols, Enum.map(atoms, &Atom.to_string/1)}
    end
  end

  # Elixir integers are unbounded: i64 is the contract's fallback (T8.7).
  def from_spec({name, _, args}, _env)
      when name in [:integer, :non_neg_integer, :pos_integer, :neg_integer] and args in [nil, []],
      do: @int

  def from_spec({:float, _, args}, _env) when args in [nil, []], do: @float
  def from_spec({:boolean, _, args}, _env) when args in [nil, []], do: @boolean
  def from_spec({:atom, _, args}, _env) when args in [nil, []], do: atom()
  def from_spec({:binary, _, args}, _env) when args in [nil, []], do: @text
  def from_spec({:pid, _, args}, _env) when args in [nil, []], do: pid()

  def from_spec({:number, _, args}, _env) when args in [nil, []],
    do: unknown("number() is integer() or float(), so it is no one type that can be stated")

  def from_spec({name, _, args}, _env) when name in [:term, :any] and args in [nil, []],
    do: unknown("#{name}() says nothing about the type, and there is no untyped representation (T8.1)")

  def from_spec({:t, _, args}, env) when args in [nil, []], do: struct_spec(env.module, env, "t()")

  # String.t() is text; Struct.t() of a struct declared in this file is that declaration.
  def from_spec({{:., _, [module, :t]}, _, []} = ast, env) do
    case env.module_ref.(module) do
      {:elixir, "String"} -> @text
      {:elixir, name} -> struct_spec(name, env, name <> ".t()")
      _ -> outside(ast)
    end
  end

  def from_spec({:%, _, [module, _]} = ast, env) do
    case env.module_ref.(module) do
      {:elixir, name} -> struct_spec(name, env, "%" <> name <> "{}")
      _ -> outside(ast)
    end
  end

  def from_spec(other, _env), do: outside(other)

  defp struct_spec(name, env, written) do
    type_name = env.type_name.(name)

    cond do
      not MapSet.member?(env.structs, name) -> unknown("#{written} is not a struct declared in this file")
      match?(%{^type_name => {:untyped, _}}, Map.get(env, :records, %{})) -> unknown(elem(env.records[type_name], 1))
      true -> named(type_name)
    end
  end

  defp tuple_spec([{:__block__, _, [tag]} | elems], env) when is_atom(tag) and not is_boolean(tag),
    do: all(Enum.map(elems, &from_spec(&1, env)), &{:t_tagged, Atom.to_string(tag), &1})

  defp tuple_spec(elems, env), do: all(Enum.map(elems, &from_spec(&1, env)), &{:t_tuple, &1})

  defp fun_spec(args, ret, env),
    do: all(Enum.map(args ++ [ret], &from_spec(&1, env)), &{:t_fun, Enum.drop(&1, -1), List.last(&1)})

  defp all(types, build), do: Enum.find(types, &unknown?/1) || build.(types)

  defp union_alts({:|, _, [left, right]}), do: union_alts(left) ++ union_alts(right)
  defp union_alts(other), do: [other]

  defp outside(ast),
    do: unknown("the type #{written(ast)} is outside the subset (lists, maps, remote and user types are not translated)")

  defp written(ast) do
    ast
    |> Macro.prewalk(fn
      {:__block__, _, [x]} when is_lit(x) and not is_tuple(x) -> x
      other -> other
    end)
    |> Macro.to_string()
  rescue
    _ -> "written there"
  end
end
