defmodule E2s.Codex.Scope do
  @moduledoc """
  Variable names of one function clause, for the rebinding lowering.

  Elixir lets a variable be bound again (`x = x + 1`); the contract's `(:var, …)` in a pattern is "a binding"
  (H16) and says nothing of binding a name twice. So this codex sends every binding under its own name: the first
  binding of `x` in a function clause is `x`, each later binding of a variable called `x` (a rebinding, or a
  binding in another branch or closure) is `x_1`, `x_2`, …, skipping names the source itself uses. A reference is
  sent under the name of the binding it sees. The receiver therefore never meets one name bound twice in a
  function clause, whatever its scoping rules are.

  `vars` is what is visible now (source name -> sent name); the codex saves and restores it around a clause of
  `case`, `cond`, `receive` or `fn`, because in Elixir a binding made in such a clause ends with it. `seen` is every
  sent name already bound in this function clause; it only grows. `taken` is every variable name of the function's
  source.
  """
  defstruct vars: %{}, seen: MapSet.new(), taken: MapSet.new()

  @doc "A scope for a function whose source uses the variable names `taken` (already in their sent spelling)."
  def new(taken), do: %__MODULE__{taken: MapSet.new(taken)}

  @doc "The scope at the start of the function's next clause: nothing visible, nothing bound."
  def reset(scope), do: %{scope | vars: %{}, seen: MapSet.new()}

  @doc "The sent name of the visible binding of `name`, or nil."
  def lookup(scope, name), do: Map.get(scope.vars, name)

  @doc """
  A sent name for a new binding of the source variable whose sent spelling is `base`. The binding is not visible
  until `show/2`: the value of `x = x + 1` must still see the old `x`.
  """
  def bind(scope, base) do
    if MapSet.member?(scope.seen, base), do: fresh(scope, base), else: {base, mark(scope, base)}
  end

  @doc "A sent name no source variable and no earlier binding has: `base_1`, `base_2`, …"
  def fresh(scope, base, n \\ 1) do
    name = "#{base}_#{n}"

    if MapSet.member?(scope.seen, name) or MapSet.member?(scope.taken, name),
      do: fresh(scope, base, n + 1),
      else: {name, mark(scope, name)}
  end

  @doc "Makes bindings (source name -> sent name) visible."
  def show(scope, bindings), do: %{scope | vars: Map.merge(scope.vars, bindings)}

  defp mark(scope, name), do: %{scope | seen: MapSet.put(scope.seen, name)}
end
