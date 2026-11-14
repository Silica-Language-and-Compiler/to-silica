# Demo: the example program of elixir-to-silica-poc. One small function per construct of the subset.
#
# Every type the sender states comes from what is written here, in Elixir's own ways: an @spec on each
# function, a @type on each struct, and a guard (is_integer/1, is_pid/1) on what a receive clause binds
# (Elixir's messages have no declared type).
defmodule Demo do
  use Supervisor

  # A struct is the record idiom: it is sent as a type declaration (a record type with its fields).
  defmodule Point do
    @type t :: %__MODULE__{x: integer(), y: integer()}
    defstruct x: 0, y: 0
  end

  # --- basic types, operators, calls
  @spec add(integer(), integer()) :: integer()
  def add(a, b), do: a + b

  @spec scale(float(), integer()) :: float()
  def scale(f, n), do: f * n * 1.5

  @spec halves(integer()) :: {integer(), integer()}
  def halves(n), do: {div(n, 2), rem(n, 2)}

  # `/` always gives a float in Elixir: both integers are converted, and a zero divisor raises.
  @spec ratio(integer(), integer()) :: float()
  def ratio(a, b), do: a / b

  # A float next to an integer, a comparison of the two, and the way back to an integer.
  @spec percent(integer(), float()) :: integer()
  def percent(part, whole) do
    if whole > 0, do: round(part * 100 / whole), else: trunc(whole)
  end

  @spec differ(integer(), integer()) :: boolean()
  def differ(a, b), do: a != b and not (a === b)

  @spec greet(String.t()) :: String.t()
  def greet(name), do: "hello, " <> name

  # --- tuples and structs
  @spec swap({integer(), boolean()}) :: {boolean(), integer()}
  def swap({a, b}), do: {b, a}

  @spec origin() :: Point.t()
  def origin, do: %Point{x: 0, y: 0}

  @spec move(Point.t(), integer(), integer()) :: Point.t()
  def move(p, dx, dy) do
    %Point{x: x} = p
    %Point{p | x: x + dx, y: p.y + dy}
  end

  @spec x_of(Point.t()) :: integer()
  def x_of(%Point{x: x}), do: x

  # --- an alias pattern, a rebinding, truthiness
  @spec shift(Point.t(), integer()) :: Point.t()
  def shift(%Point{x: x} = p, dx), do: %Point{p | x: x + dx}

  @spec doubled_sum(integer(), integer()) :: integer()
  def doubled_sum(a, b) do
    sum = a + b
    sum = sum * 2
    sum
  end

  # --- clauses, patterns, guards, case, cond, if
  @spec classify(integer()) :: :negative | :zero | :positive
  def classify(n) when n < 0, do: :negative
  def classify(0), do: :zero
  def classify(_), do: :positive

  @spec area({:square, float()} | {:rectangle, float(), float()} | {:circle, float()}) :: float()
  def area({:square, side}), do: side * side
  def area({:rectangle, w, h}) when w > 0 and h > 0, do: w * h
  def area({:circle, r}), do: 3.14159 * r * r
  def area(_), do: exit(:badarg)

  @spec describe(integer()) :: String.t()
  def describe(n) do
    case classify(n) do
      :zero -> "zero"
      _ -> "not zero"
    end
  end

  @spec max_of(integer(), integer()) :: integer()
  def max_of(a, b) do
    if a >= b do
      a
    else
      b
    end
  end

  @spec sign(integer()) :: integer()
  def sign(n) do
    cond do
      n < 0 -> -1
      n == 0 -> 0
      true -> 1
    end
  end

  # --- functions as values: fn, &name/arity, f.(x), the pipe
  @spec twice((integer() -> integer()), integer()) :: integer()
  def twice(f, x), do: f.(f.(x))

  @spec add_three(integer()) :: integer()
  def add_three(n), do: n |> add(1) |> add(2)

  # The fn is written where twice/2's @spec declares a function type, so its parameter has a type. It uses no
  # variable of add_ten/1, so the sender sends it as a function of the module (README, "A fn that captures
  # nothing").
  @spec add_ten(integer()) :: integer()
  def add_ten(n), do: twice(fn x -> add(x, 5) end, n)

  @spec adder() :: (integer(), integer() -> integer())
  def adder, do: &add/2

  # --- processes: spawn, send, receive
  @spec ping_pong(integer()) :: integer() | :timeout
  def ping_pong(n) do
    pong = spawn(fn -> pong_loop() end)
    send(pong, {:ping, self(), n})

    receive do
      {:pong, m} when is_integer(m) ->
        send(pong, :stop)
        m
    after
      1000 -> :timeout
    end
  end

  @spec pong_loop() :: :ok
  def pong_loop do
    receive do
      {:ping, from, n} when is_pid(from) and is_integer(n) ->
        send(from, {:pong, add(n, 1)})
        pong_loop()

      :stop ->
        :ok
    end
  end

  # --- a hand-written actor with state
  @spec start_counter() :: pid()
  def start_counter, do: spawn(Demo, :counter, [0])

  @spec counter(integer()) :: integer()
  def counter(total) do
    receive do
      {:add, n} when is_integer(n) ->
        counter(total + n)

      {:get, from} when is_pid(from) ->
        send(from, {:total, total})
        counter(total)

      :stop ->
        total
    end
  end

  # --- a supervisor with a static child list: Elixir's Supervisor, with this module as its callback module.
  #     The children are fixed when the supervisor starts: here one, a counter registered as :tally. The sender
  #     reads init/1 and the child's start function and sends the child as a static child of the unit's
  #     supervisor (README, "A static supervisor").
  @spec start_sup() :: :ok
  def start_sup do
    {:ok, _sup} = Supervisor.start_link(__MODULE__, [], name: Demo.Sup)
    :ok
  end

  @impl true
  def init([]) do
    children = [
      %{id: :tally, start: {__MODULE__, :start_tally, [0]}, restart: :transient}
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 10)
  end

  # The child's start function: the supervisor calls it when it starts, and again for each restart.
  @spec start_tally(integer()) :: {:ok, pid()}
  def start_tally(start) do
    pid = spawn_link(__MODULE__, :counter, [start])
    Process.register(pid, :tally)
    {:ok, pid}
  end

  # The supervised child is talked to by its registered name.
  @spec tally_add(integer()) :: :ok
  def tally_add(n) do
    send(:tally, {:add, n})
    :ok
  end

  @spec tally_total() :: integer() | :timeout
  def tally_total do
    send(:tally, {:get, self()})

    receive do
      {:total, total} when is_integer(total) -> total
    after
      1000 -> :timeout
    end
  end

  @spec tally_stop() :: :ok
  def tally_stop do
    send(:tally, :stop)
    :ok
  end
end
