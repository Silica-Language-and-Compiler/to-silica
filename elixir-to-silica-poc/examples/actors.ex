# Actors: a small working application of three actors, written the way Elixir is usually written.
#
#   coordinator (main/0)  starts the supervisor, uses the account, prints what it learns
#   supervisor            starts the account linked to itself, restarts it if it ends abnormally, and tells the
#                         coordinator when it ends normally
#   account               holds an %Account{} and answers {:deposit, n}, {:withdraw, n, from}, {:report, from}
#                         and :stop
#
# Every type the transpiler needs is written in Elixir's own ways: an @spec on each function, the struct's @type,
# and a guard (is_integer/1, is_pid/1, is_atom/1) on what a receive clause binds. Each answer of the account has
# a tag of its own ({:withdrawn, n}, {:refused, n}, {:summary, text, balance, mean}): a message tag has one type
# in a unit (contract T9.12), and the client that waits for an answer says in its guards what the answer holds.
#
# Run it:   elixir -r examples/actors.ex -e "Actors.main()"
# It prints:
#   {:refused, 30}
#   {:ok, 40}
#   ada: low
#   {:balance, 40, :mean_move, 13.333333333333334}
#   account closed
defmodule Actors do
  # The account's state: a struct.
  defmodule Account do
    @type t :: %__MODULE__{owner: String.t(), balance: integer(), moves: integer()}
    defstruct owner: "", balance: 0, moves: 0
  end

  # --- pure functions on the state

  @spec open(String.t()) :: Account.t()
  def open(owner), do: %Account{owner: owner, balance: 0, moves: 0}

  @spec deposit(Account.t(), integer()) :: Account.t()
  def deposit(%Account{balance: balance, moves: moves} = account, amount) do
    %Account{account | balance: balance + amount, moves: moves + 1}
  end

  @spec withdraw(Account.t(), integer()) :: {:ok, Account.t()} | {:refused, integer()}
  def withdraw(%Account{balance: balance}, amount) when amount > balance, do: {:refused, amount - balance}
  def withdraw(account, amount), do: {:ok, deposit(account, -amount)}

  @spec level(integer()) :: :empty | :low | :healthy
  def level(balance) do
    cond do
      balance <= 0 -> :empty
      balance < 50 -> :low
      true -> :healthy
    end
  end

  @spec mean_move(integer(), integer()) :: float()
  def mean_move(_balance, 0), do: 0.0
  def mean_move(balance, moves), do: balance / moves

  @spec label(Account.t()) :: String.t()
  def label(%Account{owner: owner, balance: balance}) do
    case level(balance) do
      :empty -> owner <> ": empty"
      :low -> owner <> ": low"
      :healthy -> owner <> ": healthy"
    end
  end

  # --- the account actor: its state is the argument of its loop

  @spec account(Account.t()) :: :ok
  def account(state) do
    receive do
      {:deposit, amount} when is_integer(amount) and amount > 0 ->
        account(deposit(state, amount))

      {:withdraw, amount, from} when is_integer(amount) and is_pid(from) ->
        case withdraw(state, amount) do
          {:ok, next} ->
            send(from, {:withdrawn, next.balance})
            account(next)

          {:refused, short} ->
            send(from, {:refused, short})
            account(state)
        end

      {:report, from} when is_pid(from) ->
        send(from, {:summary, label(state), state.balance, mean_move(state.balance, state.moves)})
        account(state)

      :stop ->
        :ok
    end
  end

  # --- the supervisor actor: one linked child, restarted when it ends abnormally

  @spec supervisor(pid()) :: :account_closed
  def supervisor(parent) do
    Process.flag(:trap_exit, true)
    child = spawn_link(fn -> "ada" |> open() |> account() end)
    send(parent, {:account, child})

    receive do
      {:EXIT, ^child, :normal} -> send(parent, :account_closed)
      {:EXIT, ^child, reason} when is_atom(reason) -> supervisor(parent)
    end
  end

  # --- the account's client functions: a request, then the reply or a timeout

  @spec withdraw_from(pid(), integer()) :: {:ok, integer()} | {:refused, integer()}
  def withdraw_from(account, amount) do
    send(account, {:withdraw, amount, self()})

    receive do
      {:withdrawn, balance} when is_integer(balance) -> {:ok, balance}
      {:refused, short} when is_integer(short) -> {:refused, short}
    after
      1000 -> exit(:no_reply)
    end
  end

  @spec report(pid()) :: {String.t(), integer(), float()}
  def report(account) do
    send(account, {:report, self()})

    receive do
      {:summary, text, balance, mean} when is_binary(text) and is_integer(balance) and is_float(mean) ->
        {text, balance, mean}
    after
      1000 -> exit(:no_reply)
    end
  end

  # --- the coordinator: the program's entry point

  @spec main() :: :ok
  def main do
    spawn(Actors, :supervisor, [self()])

    account =
      receive do
        {:account, pid} when is_pid(pid) -> pid
      end

    send(account, {:deposit, 40})
    send(account, {:deposit, 30})
    IO.inspect(withdraw_from(account, 100))
    IO.inspect(withdraw_from(account, 30))
    {text, balance, mean} = report(account)
    IO.puts(text)
    IO.inspect({:balance, balance, :mean_move, mean})
    send(account, :stop)

    receive do
      :account_closed -> IO.puts("account closed")
    end
  end
end
