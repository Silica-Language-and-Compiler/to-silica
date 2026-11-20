# mesh5_d: one node of the five-node mesh example (every node holds a link to all four others: ten links).
#
# The nodes are na, nb, nc, nd and ne, all @localhost. A node dials every node whose letter comes before its own and
# listens for the rest, so each pair has one link. A link carries messages both ways, so which end dialed does not
# matter to the programs. This node: dials na, nb, nc; listens for ne.
#
# Every node does the same two things. It serves requests on its registered name d_in: a request names the
# registered name to answer to and a number, and is answered with this node's d_in and twice the number. And it
# asks all four other nodes to double a number (node 1..5 asks node 1..5 for the number 10 * asker + asked), and
# prints each answer when it arrives at its registered name d_inbox. So twenty requests and twenty answers cross
# the ten links, each link in both directions.
#
# Distribution is BEES's BEAM mode: EPMD and a cookie (contract T9.17), as in examples/three_nodes.
defmodule Mesh5D do
  use Supervisor

  @silica_node [
    name: :"nd@localhost",
    cookie_file: "cookie",
    peer: {:"na@localhost", "localhost", :dial},
    peer: {:"nb@localhost", "localhost", :dial},
    peer: {:"nc@localhost", "localhost", :dial},
    peer: {:"ne@localhost", "localhost", :listen},
    redial: {250, 4000},
    local: {:d_in, :request, [:atom, :integer]},
    local: {:d_inbox, :reply, [:atom, :integer]},
    remote: {:a_in, :"na@localhost", :request, [:atom, :integer]},
    remote: {:b_in, :"nb@localhost", :request, [:atom, :integer]},
    remote: {:c_in, :"nc@localhost", :request, [:atom, :integer]},
    remote: {:e_in, :"ne@localhost", :request, [:atom, :integer]},
    remote: {:a_inbox, :"na@localhost", :reply, [:atom, :integer]},
    remote: {:b_inbox, :"nb@localhost", :reply, [:atom, :integer]},
    remote: {:c_inbox, :"nc@localhost", :reply, [:atom, :integer]},
    remote: {:e_inbox, :"ne@localhost", :reply, [:atom, :integer]}
  ]

  # --- the supervisor: two static children, registered as :d_in and :d_inbox
  @spec start_sup() :: :ok
  def start_sup do
    {:ok, _sup} = Supervisor.start_link(__MODULE__, [], name: Mesh5D.Sup)
    :ok
  end

  @impl true
  def init([]) do
    children = [
      %{id: :d_in, start: {__MODULE__, :start_service, []}, restart: :transient},
      %{id: :d_inbox, start: {__MODULE__, :start_inbox, []}, restart: :transient}
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 10)
  end

  @spec start_service() :: {:ok, pid()}
  def start_service do
    pid = spawn_link(__MODULE__, :service, [0])
    Process.register(pid, :d_in)
    {:ok, pid}
  end

  @spec start_inbox() :: {:ok, pid()}
  def start_inbox do
    pid = spawn_link(__MODULE__, :inbox, [0])
    Process.register(pid, :d_inbox)
    {:ok, pid}
  end

  # --- the service: the argument is how many requests it has answered
  @spec service(integer()) :: :ok
  def service(served) do
    receive do
      {:request, reply_to, n} when is_atom(reply_to) and is_integer(n) ->
        IO.inspect({:d_got_request, n, reply_to})
        answer(reply_to, n * 2)
        service(served + 1)
    end
  end

  # The answer goes to the name on the node that asked, and says who answered.
  @spec answer(atom(), integer()) :: :ok
  def answer(:a_inbox, v) do
    send({:a_inbox, :"na@localhost"}, {:reply, :d_in, v})
    :ok
  end

  def answer(:b_inbox, v) do
    send({:b_inbox, :"nb@localhost"}, {:reply, :d_in, v})
    :ok
  end

  def answer(:c_inbox, v) do
    send({:c_inbox, :"nc@localhost"}, {:reply, :d_in, v})
    :ok
  end

  def answer(:e_inbox, v) do
    send({:e_inbox, :"ne@localhost"}, {:reply, :d_in, v})
    :ok
  end

  def answer(_other, _v), do: :ok

  # --- the inbox: the argument is the sum of the answers so far
  @spec inbox(integer()) :: :ok
  def inbox(sum) do
    receive do
      {:reply, from, v} when is_atom(from) and is_integer(v) ->
        IO.inspect({:d_got_answer, from, v})
        inbox(sum + v)
    end
  end

  # --- run/0, not main/0 (BEES owns main). Start the two processes, ask the four other nodes, and stay up while the
  # answers arrive and the other nodes ask this one.
  @spec run() :: :ok
  def run do
    start_sup()
    send({:a_in, :"na@localhost"}, {:request, :d_inbox, 41})
    send({:b_in, :"nb@localhost"}, {:request, :d_inbox, 42})
    send({:c_in, :"nc@localhost"}, {:request, :d_inbox, 43})
    send({:e_in, :"ne@localhost"}, {:request, :d_inbox, 45})

    receive do
      :never -> :ok
    after
      15_000 -> :ok
    end
  end
end
