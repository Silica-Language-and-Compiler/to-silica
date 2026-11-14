defmodule E2s.Names do
  @moduledoc """
  The naming scheme of elixir-to-silica-poc: how Elixir names become the names in frames. The Erlang and Gleam
  proofs of concept use the same rules, so a session that mixes languages spells names one way.

    * N1 `silica_unit` (T5.2): the prefix, then the module path with each `.`-separated segment in snake case,
      joined with `_`, through `ident/1`. `MyApp.HTTPServer` -> `ex_my_app_http_server`.
    * N2 `unit_name`, and the `module` of `(:call)` and `(:fun_ref)`: the module name as the user writes it
      (`Actors.Account`, `IO`, `erlang`). Not changed (T5.2).
    * N3 type names (`:type` form, `t_named`, `(:record)`): a struct is named after its module, in the N1 spelling
      without the prefix. `Actors.Account` -> `actors_account`. The session has one namespace for types, so the
      name carries the module.
    * N4 function, variable and field names: the source spelling through `ident/1`, which is injective: two
      source names never get one sent name, and `decode` in the tests reads the source name back. A function
      name defined at more than one arity gets `__<arity>` (`function/2`).
    * N5 symbols (`(:symbol)`, `t_symbols`, the tag of `t_tagged`): the atom's own text, unchanged. Making a symbol
      a Silica atom is the transpiler's work (H5, BEES A6.3).

  This module is the only place that spells a name; change a rule here and every frame follows.
  """

  @doc """
  N4. An identifier of letters, digits and `_` for a source name, such that no two source names give the same
  identifier. The name's characters are taken left to right:

    * `[A-Za-z0-9]` is kept;
    * `?` is `__q`, `!` is `__b`;
    * `_` is kept only when the character before it is not `_` and the character after it (if any) is neither
      `_` nor a character that is escaped; every other `_` is `__x5f_`;
    * any other character is `__x<lowercase hex code point>_`;
    * the empty name is `__e`; a first character that is a digit is escaped as `__x3N_`.

  So `__` appears in the result only where an escape starts, and ordinary names are unchanged.

      iex> E2s.Names.ident("empty?")
      "empty__q"
      iex> E2s.Names.ident("sum_list")
      "sum_list"
  """
  def ident(""), do: "__e"

  def ident(name) when is_binary(name) do
    case String.to_charlist(name) do
      [first | rest] when first in ?0..?9 -> hex(first) <> chars(rest, first)
      chars -> chars(chars, nil)
    end
  end

  # chars(what is left, the source character before it)
  defp chars([], _previous), do: ""

  defp chars([?_ | rest], previous) do
    kept = previous != ?_ and (rest == [] or plain?(hd(rest)))
    if(kept, do: "_", else: hex(?_)) <> chars(rest, ?_)
  end

  defp chars([c | rest], _previous) do
    cond do
      plain?(c) -> <<c>>
      c == ?? -> "__q"
      c == ?! -> "__b"
      true -> hex(c)
    end <> chars(rest, c)
  end

  defp plain?(c), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9
  defp hex(c), do: "__x" <> String.downcase(Integer.to_string(c, 16)) <> "_"

  @doc """
  N4, arity. The sent name of the function `name`/`arity`: `ident(name)`, and `ident(name)__<arity>` when
  `several` is true, which the codex passes when the module defines `name` at more than one arity. `__` and then a
  digit is never an escape of `ident/1`, so the result stays injective.

      iex> E2s.Names.function("fetch!", 2, true)
      "fetch__b__2"
  """
  def function(name, _arity, false), do: ident(name)
  def function(name, arity, true), do: ident(name) <> "__" <> Integer.to_string(arity)

  @doc """
  Snake case of one name segment: `_` goes between a lowercase letter or digit and an uppercase letter, and
  between an uppercase letter and an uppercase letter that a lowercase letter follows; then everything is
  lowercased. `HTTPServer` -> `http_server`, `MyApp` -> `my_app`.
  """
  def snake(segment) when is_binary(segment) do
    segment
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
    |> String.replace(~r/([A-Z])([A-Z][a-z])/, "\\1_\\2")
    |> String.downcase()
  end

  @doc "N3. The type name of the struct declared by `module` (`\"Actors.Account\"` -> `\"actors_account\"`)."
  def type_name(module) when is_binary(module),
    do: module |> String.split(".") |> Enum.map_join("_", &snake/1) |> ident()

  @doc "N1. The Silica unit asked for a module (`\"My.HTTPMod\"`, prefix `\"ex_\"` -> `\"ex_my_http_mod\"`)."
  def silica_unit(prefix, module), do: prefix <> type_name(module)
end
