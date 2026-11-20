# mesh_c: one node of the three-node mesh example (every node holds a link to both others).
#
#   ma@localhost <--dial-- mb@localhost
#        ^                      ^
#        +--dial-- mc@localhost +
#
# mb dials ma, mc dials ma and mb: three links, one for each pair. A link carries messages both ways, so which end
# dialed does not matter to the programs. This node: dials ma and mb.
#
# Every node does the same two things. It serves requests on its registered name :c_in: {:request, reply_to, n} is
# answered with {:reply, :c_in, 2 * n}, sent to the registered name reply_to on the node that asked. And it asks
# both other nodes to double a number, and prints each answer when it arrives at its registered name :c_inbox.
# So six requests and six answers cross the three links, each link in both directions.
#
# Distribution is BEES's BEAM mode: EPMD and a cookie (contract T9.17), as in examples/three_nodes.
defmodule MeshC do
  use Supervisor

  @silica_node [
    name: :"mc@localhost",
    cookie_file: "cookie",
    peer: {:"ma@localhost", "localhost", :dial},
    peer: {:"mb@localhost", "localhost", :dial},
    redial: {250, 4000},
    local: {:c_in, :request, [:atom, :integer]},
    local: {:c_inbox, :reply, [:atom, :integer]},
    remote: {:a_in, :"ma@localhost", :request, [:atom, :integer]},
    remote: {:b_in, :"mb@localhost", :request, [:atom, :integer]},
    remote: {:a_inbox, :"ma@localhost", :reply, [:atom, :integer]},
    remote: {:b_inbox, :"mb@localhost", :reply, [:atom, :integer]}
  ]

  # --- the supervisor: two static children, registered as :c_in and :c_inbox
  @spec start_sup() :: :ok
  def start_sup do
    {:ok, _sup} = Supervisor.start_link(__MODULE__, [], name: MeshC.Sup)
    :ok
  end

  @impl true
  def init([]) do
    children = [
      %{id: :c_in, start: {__MODULE__, :start_service, []}, restart: :transient},
      %{id: :c_inbox, start: {__MODULE__, :start_inbox, []}, restart: :transient}
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 10)
  end

  @spec start_service() :: {:ok, pid()}
  def start_service do
    pid = spawn_link(__MODULE__, :service, [0])
    Process.register(pid, :c_in)
    {:ok, pid}
  end

  @spec start_inbox() :: {:ok, pid()}
  def start_inbox do
    pid = spawn_link(__MODULE__, :inbox, [0])
    Process.register(pid, :c_inbox)
    {:ok, pid}
  end

  # --- the service: the argument is how many requests it has answered
  @spec service(integer()) :: :ok
  def service(served) do
    receive do
      {:request, reply_to, n} when is_atom(reply_to) and is_integer(n) ->
        IO.inspect({:c_got_request, n, reply_to})
        answer(reply_to, n * 2)
        service(served + 1)
    end
  end

  # The answer goes to the name on the node that asked, and says who answered.
  @spec answer(atom(), integer()) :: :ok
  def answer(:a_inbox, v) do
    send({:a_inbox, :"ma@localhost"}, {:reply, :c_in, v})
    :ok
  end

  def answer(:b_inbox, v) do
    send({:b_inbox, :"mb@localhost"}, {:reply, :c_in, v})
    :ok
  end

  def answer(_other, _v), do: :ok

  # --- the inbox: the argument is the sum of the answers so far
  @spec inbox(integer()) :: :ok
  def inbox(sum) do
    receive do
      {:reply, from, v} when is_atom(from) and is_integer(v) ->
        IO.inspect({:c_got_answer, from, v})
        inbox(sum + v)
    end
  end

  # --- run/0, not main/0 (BEES owns main). Start the two processes, ask both other nodes, and stay up while the
  # answers arrive and the other nodes ask this one.
  @spec run() :: :ok
  def run do
    start_sup()
    send({:a_in, :"ma@localhost"}, {:request, :c_inbox, 31})
    send({:b_in, :"mb@localhost"}, {:request, :c_inbox, 32})

    receive do
      :never -> :ok
    after
      15_000 -> :ok
    end
  end
end
