# edge_c: an edge node of the three-node example (hub topology). It dials hub@localhost, asks the hub's registered
# name :hub_in to double 34, and prints the answer, which the hub casts back to this node's registered name :c_inbox.
defmodule EdgeC do
  use Supervisor

  @silica_node [
    name: :"c@localhost",
    cookie_file: "cookie",
    peer: {:"hub@localhost", "localhost", :dial},
    redial: {250, 4000},
    remote: {:hub_in, :"hub@localhost", :request, [:atom, :integer]},
    local: {:c_inbox, :reply, [:integer]}
  ]

  @spec start_sup() :: :ok
  def start_sup do
    {:ok, _sup} = Supervisor.start_link(__MODULE__, [], name: EdgeC.Sup)
    :ok
  end

  @impl true
  def init([]) do
    children = [
      %{id: :c_inbox, start: {__MODULE__, :start_inbox, []}, restart: :transient}
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 10)
  end

  @spec start_inbox() :: {:ok, pid()}
  def start_inbox do
    pid = spawn_link(__MODULE__, :inbox, [0])
    Process.register(pid, :c_inbox)
    {:ok, pid}
  end

  # The argument is the sum of the answers so far.
  @spec inbox(integer()) :: :ok
  def inbox(sum) do
    receive do
      {:reply, v} when is_integer(v) ->
        IO.inspect({:c_got_answer, v})
        inbox(sum + v)
    end
  end

  # Start the inbox, ask the hub, and wait for the answer to arrive.
  @spec run() :: :ok
  def run do
    start_sup()
    send({:hub_in, :"hub@localhost"}, {:request, :c_inbox, 34})

    receive do
      :never -> :ok
    after
      8_000 -> :ok
    end
  end
end
