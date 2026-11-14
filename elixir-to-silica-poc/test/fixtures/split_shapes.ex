# split_shapes.ex: every shape E2s.Split cuts, in one module, for the tests ("the split" in test/e2s_test.exs).
#
#   elixir -r test/fixtures/split_shapes.ex -e "Shapes.main()"
#
# prints the 16 lines listed in the test "the split forms of the fixture run as Elixir". The same module, sent in
# transpile mode, exported, compiled and run as a Silica program, printed the same 16 lines (README, "Processes:
# what this sender splits"). main/0 sends itself the messages each function then receives.
defmodule Shapes do
  defmodule Box do
    @type t :: %__MODULE__{n: integer(), tag: atom()}
    defstruct n: 0, tag: :none
  end

  @spec get() :: integer()
  def get do
    receive do
      {:n, n} when is_integer(n) -> n
    end
  end

  @spec two(atom()) :: {atom(), integer(), integer()}
  def two(a) do
    x = receive do {:n, n} when is_integer(n) -> n end
    y = receive do {:n, n} when is_integer(n) -> n end
    {a, x, y}
  end

  @spec in_case(:wait | :no, integer()) :: integer()
  def in_case(flag, a) do
    r =
      case flag do
        :wait ->
          m = receive do {:n, n} when is_integer(n) -> n end
          m * 2
        :no ->
          a
      end
    r + 1
  end

  @spec in_if(boolean()) :: integer()
  def in_if(flag) do
    if flag do
      v = get()
      send(self(), {:n, v + 1})
    end
    w = get()
    w * 10
  end

  @spec nested() :: integer()
  def nested do
    receive do
      {:n, n} when is_integer(n) ->
        m = receive do {:n, k} when is_integer(k) -> k end
        n - m
      :none -> 0
    end
  end

  @spec as_arg(integer()) :: integer()
  def as_arg(a) do
    add(a, get())
  end

  @spec piped(integer()) :: integer()
  def piped(a) do
    b = a |> wait_add() |> add(1)
    b * 2
  end

  @spec wait_add(integer()) :: integer()
  def wait_add(a), do: a + get()
  @spec add(integer(), integer()) :: integer()
  def add(a, b), do: a + b

  @spec rebind(integer()) :: integer()
  def rebind(x) do
    x = x + get()
    x = x + get()
    x
  end

  @spec subject() :: :one | :many
  def subject do
    case get() do
      1 -> :one
      _ -> :many
    end
  end

  @spec loop(integer()) :: integer()
  def loop(acc) do
    receive do
      {:n, n} when is_integer(n) -> loop(acc + n)
      :stop -> acc
    end
  end

  @spec after_loop(integer()) :: {:total, integer()}
  def after_loop(start) do
    total = loop(start)
    {:total, total}
  end

  @spec timed() :: {:got, integer()}
  def timed do
    r = receive do {:n, n} when is_integer(n) -> n after 20 -> -1 end
    {:got, r}
  end

  @spec boxes(Box.t()) :: integer()
  def boxes(%Box{n: 0}), do: 0
  def boxes(%Box{tag: :big, n: n}), do: n * 1000
  def boxes(%Box{n: n}), do: n

  @spec in_cond(integer()) :: integer()
  def in_cond(a) do
    v =
      cond do
        a > 5 -> get()
        true -> a
      end
    v + 100
  end

  @spec sup(pid()) :: :closed
  def sup(parent) do
    Process.flag(:trap_exit, true)
    child = spawn_link(fn -> loop(0) end)
    send(parent, {:child, child})
    receive do
      {:EXIT, ^child, :normal} -> send(parent, :closed)
      {:EXIT, ^child, _reason} -> sup(parent)
    end
  end

  @spec main() :: :ok
  def main do
    me = self()
    send(me, {:n, 1})
    send(me, {:n, 2})
    {a, x, y} = two(:a)
    IO.inspect({a, x, y})
    send(me, {:n, 4})
    IO.inspect(in_case(:wait, 5))
    IO.inspect(in_case(:no, 5))
    send(me, {:n, 4})
    IO.inspect(in_if(true))
    send(me, {:n, 4})
    IO.inspect(in_if(false))
    send(me, {:n, 9})
    send(me, {:n, 4})
    IO.inspect(nested())
    send(me, {:n, 4})
    IO.inspect(as_arg(3))
    send(me, {:n, 4})
    IO.inspect(piped(3))
    send(me, {:n, 10})
    send(me, {:n, 100})
    IO.inspect(rebind(1))
    send(me, {:n, 1})
    IO.inspect(subject())
    send(me, {:n, 10})
    send(me, {:n, 100})
    send(me, :stop)
    IO.inspect(after_loop(1))
    IO.inspect(timed())
    send(me, {:n, 7})
    IO.inspect(in_cond(9))
    IO.inspect(boxes(%Box{n: 3, tag: :big}))
    IO.inspect(boxes(%Box{n: 0, tag: :big}))
    spawn(Shapes, :sup, [me])
    child = receive do {:child, c} when is_pid(c) -> c end
    send(child, {:n, 1})
    send(child, :stop)
    receive do :closed -> IO.puts("closed") end
  end
end
