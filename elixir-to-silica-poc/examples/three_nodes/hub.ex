# hub: the middle node of the three-node example (hub topology). It listens for the two edge nodes, a@localhost and
# c@localhost, serves requests on the registered name :hub_in and answers each one by name on the edge that asked.
#
#   a@localhost --dial--> hub@localhost <--dial-- c@localhost
#
# A request is {:request, reply_to, n}: reply_to is the registered name the answer goes to (a pid does not cross a
# node; BEES sends to registered names, so the request says which name). The answer is {:reply, 2 * n}.
#
# Distribution is BEES's BEAM mode: EPMD (started with `epmd -daemon` if it is not running) and a cookie. The
# @silica_node attribute is what to-silica turns into BEES's manifest and bees.config (contract T9.17).
defmodule Hub do
  use Supervisor

  @silica_node [
    name: :"hub@localhost",
    cookie_file: "cookie",
    peer: {:"a@localhost", "localhost", :listen},
    peer: {:"c@localhost", "localhost", :listen},
    local: {:hub_in, :request, [:atom, :integer]},
    remote: {:a_inbox, :"a@localhost", :reply, [:integer]},
    remote: {:c_inbox, :"c@localhost", :reply, [:integer]}
  ]

  # --- the supervisor: one static child, registered as :hub_in
  @spec start_sup() :: :ok
  def start_sup do
    {:ok, _sup} = Supervisor.start_link(__MODULE__, [], name: Hub.Sup)
    :ok
  end

  @impl true
  def init([]) do
    children = [
      %{id: :hub_in, start: {__MODULE__, :start_hub_in, []}, restart: :transient}
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 10)
  end

  @spec start_hub_in() :: {:ok, pid()}
  def start_hub_in do
    pid = spawn_link(__MODULE__, :service, [0])
    Process.register(pid, :hub_in)
    {:ok, pid}
  end

  # --- the service: the argument is how many requests it has answered
  @spec service(integer()) :: :ok
  def service(served) do
    receive do
      {:request, reply_to, n} when is_atom(reply_to) and is_integer(n) ->
        IO.inspect({:hub_got, n, reply_to})
        answer(reply_to, n * 2)
        service(served + 1)
    end
  end

  # The answer goes to the name on the node that asked.
  @spec answer(atom(), integer()) :: :ok
  def answer(:a_inbox, v) do
    send({:a_inbox, :"a@localhost"}, {:reply, v})
    :ok
  end

  def answer(:c_inbox, v) do
    send({:c_inbox, :"c@localhost"}, {:reply, v})
    :ok
  end

  def answer(_other, _v), do: :ok

  # --- run/0, not main/0: BEES owns the node program's main, which starts the node and then calls run/0. Start the service and stay up while the edges talk to it
  @spec run() :: :ok
  def run do
    start_sup()

    receive do
      :never -> :ok
    after
      20_000 -> :ok
    end
  end
end
