# Gaps: what examples/demo.ex used to leave out on purpose, kept here for the tests. Every function of this
# module is sent as a gap, or holds one (contract T9.10: a session with gaps still completes):
#   - a type the sender cannot state: max_of/2 (no @spec), area/1 (number()), sum_list/1 (a list type),
#     name_or/2 (truthiness of a value that may be nil), boxed/1 (a fn whose parameter nothing types);
#   - a construct outside the subset: the inter-node call of shout/1;
#   - what the sender sends and the transpiler answers with its own gap: a closure (add_n/2), a union with nil
#     in a signature (name_or/2), Process.link/1 on a process that exists (stop_counter/1).
defmodule Gaps do
  @spec add(integer(), integer()) :: integer()
  def add(a, b), do: a + b

  # `||` asks whether a value that is a string or nil is nil: a comparison of two types, which has no operator.
  @spec name_or(String.t() | nil, String.t()) :: String.t()
  def name_or(name, default), do: name || default

  # number() is integer() or float(): no one type to state, so the function is a gap.
  @spec area({:square, integer()} | {:rectangle, integer(), integer()} | {:circle, float()}) :: number()
  def area({:square, side}), do: side * side
  def area({:rectangle, w, h}) when w > 0 and h > 0, do: w * h
  def area({:circle, r}), do: 3.14159 * r * r
  def area(_), do: exit(:badarg)

  # No @spec: nothing states its types, so the function is a gap.
  def max_of(a, b) do
    if a >= b do
      a
    else
      b
    end
  end

  @spec twice((integer() -> integer()), integer()) :: integer()
  def twice(f, x), do: f.(f.(x))

  # The fn uses n, a variable of add_n/2: a closure. The sender states its type and sends it as a (:lambda).
  @spec add_n(integer(), integer()) :: integer()
  def add_n(n, start), do: twice(fn x -> add(x, n) end, start)

  # Here nothing gives the fn's parameter a type (Elixir writes none on a fn): the binding is a gap.
  @spec boxed(integer()) :: integer()
  def boxed(n) do
    step = fn x -> add(x, 5) end
    step.(n)
  end

  @spec start_counter() :: pid()
  def start_counter, do: spawn(Gaps, :counter, [0])

  @spec counter(integer()) :: integer()
  def counter(total) do
    receive do
      {:add, n} when is_integer(n) -> counter(total + n)
      :stop -> total
    end
  end

  # Process.link/1 and Process.exit/2 have nodes (H24, H25); the transpiler writes no link (contract T9.15).
  @spec stop_counter(pid()) :: boolean()
  def stop_counter(pid) do
    Process.link(pid)
    Process.exit(pid, :shutdown)
  end

  @spec sum_list([integer()]) :: integer()
  def sum_list([]), do: 0
  def sum_list([h | t]), do: h + sum_list(t)

  @spec shout(String.t()) :: :ok
  def shout(name), do: :rpc.call(node(), IO, :puts, [name])
end
