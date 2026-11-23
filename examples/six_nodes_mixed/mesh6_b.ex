# mesh6_b: one node of the six-node mixed mesh (every node holds a link to all five others: fifteen links).
#
# The six nodes are written in four languages: xa and xd in Erlang, xb and xe in Elixir, xc in Gleam, and xf in
# Silica by hand. All are @localhost. A node dials every node whose letter comes before its own and listens for the
# rest, so each pair has one link. This node: dials xa; listens for xc, xd, xe, xf.
#
# Every node does the same two things, whatever its language. It serves requests on its registered name b_in: a
# request names the registered name to answer to (an atom) and a number, and is answered with this node's b_in
# and twice the number. And it asks all five other nodes to double a number (node 1..6 asks node 1..6 for the number
# 10 * asker + asked), and prints each answer when it arrives at its registered name b_inbox. So thirty requests
# and thirty answers cross the fifteen links, each link in both directions.
#
# Distribution is BEES's BEAM mode: EPMD and a cookie (contract T9.17).
defmodule Mesh6B do
  use Supervisor

  @silica_node [
    name: :"xb@localhost",
    cookie_file: "cookie",
    peer: {:"xa@localhost", "localhost", :dial},
    peer: {:"xc@localhost", "localhost", :listen},
    peer: {:"xd@localhost", "localhost", :listen},
    peer: {:"xe@localhost", "localhost", :listen},
    peer: {:"xf@localhost", "localhost", :listen},
    redial: {250, 4000},
    local: {:b_in, :request, [:atom, :integer]},
    local: {:b_inbox, :reply, [:atom, :integer]},
    remote: {:a_in, :"xa@localhost", :request, [:atom, :integer]},
    remote: {:c_in, :"xc@localhost", :request, [:atom, :integer]},
    remote: {:d_in, :"xd@localhost", :request, [:atom, :integer]},
    remote: {:e_in, :"xe@localhost", :request, [:atom, :integer]},
    remote: {:f_in, :"xf@localhost", :request, [:atom, :integer]},
    remote: {:a_inbox, :"xa@localhost", :reply, [:atom, :integer]},
    remote: {:c_inbox, :"xc@localhost", :reply, [:atom, :integer]},
    remote: {:d_inbox, :"xd@localhost", :reply, [:atom, :integer]},
    remote: {:e_inbox, :"xe@localhost", :reply, [:atom, :integer]},
    remote: {:f_inbox, :"xf@localhost", :reply, [:atom, :integer]}
  ]

  # --- the supervisor: two static children, registered as :b_in and :b_inbox
  @spec start_sup() :: :ok
  def start_sup do
    {:ok, _sup} = Supervisor.start_link(__MODULE__, [], name: Mesh6B.Sup)
    :ok
  end

  @impl true
  def init([]) do
    children = [
      %{id: :b_in, start: {__MODULE__, :start_service, []}, restart: :transient},
      %{id: :b_inbox, start: {__MODULE__, :start_inbox, []}, restart: :transient}
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 10)
  end

  @spec start_service() :: {:ok, pid()}
  def start_service do
    pid = spawn_link(__MODULE__, :service, [0])
    Process.register(pid, :b_in)
    {:ok, pid}
  end

  @spec start_inbox() :: {:ok, pid()}
  def start_inbox do
    pid = spawn_link(__MODULE__, :inbox, [0])
    Process.register(pid, :b_inbox)
    {:ok, pid}
  end

  # --- the service: the argument is how many requests it has answered
  @spec service(integer()) :: :ok
  def service(served) do
    receive do
      {:request, reply_to, n} when is_atom(reply_to) and is_integer(n) ->
        IO.inspect({:b_got_request, n, reply_to})
        answer(reply_to, n * 2)
        service(served + 1)
    end
  end

  # The answer goes to the name on the node that asked, and says who answered.
  @spec answer(atom(), integer()) :: :ok
  def answer(:a_inbox, v) do
    send({:a_inbox, :"xa@localhost"}, {:reply, :b_in, v})
    :ok
  end

  def answer(:c_inbox, v) do
    send({:c_inbox, :"xc@localhost"}, {:reply, :b_in, v})
    :ok
  end

  def answer(:d_inbox, v) do
    send({:d_inbox, :"xd@localhost"}, {:reply, :b_in, v})
    :ok
  end

  def answer(:e_inbox, v) do
    send({:e_inbox, :"xe@localhost"}, {:reply, :b_in, v})
    :ok
  end

  def answer(:f_inbox, v) do
    send({:f_inbox, :"xf@localhost"}, {:reply, :b_in, v})
    :ok
  end

  def answer(_other, _v), do: :ok

  # --- the inbox: the argument is the sum of the answers so far
  @spec inbox(integer()) :: :ok
  def inbox(sum) do
    receive do
      {:reply, from, v} when is_atom(from) and is_integer(v) ->
        IO.inspect({:b_got_answer, from, v})
        inbox(sum + v)
    end
  end

  # --- run/0, not main/0 (BEES owns main). Start the two processes, ask the five other nodes, and stay up while the
  # answers arrive and the other nodes ask this one.
  @spec run() :: :ok
  def run do
    start_sup()
    send({:a_in, :"xa@localhost"}, {:request, :b_inbox, 21})
    send({:c_in, :"xc@localhost"}, {:request, :b_inbox, 23})
    send({:d_in, :"xd@localhost"}, {:request, :b_inbox, 24})
    send({:e_in, :"xe@localhost"}, {:request, :b_inbox, 25})
    send({:f_in, :"xf@localhost"}, {:request, :b_inbox, 26})

    receive do
      :never -> :ok
    after
      15_000 -> :ok
    end
  end
end
