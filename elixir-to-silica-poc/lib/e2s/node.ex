defmodule E2s.Node do
  @moduledoc """
  A node program (contract T9.17). `@silica_node [...]` declares the node a module runs on, the nodes it talks to and
  the registered names that cross. The transpiler writes BEES's manifest and `bees.config` from the one form sent.

      @silica_node [
        name: :"hub@localhost",
        cookie_file: "cookie",
        peer: {:"a@localhost", "localhost", :listen},
        local: {:hub_in, :request, [:atom, :integer]},
        remote: {:a_inbox, :"a@localhost", :reply, [:integer]}
      ]

  * `name:` (required) the node's name
  * `peer: {node, host, :dial | :listen}` a node this one talks to; a dial peer is found through EPMD
  * `remote: {name, node, tag, kinds}` a registered name on `node`: `send({name, node}, {tag, ...})` casts to it
  * `local: {name, tag, kinds}` a registered name here that peers may cast `{tag, ...}` to
  * `redial: :off | {initial_ms, max_ms}` whether a lost link to a dial peer is dialed again; BEES has no default,
    so a node with a dial peer states it and a node without one leaves it out
  * optional: `creation:`, `listen_address:`, `listen_port:`, `epmd_port:`, `cookie_file:`, `net_ticktime_s:`

  `kinds` are `:integer | :float | :atom | :boolean | :binary`: what the fields of the message are (the node states
  every field's type, contract 8.6). The message is the tagged tuple `{tag, field...}`; BEES's wire carries it as
  the tuple `(atom, field...)`, which is the tagged tuple the unit's processes send and receive.
  """

  @doc "{the (:node) body or nil, the remote table %{{name, node} => tag}} of one module's forms."
  def forms(forms) do
    case Enum.find_value(forms, &declaration/1) do
      nil -> {nil, %{}}
      opts -> {body(opts), remotes(opts)}
    end
  end

  defp declaration({:@, _, [{:silica_node, _, [list]}]}), do: unwrap(list)
  defp declaration(_), do: nil

  # The source is parsed with every literal wrapped in a block (Code.string_to_quoted with a literal encoder).
  defp unwrap({:__block__, _, [x]}), do: unwrap(x)
  defp unwrap({:{}, _, elems}), do: elems |> Enum.map(&unwrap/1) |> List.to_tuple()
  defp unwrap({a, b}), do: {unwrap(a), unwrap(b)}
  defp unwrap(list) when is_list(list), do: Enum.map(list, &unwrap/1)
  defp unwrap(other), do: other

  defp text(a) when is_atom(a), do: Atom.to_string(a)
  defp text(s) when is_binary(s), do: s

  defp body(opts) do
    get = fn key, default -> Keyword.get(opts, key, default) end

    redial =
      case Keyword.get(opts, :redial) do
        :off -> {0, 0}
        {initial, max} -> {initial, max}
        nil -> {-1, -1}
      end

    {:node,
     %{
       name: text(Keyword.fetch!(opts, :name)),
       timing: %{creation: get.(:creation, 1), net_ticktime_s: get.(:net_ticktime_s, 60),
         redial_initial_ms: elem(redial, 0), redial_max_ms: elem(redial, 1)},
       net: %{
         listen_address: text(get.(:listen_address, "127.0.0.1")),
         listen_port: get.(:listen_port, 0),
         epmd_port: get.(:epmd_port, 4369),
         cookie_file: text(get.(:cookie_file, "cookie"))
       },
       tables: %{
         peers: for({:peer, {n, h, role}} <- opts, role in [:dial, :listen], do: %{name: text(n), host: text(h), port: 0, role: role}),
         remotes: for({:remote, {nm, n, tag, ks}} <- opts, do: %{name: text(nm), peer: text(n), tag: text(tag), fields: Enum.map(ks, &kind/1)}),
         locals: for({:local, {nm, tag, ks}} <- opts, do: %{name: text(nm), tag: text(tag), fields: Enum.map(ks, &kind/1)})
       }
     }}
  end

  defp remotes(opts), do: Map.new(for({:remote, {nm, n, tag, _}} <- opts, do: {{text(nm), text(n)}, text(tag)}))

  defp kind(:integer), do: "int64"
  defp kind(:float), do: "float64"
  defp kind(:atom), do: "atom"
  defp kind(:boolean), do: "boolean"
  defp kind(:binary), do: "string"
  defp kind(other), do: raise(ArgumentError, "@silica_node: a field kind is :integer, :float, :atom, :boolean or :binary, not #{inspect(other)}")
end
