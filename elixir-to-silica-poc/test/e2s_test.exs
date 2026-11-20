defmodule E2sTest do
  @moduledoc """
  The test of elixir-to-silica-poc.

  Offline: every frame made from examples/demo.ex passes the Erlang binding's checker
  (../contract/bindings/erlang/check_frame.erl, compiled into the test build by mix.exs), the node tables are in
  post-order (T9.2), and the example covers the proof of concept's subset.

  Two kinds of small test follow. The **mapping** tests (`body/1`, `clauses/1`) give a snippet with no types and
  look at the nodes of the construct alone: they run the codex with `strict: false`, which sends a node whose
  type is unknown as it is. The **typing** tests (`typed/1`) give a module with `@spec`s and run the codex as
  the command line does: every type stated, every conversion written, a gap where a type is missing (contract 8.6).

  Online: the same frames, sent to a transpiler in check mode (contract 6.5), end with status :ok. It runs only
  when TO_SILICA_PORT is set: `TO_SILICA_PORT=7411 mix test`.
  """
  use ExUnit.Case, async: true

  alias E2s.Codex

  @demo Path.expand("../examples/demo.ex", __DIR__)
  @actors Path.expand("../examples/actors.ex", __DIR__)
  @shapes Path.expand("fixtures/split_shapes.ex", __DIR__)
  # What examples/demo.ex used to leave out on purpose, and test/fixtures/gaps.ex now holds (see its header):
  # 5 for a type the sender cannot state, 1 for a construct outside the subset.
  @gaps Path.expand("fixtures/gaps.ex", __DIR__)
  @expected_gaps 6

  # The node kinds of the subset; examples/demo.ex must use every one but those of @gap_kinds, which
  # test/fixtures/gaps.ex has (the transpiler writes no link, contract T9.15, so the example has none).
  @kinds [:int, :float, :text, :symbol, :boolean, :tuple, :record, :field, :var, :wild, :match, :block, :case,
          :clause, :cond, :op, :call, :apply, :lambda, :fun_ref, :self, :spawn, :send, :receive, :fail,
          :register, :send_named]
  @gap_kinds [:link, :exit_signal, :gap_node]

  setup_all do
    %{frames: Codex.frames([@demo], :check), gap_frames: Codex.frames([@gaps], :check)}
  end

  describe "offline, examples/demo.ex" do
    test "every frame passes check_frame", %{frames: frames} do
      for frame <- frames do
        assert :check_frame.check(frame) == :ok, "#{inspect(frame, limit: 6)}"
      end

      wire = for frame <- frames, bytes = :erlang.term_to_binary(frame), into: <<>>, do: <<byte_size(bytes)::32, bytes::binary>>
      assert :check_frame.check_wire(wire) == :ok
    end

    test "check_frame does reject a wrong frame" do
      assert {:error, _, _} = :check_frame.check({:form, %{seq: 1, unit_name: :Demo, body: :nothing}})
    end

    test "the session is hello, one unit, end", %{frames: frames} do
      assert [{:hello, hello}, {:unit_begin, unit} | rest] = frames
      assert %{contract: 1, session: "", sender: %{language: "elixir", prefix: "ex_", codex: "elixir-to-silica-poc"}} = hello
      assert %{profile: :bees, hints: %{proven: :trust, declared: :check, inferred: :check}, run: %{mode: :check}} = hello.options
      assert Enum.map(hello.options.choices, & &1.requirement) == ~w(a3_2 a3_3 a3_4 a4_2 a4_3 a4_4 a5_1 a5_4 a5_5 a6_8 a7_1)a
      assert %{unit_name: "Demo", silica_unit: "ex_demo", source: "demo.ex"} = unit
      forms = for {:form, form} <- rest, do: form
      assert [{:unit_end, %{unit_name: "Demo", forms: n}}, {:end, %{units: 1}}] = Enum.take(rest, -2)
      assert n == length(forms)
    end

    test "children come before parents (T9.2)", %{frames: frames} do
      for {:form, %{body: {:function, %{head: head, code: %{nodes: nodes, locations: locations, clauses: clauses}}}}} <- frames do
        assert length(locations) == length(nodes)

        for {node, i} <- Enum.with_index(nodes) do
          assert elem(node, 1) == i, "#{head.name}: at of node #{i}"
          for child <- children(node), do: assert(child < i and child >= -1, "#{head.name}: node #{i} #{inspect(node)}")
        end

        for c <- clauses, do: assert(match?({:clause, _, ps, _, _} when length(ps) == head.arity, Enum.at(nodes, c)))
      end
    end

    test "type tables are in post-order too and hints point into them", %{frames: frames} do
      for {:form, %{body: {:function, %{types: types, notes: %{hints: hints}} = function}}} <- frames do
        for {type, i} <- Enum.with_index(types), is_tuple(type), field <- tl(Tuple.to_list(type)), is_list(field) or is_integer(field) do
          for child <- List.wrap(field), is_integer(child), do: assert(child < i)
        end

        # T8.10 (a): every function form has its signature, first, as a (:t_fun) with one type for each
        # parameter: declared (the @spec), or inferred for a function the split made (from the calls of it).
        # T8.5: at most one hint for a node, each pointing at a node and a type of the form.
        assert [%{node: -1, strength: strength, policy: :default, type: sig} | rest] = hints
        assert strength == if(function.head.name =~ ~r/__(k\d+|c\d+|l)$/, do: :inferred, else: :declared)
        assert {:t_fun, params, _} = Enum.at(types, sig)
        assert length(params) == function.head.arity
        assert Enum.uniq_by(hints, & &1.node) == hints

        for hint <- rest do
          assert hint.node in 0..(length(function.code.nodes) - 1)
          assert hint.type in 0..(length(types) - 1)
          assert hint.strength in [:declared, :inferred] and hint.policy == :default
        end
      end
    end

    test "seq counts from 0 (T5.1)", %{frames: frames} do
      assert (for {_, %{seq: seq}} <- frames, do: seq) == Enum.to_list(0..(length(frames) - 2))
    end

    test "identifiers are binaries, never atoms (T4.4)", %{frames: frames} do
      for node <- nodes(frames), field <- tl(Tuple.to_list(node)) do
        refute is_atom(field) and not is_boolean(field), inspect(node)
      end

      for {:form, %{unit_name: name, body: {_, body}}} <- frames do
        assert is_binary(name)
        if head = body[:head], do: assert(is_binary(head.name) and is_binary(head.file))
      end

      assert {:symbol, _, "ok"} = Enum.find(nodes(frames), &match?({:symbol, _, "ok"}, &1))
    end

    test "the example covers the subset", %{frames: frames, gap_frames: gap_frames} do
      kinds = frames |> nodes() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      assert @kinds -- kinds == []
      assert kinds -- @kinds == [], "the example has no gap, no link and no exit request"
      assert @gap_kinds -- (gap_frames |> nodes() |> Enum.map(&elem(&1, 0))) == []
      # (A spawn_link under Process.flag(:trap_exit, true) is lowered by the sender, "the split" below; a linked
      # spawn node is what any other spawn_link is sent as.)
      assert Enum.any?(body("spawn_link(fn -> f() end)"), &match?({:spawn, _, _, _, true}, &1)), "a linked spawn"
      assert Enum.any?(nodes(frames), &match?({:record, _, "demo_point", _, base} when base >= 0, &1)), "a struct update"
      assert Enum.any?(nodes(frames), &match?({:receive, _, _, timeout, _} when timeout >= 0, &1)), "receive with after"
      assert Enum.any?(frames, &match?({:form, %{body: {:type, %{head: %{name: "demo_point"}}}}}, &1)), "defstruct"
    end

    test "operators use the Appendix B spellings", %{frames: frames} do
      ops = for {:op, _, op, _} <- nodes(frames), uniq: true, do: op
      allowed = ~w(+ - * div rem / neg to_float trunc round == /= < =< > >= =:= =/= and or not andalso orelse band bor bxor bnot bsl bsr ++ <>)
      assert ops -- allowed == []
      assert ~w(/= =:= andalso not div rem <> / to_float trunc round) -- ops == []
    end

    test "@spec becomes a declared hint on the signature", %{frames: frames} do
      assert %{types: types} = function(frames, "swap", 1)
      # A type is written into the table once; children come before their parent.
      assert types == [{:t_int, :i64}, {:t_basic, :boolean}, {:t_tuple, [0, 1]}, {:t_tuple, [1, 0]}, {:t_fun, [2], 3}]
      assert Enum.take(function(frames, "classify", 1).types, 3) == [{:t_int, :i64}, {:t_symbols, ["negative", "zero", "positive"]}, {:t_fun, [0], 1}]
      assert function(frames, "greet", 1).types == [{:t_basic, :text}, {:t_fun, [0], 0}]
      assert Enum.take(function(frames, "start_counter", 0).types, 3) == [{:t_basic, :dynamic}, {:t_actor, 0}, {:t_fun, [], 1}]
      assert Enum.take(function(frames, "origin", 0).types, 2) == [{:t_named, "demo_point", []}, {:t_fun, [], 0}]
    end

    test "no @spec, no signature: the function cannot be typed and is a gap form (T8.10 a)", %{gap_frames: frames} do
      assert function(frames, "max_of", 2) == nil
      assert %{types: _} = function(frames, "add", 2)
    end

    test "the type form comes before every form that names it (T8.14)", %{frames: frames} do
      assert [{:unit_begin, _}, {:form, %{body: {:type, %{head: %{name: "demo_point"}}}}} | _] = tl(frames)
    end

    test "examples/demo.ex by eye: ratio/2 is to_float on both operands under the zero guard (T8.12, T8.15)", %{frames: frames} do
      f = function(frames, "ratio", 2)

      assert f.code.nodes == [
               {:var, 0, "a"}, {:var, 1, "b"}, {:var, 2, "a"}, {:var, 3, "b"},
               {:op, 4, "to_float", [2]}, {:op, 5, "to_float", [3]},
               {:float, 6, "0.0"}, {:op, 7, "==", [5, 6]}, {:symbol, 8, "badarith"}, {:fail, 9, 8}, {:clause, 10, [], 7, 9},
               {:boolean, 11, true}, {:var, 12, "b"}, {:op, 13, "to_float", [12]}, {:op, 14, "/", [4, 13]}, {:clause, 15, [], 11, 14},
               {:cond, 16, [10, 15]}, {:clause, 17, [0, 1], -1, 16}
             ]

      assert hints(f) == %{-1 => {{:t_fun, [int(), int()], float()}, :declared}, 0 => {int(), :declared}, 1 => {int(), :declared},
                           16 => {float(), :inferred}}
    end

    test "the example has no gap", %{frames: frames} do
      assert gaps(frames) == 0
      assert Codex.gaps(frames) == []
      assert Codex.gaps(Codex.frames([@actors], :check)) == []
    end

    test "out-of-scope constructs are gaps (T9.10): test/fixtures/gaps.ex", %{gap_frames: frames} do
      for frame <- frames, do: assert(:check_frame.check(frame) == :ok, "#{inspect(frame, limit: 6)}")
      assert gaps(frames) == @expected_gaps
      assert length(Codex.gaps(frames)) == @expected_gaps
      notes = for {:gap_node, _, construct, note} <- nodes(frames), do: {construct, note}
      assert {":rpc.call/4", "inter-node communication is outside the proof of concept"} in notes
      # a closure is no gap of this sender: it is sent as a (:lambda) with its function type (H36)
      add_n = function(frames, "add_n", 2)
      assert Enum.any?(add_n.code.nodes, &match?({:lambda, _, [_]}, &1))
      refute Enum.any?(add_n.code.nodes, &match?({:gap_node, _, _, _}, &1))
    end

    test "a type the sender cannot state is a gap that says which type and why (contract 8.6)", %{gap_frames: frames} do
      reasons = for {_unit, form, _line, "missing type: " <> what, note} <- Codex.gaps(frames), do: {form, what, note}
      assert [{"area", "function signature", area}, {"max_of", "function signature", max_of}, {"boxed/1", "parameter of a fn", boxed},
              {"sum_list", "function signature", sum_list}] = reasons

      assert area =~ "number() is integer() or float()"
      assert max_of =~ "max_of/2 has no @spec"
      assert boxed =~ "Elixir writes no type on a fn's parameters"
      assert sum_list =~ "[integer()] is outside the subset"
      assert [{"name_or/2", "type rule: operands of =:=", _}] = for({_, form, _, "type rule: " <> _ = c, n} <- Codex.gaps(frames), do: {form, c, n})
    end

    test "the same source gives the same bytes", %{frames: frames} do
      assert :erlang.term_to_binary(frames) == :erlang.term_to_binary(Codex.frames([@demo], :check))
    end
  end

  describe "offline, small sources" do
    test "the parser is the gate: source that does not parse gives no frames" do
      assert_raise Codex.Error, ~r/does not parse/, fn -> Codex.string("defmodule Broken do\n  def f(, do: 1\nend\n") end
      assert_raise Codex.Error, ~r/defines no module/, fn -> Codex.string("1 + 1\n") end
    end

    test "module names become prefixed Silica unit names (T5.2)" do
      assert [{:unit_begin, %{seq: 5, unit_name: "My.HTTPMod", silica_unit: "ex_my_http_mod"}}, {:unit_end, %{seq: 6, forms: 0}}] =
               Codex.string("defmodule My.HTTPMod do\nend\n", "m.ex", 5)
    end

    test "inter-node communication is always a gap" do
      for source <- ["Node.spawn(n, fn -> :ok end)", "node()", "send({:name, n}, :hi)", ":erpc.call(n, M, :f, [])",
                     ":global.whereis_name(:x)", "Node.list()", "spawn(n, fn -> :ok end)", "Node.self()"] do
        assert [{:gap_node, 0, _, note}, {:clause, 1, [], -1, 0}] = body(source), source
        assert note =~ "another node" or note =~ "inter-node", source
      end
    end

    test "registered names, OTP behaviours, try and the rest of what is out of scope are gaps" do
      for source <- ["Process.register(self(), :name)", "Process.whereis(:name)", "GenServer.call(pid, :get)",
                     "Supervisor.start_link([], strategy: :one_for_one)", "Task.async(fn -> 1 end)",
                     "[1, 2]", "[a: 1]", "%{a: 1}", "\"a\#{x}\"", "<<1, 2>>", "for x <- xs, do: x", "~r/a/",
                     "with {:ok, x} <- f(), do: x", "raise \"no\"", "try do\n 1\n rescue\n _ -> 2\n end",
                     "try do\n 1\n catch\n _ -> 2\n end", "Process.flag(:trap_exit, true)", "f(^x = 1)"] do
        nodes = body(source)
        assert Enum.count(nodes, &(elem(&1, 0) == :gap_node)) == 1, "#{source}: #{inspect(nodes)}"
      end
    end

    test "module-level constructs outside the subset are form gaps" do
      source = "defmodule G do\n  use GenServer\n  import Enum\n  @type id :: integer()\n  defmacro m(x), do: x\n  def f(x \\\\ 1), do: x\nend\n"
      frames = Codex.string(source, "nofile", 0, strict: false)
      assert (for {:form, %{body: {:gap, %{construct: c, place: %{line: l}}}}} <- frames, do: {c, l}) ==
               [{"use", 2}, {"import", 3}, {"@type", 4}, {"defmacro", 5}, {"default arguments (\\\\)", 6}]
      for frame <- frames, do: assert(:check_frame.check(frame) == :ok)
    end

    test "process built-ins and calls" do
      assert [{:self, 0}, {:symbol, 1, "kill"}, {:exit_signal, 2, 0, 1}, _] = body("Process.exit(self(), :kill)")
      assert [{:var, 0, "p"}, {:link, 1, 0}, _] = body("Process.link(p)")
      assert [{:fun_ref, 0, "M", "run", 2}, {:int, 1, 1}, {:var, 2, "x"}, {:spawn, 3, 0, [1, 2], true}, _] = body("spawn_link(M, :run, [1, x])")
      assert [{:var, 0, "x"}, {:call, 1, "lists", "reverse", [0]}, _] = body(":lists.reverse(x)")
      assert [{:var, 0, "x"}, {:call, 1, "String", "upcase", [0]}, _] = body("x |> String.upcase()")
      assert [{:var, 0, "x"}, {:call, 1, "Kernel", "is_integer", [0]}, _] = body("is_integer(x)")
      assert [{:var, 0, "x"}, {:call, 1, "", "helper", [0]}, _] = body("helper(x)")
      assert [{:fun_ref, 0, "String", "upcase", 1}, _] = body("&String.upcase/1")
      assert [{:int, 0, -3}, _] = body("-3")
      assert [{:float, 0, "-0.5"}, _] = body("-0.5")
      assert [{:var, 0, "x"}, {:op, 1, "neg", [0]}, _] = body("-x")
      assert [{:symbol, 0, "nil"}, _] = body("nil")
      assert [{:var, 0, "a"}, {:var, 1, "b"}, {:op, 2, "<", [0, 1]}, {:int, 3, 1}, {:clause, 4, [], 2, 3}, {:boolean, 5, true},
              {:symbol, 6, "nil"}, {:clause, 7, [], 5, 6}, {:cond, 8, [4, 7]}, _] = body("if a < b do\n 1\n end")
    end
  end

  # One small test per mapping: a source snippet in, the expected nodes out. Copy one of these for a new mapping.
  describe "mappings added for the sender-side gaps" do
    test "alias pattern: (:match, at, left pattern, right pattern) in pattern position (H18 read with 9.4)" do
      assert [{:var, 0, "a"}, {:var, 1, "b"}, {:tuple, 2, [0, 1]}, {:var, 3, "t"}, {:match, 4, 2, 3}, {:var, 5, "t"},
              {:clause, 6, [4], -1, 5}] = clauses("def f({a, b} = t), do: t")

      # in a case clause, and nested inside a tuple
      nodes = body("case v do\n  {:ok, {x, _} = pair} -> {x, pair}\nend")
      assert {:match, _, tuple, pair} = Enum.find(nodes, &(elem(&1, 0) == :match))
      assert {:tuple, _, [_, _]} = Enum.at(nodes, tuple)
      assert {:var, _, "pair"} = Enum.at(nodes, pair)
    end

    test "pin in a clause: a stand-in variable and `stand-in =:= pinned` in the clause's guard (H29)" do
      assert [{:var, 0, "v"}, {:symbol, 1, "ok"}, {:var, 2, "_pin_1"}, {:tuple, 3, [1, 2]}, {:var, 4, "_pin_1"}, {:var, 5, "x"},
              {:op, 6, "=:=", [4, 5]}, {:int, 7, 1}, {:clause, 8, [3], 6, 7}, {:case, 9, 0, [8]}, _] =
               body("case v do\n  {:ok, ^x} -> 1\nend")
    end

    test "pin in a clause that has a guard: the pin's test, andalso the guard" do
      nodes = body("receive do\n  {^ref, n} when n > 0 -> n\nend")
      assert {:clause, _, [_], guard, _} = Enum.find(nodes, &match?({:clause, _, [_], _, _}, &1))
      assert {:op, _, "andalso", [pin, user]} = Enum.at(nodes, guard)
      assert {:op, _, "=:=", _} = Enum.at(nodes, pin)
      assert {:op, _, ">", _} = Enum.at(nodes, user)
    end

    test "pin in a `=` statement: the match, then true = (stand-in =:= pinned) (H18)" do
      assert [{:symbol, 0, "ok"}, {:var, 1, "_pin_1"}, {:tuple, 2, [0, 1]}, {:var, 3, "v"}, {:match, 4, 2, 3},
              {:boolean, 5, true}, {:var, 6, "_pin_1"}, {:var, 7, "x"}, {:op, 8, "=:=", [6, 7]}, {:match, 9, 5, 8},
              {:symbol, 10, "done"}, {:block, 11, [4, 9, 10]}, _] = body("{:ok, ^x} = v\n:done")
    end

    test "pin in a `=` used for its value is a gap: there is no guard to carry the test" do
      assert [{:gap_node, _, "pin operator (^) in a match used for its value", _}] =
               Enum.filter(body("f(^x = v)"), &(elem(&1, 0) == :gap_node))
    end

    test "rebinding: each binding has its own name, a reference uses the binding it sees" do
      assert [{:var, 0, "x"}, {:int, 1, 1}, {:match, 2, 0, 1}, {:var, 3, "x_1"}, {:var, 4, "x"}, {:int, 5, 1}, {:op, 6, "+", [4, 5]},
              {:match, 7, 3, 6}, {:var, 8, "x_1"}, {:block, 9, [2, 7, 8]}, _] = body("x = 1\nx = x + 1\nx")
    end

    test "rebinding: a generated name avoids the names the source uses" do
      vars = for {:var, _, name} <- body("x_1 = 0\nx = 1\nx = 2\n{x, x_1}"), do: name
      assert vars == ["x_1", "x", "x_2", "x_2", "x_1"]
    end

    test "rebinding: a binding made in a clause of case, cond, receive or fn ends with the clause" do
      vars = for {:var, _, name} <- body("x = 1\ny = case x do\n  1 -> x = 2\n  x\nend\n{x, y}"), do: name
      assert vars == ["x", "y", "x", "x_1", "x_1", "x", "y"]

      # a closure's parameter is a binding of its own; after the closure the outer x is seen again
      vars = for {:var, _, name} <- body("x = 1\nf = fn x -> x end\nf.(x)"), do: name
      assert vars == ["x", "f", "x_1", "x_1", "f", "x"]
    end

    test "rebinding: the clauses of a function each start with nothing bound" do
      vars = for {:var, _, name} <- clauses("def f(a, 0), do: a\n  def f(a, b), do: a + b"), do: name
      assert vars == ["a", "a", "a", "b", "a", "b"]
    end

    test "truthiness: a condition that is boolean by its syntax stays a cond (H30)" do
      for source <- ["if a == b, do: 1, else: 2", "if is_integer(a), do: 1, else: 2", "if not a, do: 1, else: 2",
                     "if a > 0 and b > 0, do: 1, else: 2", "cond do\n  a < 0 -> 1\n  true -> 2\nend"] do
        kinds = Enum.map(body(source), &elem(&1, 0))
        assert :cond in kinds and :case not in kinds, source
      end
    end

    test "truthiness: if on any other condition is a case that tests the value once" do
      assert [{:var, 0, "c"}, {:var, 1, "_truthy"}, {:var, 2, "_truthy"}, {:boolean, 3, false}, {:op, 4, "=:=", [2, 3]},
              {:var, 5, "_truthy"}, {:symbol, 6, "nil"}, {:op, 7, "=:=", [5, 6]}, {:op, 8, "orelse", [4, 7]},
              {:int, 9, 2}, {:clause, 10, [1], 8, 9}, {:wild, 11}, {:int, 12, 1}, {:clause, 13, [11], -1, 12},
              {:case, 14, 0, [10, 13]}, _] = body("if c, do: 1, else: 2")
    end

    test "truthiness: cond with a condition that is not boolean" do
      # cond do a < 0 -> 1; f(a) -> 2; true -> 3 end
      #   = cond do a < 0 -> 1; true -> case f(a) do falsy -> cond do true -> 3 end; _ -> 2 end end
      nodes = body("cond do\n  a < 0 -> 1\n  f(a) -> 2\n  true -> 3\nend")
      assert {:cond, _, [first, second]} = List.last(Enum.filter(nodes, &(elem(&1, 0) == :cond)))
      assert {:clause, _, [], _, one} = Enum.at(nodes, first)
      assert {:int, _, 1} = Enum.at(nodes, one)
      assert {:clause, _, [], always, tested} = Enum.at(nodes, second)
      assert {:boolean, _, true} = Enum.at(nodes, always)
      assert {:case, _, subject, [falsy, truthy]} = Enum.at(nodes, tested)
      assert {:call, _, "", "f", [_]} = Enum.at(nodes, subject)
      assert {:clause, _, [_], _, inner} = Enum.at(nodes, falsy)
      assert {:cond, _, [_]} = Enum.at(nodes, inner)
      assert {:clause, _, [_], -1, two} = Enum.at(nodes, truthy)
      assert {:int, _, 2} = Enum.at(nodes, two)

      # no clause left: the falsy branch fails, as CondClauseError does
      assert Enum.any?(body("cond do\n  f(a) -> 1\nend"), &match?({:fail, _, _}, &1))
    end

    test "truthiness: &&, || and !" do
      assert [{:var, 0, "a"}, {:var, 1, "b"}, {:op, 2, "<", [0, 1]}, {:var, 3, "b"}, {:var, 4, "c"}, {:op, 5, "<", [3, 4]},
              {:op, 6, "andalso", [2, 5]}, _] = body("a < b && b < c")

      assert [{:var, 0, "a"}, {:var, 1, "b"}, {:op, 2, "==", [0, 1]}, {:op, 3, "not", [2]}, _] = body("!(a == b)")

      # a && b: case a do t when falsy -> t; _ -> b end
      nodes = body("a && b")
      assert {:case, _, 0, [falsy, truthy]} = Enum.find(nodes, &(elem(&1, 0) == :case))
      assert {:clause, _, [t], _, t_again} = Enum.at(nodes, falsy)
      assert {:var, _, "_truthy"} = Enum.at(nodes, t)
      assert {:var, _, "_truthy"} = Enum.at(nodes, t_again)
      assert {:clause, _, [wild], -1, b} = Enum.at(nodes, truthy)
      assert {:wild, _} = Enum.at(nodes, wild)
      assert {:var, _, "b"} = Enum.at(nodes, b)

      # a || b: case a do t when falsy -> b; t -> t end
      nodes = body("a || b")
      assert {:case, _, 0, [falsy, truthy]} = Enum.find(nodes, &(elem(&1, 0) == :case))
      assert {:clause, _, [_], _, b} = Enum.at(nodes, falsy)
      assert {:var, _, "b"} = Enum.at(nodes, b)
      assert {:clause, _, [t], -1, t_again} = Enum.at(nodes, truthy)
      assert {:var, _, name} = Enum.at(nodes, t)
      assert {:var, _, ^name} = Enum.at(nodes, t_again)

      # !a: case a do t when falsy -> true; _ -> false end
      nodes = body("!a")
      assert {:case, _, 0, [falsy, truthy]} = Enum.find(nodes, &(elem(&1, 0) == :case))
      assert {:clause, _, [_], _, yes} = Enum.at(nodes, falsy)
      assert {:boolean, _, true} = Enum.at(nodes, yes)
      assert {:clause, _, [_], -1, no} = Enum.at(nodes, truthy)
      assert {:boolean, _, false} = Enum.at(nodes, no)
    end

    test "is_nil(x) is x =:= nil" do
      assert [{:var, 0, "x"}, {:symbol, 1, "nil"}, {:op, 2, "=:=", [0, 1]}, _] = body("is_nil(x)")
    end
  end

  # One small test per typing rule: a typed module in, the nodes and hints out. Copy one for a new rule.
  describe "typing (contract 8.6): the sender states every type and every conversion" do
    test "T8.10 (a), (b): the signature from @spec, a hint on every variable binding" do
      [f] = functions(typed("""
        @spec f(integer()) :: integer()
        def f(a) do
          x = a + 1
          x * 2
        end
      """))

      assert f.code.nodes == [{:var, 0, "a"}, {:var, 1, "x"}, {:var, 2, "a"}, {:int, 3, 1}, {:op, 4, "+", [2, 3]}, {:match, 5, 1, 4},
                              {:var, 6, "x"}, {:int, 7, 2}, {:op, 8, "*", [6, 7]}, {:block, 9, [5, 8]}, {:clause, 10, [0], -1, 9}]

      # The parameter is declared (@spec); the local x is inferred (the codex worked it out from `a + 1`); the
      # match is a block expression that is not the last (T8.10 e).
      assert hints(f) == %{-1 => {{:t_fun, [int()], int()}, :declared}, 0 => {int(), :declared}, 1 => {int(), :inferred}, 5 => {int(), :inferred}}
    end

    test "T8.10 (b): a pattern is taken apart against the type of what it is matched with" do
      frames = typed("""
        defmodule P do
          @type t :: %__MODULE__{x: integer(), name: String.t()}
          defstruct x: 0, name: ""
        end

        @spec f({:ok, float()} | {:error, atom()}, P.t()) :: float()
        def f(result, %P{x: x} = p) do
          {n, label} = {x, p.name}

          case result do
            {:ok, value} -> value
            {:error, why} -> 0.0
          end
        end
      """)

      f = function(frames, "f", 2)
      types = for {node, {type, strength}} <- hints(f), match?({:var, _, _}, Enum.at(f.code.nodes, max(node, 0))), node >= 0, into: %{}, do: {elem(Enum.at(f.code.nodes, node), 2), {type, strength}}
      text = {:t_basic, :text}

      assert %{"result" => {{:t_union, [{:t_tagged, "ok", [{:t_float, :f64}]}, {:t_tagged, "error", [{:t_basic, :symbol}]}]}, :declared},
               "x" => {{:t_int, :i64}, :declared}, "p" => {{:t_named, "t_p", []}, :declared},
               "n" => {{:t_int, :i64}, :inferred}, "label" => {^text, :inferred},
               "value" => {{:t_float, :f64}, :declared}, "why" => {{:t_basic, :symbol}, :declared}} = types
    end

    test "T8.10 (d): the result of a call to a function of the module, from the callee's @spec" do
      frames = typed("""
        @spec g(integer()) :: integer()
        def g(a), do: a

        @spec f(integer()) :: boolean()
        def f(a), do: g(a) > 0
      """)

      f = function(frames, "f", 1)
      assert [{:var, 0, "a"}, {:var, 1, "a"}, {:call, 2, "", "g", [1]}, {:int, 3, 0}, {:op, 4, ">", [2, 3]}, {:clause, 5, [0], -1, 4}] = f.code.nodes
      assert hints(f)[2] == {int(), :declared}
    end

    test "T8.10 (d), (e): case subject, dropped statement, match value, struct, send, fn" do
      frames = typed("""
        defmodule P do
          @type t :: %__MODULE__{x: integer()}
          defstruct x: 0
        end

        @spec g(integer()) :: :small | :big
        def g(a), do: if(a < 10, do: :small, else: :big)

        @spec f(pid(), integer()) :: P.t()
        def f(to, a) do
          g(a)
          p = %P{x: a}
          send(to, {:point, p.x, 1.5})
          spawn(fn -> g(a) end)

          case g(a) do
            :small -> p
            :big -> %P{p | x: 0}
          end
        end
      """)

      f = function(frames, "f", 2)
      by_kind = for {node, hint} <- hints(f), node >= 0, do: {elem(Enum.at(f.code.nodes, node), 0), hint}
      sizes = {:t_symbols, ["small", "big"]}
      point = {:t_named, "t_p", []}
      message = {:t_tagged, "point", [int(), float()]}

      assert {:call, {sizes, :declared}} in by_kind
      assert Enum.count(by_kind, &(&1 == {:call, {sizes, :declared}})) == 3
      assert {:record, {point, :declared}} in by_kind
      assert {:match, {point, :declared}} in by_kind
      assert {:tuple, {message, :inferred}} in by_kind
      assert {:send, {message, :inferred}} in by_kind
      assert {:lambda, {{:t_fun, [], sizes}, :inferred}} in by_kind
      assert {:spawn, {{:t_actor, {:t_basic, :dynamic}}, :inferred}} in by_kind
      # g/1's `if` on a comparison stays a cond; its branches are atoms of one union.
      assert Enum.any?(function(frames, "g", 1).code.nodes, &(elem(&1, 0) == :cond))
    end

    test "T8.10 (a): a fn written where a function type is declared takes its parameter types from it" do
      frames = typed("""
        @spec twice((integer() -> integer()), integer()) :: integer()
        def twice(f, x), do: f.(f.(x))

        @spec f(integer()) :: integer()
        def f(n), do: twice(fn x -> x + n end, n)
      """)

      f = function(frames, "f", 1)
      assert {{:t_fun, [{:t_int, :i64}], {:t_int, :i64}}, :declared} in Map.values(hints(f))
      assert gap_nodes(f) == []
      # f.(x): the result of an (:apply) is the result of the function type of f
      twice = function(frames, "twice", 2)
      assert [{int(), :declared}, {int(), :declared}] == for({node, hint} <- hints(twice), node >= 0, elem(Enum.at(twice.code.nodes, node), 0) == :apply, do: hint)
    end

    test "T8.12, T8.15: `/` on integers is to_float on both operands, under a guard that fails on a zero divisor" do
      [f] = functions(typed("""
        @spec f(integer(), integer()) :: float()
        def f(a, b), do: a / b
      """))

      assert [{:var, 0, "a"}, {:var, 1, "b"}, {:var, 2, "a"}, {:var, 3, "b"}, {:op, 4, "to_float", [2]}, {:op, 5, "to_float", [3]},
              {:float, 6, "0.0"}, {:op, 7, "==", [5, 6]}, {:symbol, 8, "badarith"}, {:fail, 9, 8}, {:clause, 10, [], 7, 9},
              {:boolean, 11, true}, {:var, 12, "b"}, {:op, 13, "to_float", [12]}, {:op, 14, "/", [4, 13]}, {:clause, 15, [], 11, 14},
              {:cond, 16, [10, 15]}, {:clause, 17, [0, 1], -1, 16}] = f.code.nodes

      assert hints(f)[16] == {float(), :inferred}
    end

    test "T8.15: an operand of `/` that is not a variable or a literal is evaluated once: it is bound first" do
      frames = typed("""
        @spec g(integer()) :: integer()
        def g(a), do: a

        @spec f(integer(), float()) :: float()
        def f(a, x), do: g(a) / (x + 1.0)
      """)

      f = function(frames, "f", 2)
      assert [{:call, _, "", "g", [_]}] = Enum.filter(f.code.nodes, &(elem(&1, 0) == :call))
      assert ["_div_1", "_div_1", "_div_2", "_div_2", "_div_2"] == for({:var, _, "_div" <> _ = name} <- f.code.nodes, do: name)
      assert {:block, block, [m1, m2, guarded]} = Enum.find(f.code.nodes, &(elem(&1, 0) == :block))
      assert {:match, _, _, converted} = Enum.at(f.code.nodes, m1)
      assert {:op, _, "to_float", [_]} = Enum.at(f.code.nodes, converted)
      assert {:match, _, _, _} = Enum.at(f.code.nodes, m2)
      assert {:cond, _, [_, _]} = Enum.at(f.code.nodes, guarded)
      for node <- [m1, m2, guarded, block], do: assert(hints(f)[node] == {float(), :inferred})
    end

    test "T8.15: a literal divisor that is not zero needs no guard; `x / 1` is the integer-to-float conversion" do
      [f] = functions(typed("""
        @spec f(integer()) :: float()
        def f(a), do: a / 1
      """))

      assert [{:var, 0, "a"}, {:var, 1, "a"}, {:float, 2, "1.0"}, {:op, 3, "to_float", [1]}, {:op, 4, "/", [3, 2]}, {:clause, 5, [0], -1, 4}] = f.code.nodes
    end

    test "T8.11: a float next to an integer: to_float on the integer; an integer literal becomes a float literal" do
      frames = typed("""
        @spec scale(float(), integer()) :: float()
        def scale(f, n), do: f * n

        @spec inc(float()) :: float()
        def inc(f), do: 1 + f

        @spec ints(integer(), integer()) :: integer()
        def ints(a, b), do: a * b - 1

        @spec back(integer()) :: float()
        def back(n), do: n * 1.0
      """)

      assert [{"to_float", [{:var, _, "n"}]}, {"*", [{:var, _, "f"}, {:op, _, "to_float", _}]}] = ops(function(frames, "scale", 2))
      assert [{"+", [{:float, _, "1.0"}, {:var, _, "f"}]}] = ops(function(frames, "inc", 1))
      assert [{"*", [{:var, _, "a"}, {:var, _, "b"}]}, {"-", [{:op, _, "*", _}, {:int, _, 1}]}] = ops(function(frames, "ints", 2))
      assert [{"to_float", [{:var, _, "n"}]}, {"*", [{:op, _, "to_float", _}, {:float, _, "1.0"}]}] = ops(function(frames, "back", 1))
    end

    test "T8.11: a comparison of an integer and a float converts the integer; === between them is false" do
      frames = typed("""
        @spec lt(integer(), float()) :: boolean()
        def lt(n, f), do: n < f

        @spec eq(float()) :: boolean()
        def eq(f), do: f == 1

        @spec same(integer(), float()) :: boolean()
        def same(n, f), do: n === f

        @spec other(integer(), float()) :: boolean()
        def other(n, f), do: n !== f

        @spec g(integer()) :: integer()
        def g(n), do: n

        @spec effect(integer(), float()) :: boolean()
        def effect(n, f), do: g(n) === f
      """)

      assert [{"to_float", [{:var, _, "n"}]}, {"<", [{:op, _, "to_float", _}, {:var, _, "f"}]}] = ops(function(frames, "lt", 2))
      assert [{"==", [{:var, _, "f"}, {:float, _, "1.0"}]}] = ops(function(frames, "eq", 1))
      assert [{:var, 0, "n"}, {:var, 1, "f"}, {:boolean, 2, false}, {:clause, 3, [0, 1], -1, 2}] = function(frames, "same", 2).code.nodes
      assert [{:var, 0, "n"}, {:var, 1, "f"}, {:boolean, 2, true}, {:clause, 3, [0, 1], -1, 2}] = function(frames, "other", 2).code.nodes
      # An operand that is a call is still evaluated: (g(n); f; false)
      effect = function(frames, "effect", 2).code.nodes
      assert {:block, _, [call, _f, constant]} = Enum.find(effect, &(elem(&1, 0) == :block))
      assert {:call, _, "", "g", [_]} = Enum.at(effect, call)
      assert {:boolean, _, false} = Enum.at(effect, constant)
    end

    test "T8.12: trunc/1 and round/1 are the conversion operators on a float; an integer is sent as it is" do
      frames = typed("""
        @spec t(float()) :: integer()
        def t(f), do: trunc(f)

        @spec r(float()) :: integer()
        def r(f), do: round(f * 2)

        @spec i(integer()) :: integer()
        def i(n), do: trunc(n) + round(n)

        @spec fl(integer()) :: float()
        def fl(n), do: :erlang.float(n)

        @spec down(float()) :: integer()
        def down(f), do: floor(f)
      """)

      assert [{"trunc", [{:var, _, "f"}]}] = ops(function(frames, "t", 1))
      assert [{"*", [{:var, _, "f"}, {:float, _, "2.0"}]}, {"round", [{:op, _, "*", _}]}] = ops(function(frames, "r", 1))
      assert [{"+", [{:var, _, "n"}, {:var, _, "n"}]}] = ops(function(frames, "i", 1))
      assert [{"to_float", [{:var, _, "n"}]}] = ops(function(frames, "fl", 1))
      # floor/1 has no conversion operator in T8.12: a gap until the table grows.
      assert [{"type rule: conversion floor", note}] = gap_nodes(function(frames, "down", 1))
      assert note =~ "T8.12"
    end

    test "T8.15: div and rem are sent as they are (Silica's integer division fails on zero, as Elixir's does)" do
      [f] = functions(typed("""
        @spec f(integer(), integer()) :: {integer(), integer()}
        def f(a, b), do: {div(a, b), rem(a, b)}
      """))

      assert [{"div", [{:var, _, "a"}, {:var, _, "b"}]}, {"rem", [{:var, _, "a"}, {:var, _, "b"}]}] = ops(f)
      refute Enum.any?(f.code.nodes, &(elem(&1, 0) in [:cond, :fail]))
    end

    test "a type that is missing is a gap whose note says which and why, never an untyped node" do
      frames = typed("""
        def helper(x), do: x

        @spec f(integer()) :: integer()
        def f(a), do: helper(a) + 1

        @spec g(String.t()) :: integer()
        def g(s), do: String.to_integer(s) * 2

        @spec h(integer()) :: integer()
        def h(a) do
          x = helper(a)
          a
        end

        @spec n(number()) :: integer()
        def n(a), do: 1

        @spec r() :: integer()
        def r do
          receive do
            {:add, n} -> n
          end
        end

        @spec typed_receive() :: integer()
        def typed_receive do
          receive do
            {:add, n} when is_integer(n) -> n + 1
          end
        end
      """)

      # {unit, form, line, construct, note}: the line is the source's (the module's `defmodule` is line 1)
      assert [{"T", "helper", 2, "missing type: function signature", helper}, {"T", "f/1", 5, "missing type: operand of +", f},
              {"T", "g/1", 8, "missing type: operand of *", g}, {"T", "h/1", 12, "missing type: value of a match (=)", h},
              {"T", "n", 17, "missing type: function signature", n}, {"T", "r/0", 21, "missing type: message of a receive clause", r}] = Codex.gaps(frames)

      assert helper == "helper/1 has no @spec, so its parameter and result types cannot be stated (T8.10 a)"
      assert f == "the local call helper/1: helper/1 has no @spec, so its result type cannot be stated (T8.10 d) (T8.10 c)"
      assert g =~ "String.to_integer/1: it is in another module, whose @spec the codex does not see"
      assert h =~ "helper/1 has no @spec"
      assert n =~ "parameter 1: number() is integer() or float()"
      assert r =~ "the variable n has no stated type: Elixir declares no type for a received message"

      # Nothing untyped is left where a type is required: f's body is the gap, with no (:op) and no (:call).
      assert [{:var, 0, "a"}, {:gap_node, 1, _, _}, {:clause, 2, [0], -1, 1}] = function(frames, "f", 1).code.nodes
      assert gap_nodes(function(frames, "typed_receive", 0)) == []
    end

    test "Elixir types with no one type to compare: a gap that says so (T8.11)" do
      frames = typed("""
        @spec f(String.t(), integer()) :: boolean()
        def f(s, n), do: s < n

        @spec g(String.t(), integer()) :: boolean()
        def g(s, n), do: s == n

        @spec h(float(), integer()) :: integer()
        def h(f, n), do: div(f, n)
      """)

      assert [{"type rule: operands of <", note}] = gap_nodes(function(frames, "f", 2))
      assert note =~ "String.t() < integer()" and note =~ "T8.11"
      # == between types that share no value is false whatever the values
      assert [{:var, 0, "s"}, {:var, 1, "n"}, {:boolean, 2, false}, _] = function(frames, "g", 2).code.nodes
      assert [{"type rule: operands of div", _}] = gap_nodes(function(frames, "h", 2))
    end

    test "truthiness uses types: a condition whose stated type is boolean stays a cond" do
      frames = typed("""
        @spec valid?(integer()) :: boolean()
        def valid?(n), do: n > 0

        @spec f(integer(), boolean()) :: integer()
        def f(n, flag) do
          if valid?(n) && flag, do: 1, else: 2
        end
      """)

      kinds = Enum.map(function(frames, "f", 2).code.nodes, &elem(&1, 0))
      assert :cond in kinds and :case not in kinds
      assert [{"andalso", [{:call, _, "", "valid__q", _}, {:var, _, "flag"}]}] = ops(function(frames, "f", 2))
    end

    test "T8.14: the type forms of a module are sent first, a type before the type that names it" do
      frames = typed("""
        @spec f(Line.t()) :: integer()
        def f(line), do: line.from.x

        defmodule Line do
          @type t :: %__MODULE__{from: T.Point.t(), to: T.Point.t()}
          defstruct [:from, :to]
        end

        defmodule Point do
          @type t :: %__MODULE__{x: integer()}
          defstruct x: 0
        end
      """)

      assert [{:type, %{head: %{name: "t_point"}}}, {:type, %{head: %{name: "t_line"}, types: types}}, {:function, %{head: %{name: "f"}}}] =
               for({:form, %{body: body}} <- frames, do: body)

      assert types == [{:t_named, "t_point", []}, {:t_record, [{"from", 0}, {"to", 0}]}]
      assert gap_nodes(function(frames, "f", 1)) == []
    end

    test "a struct with a field that has no type cannot be declared: a gap, and so is every use of it" do
      frames = typed("""
        defmodule Open do
          defstruct [:x]
        end

        @spec f() :: integer()
        def f do
          o = %Open{x: 1}
          1
        end
      """)

      assert [{"T", "T.Open", 3, "missing type: struct field", field}, {"T", "f/0", 8, "missing type: struct", _}] = Codex.gaps(frames)
      assert field =~ "the struct T.Open states no type for its field x"
      refute Enum.any?(frames, &match?({:form, %{body: {:type, _}}}, &1))
    end

    test "both examples: every node T8.10 requires a type for has one (a hint, or a type the node fixes)" do
      for file <- [@demo, @actors], {:form, %{body: {:function, f}}} <- Codex.frames([file], :check) do
        nodes = f.code.nodes
        stated = hints(f)
        # (an (:sl_call) of a print builtin has the builtin's own type: contract T9.16)
        fixed = [:int, :float, :text, :boolean, :symbol, :var, :op, :fail, :gap_node, :sl_call]
        has_type = fn i -> is_map_key(stated, i) or elem(Enum.at(nodes, i), 0) in fixed end
        where = fn i -> "#{f.head.name}/#{f.head.arity} node #{i}: #{inspect(Enum.at(nodes, i))}" end
        assert is_map_key(stated, -1), f.head.name

        for node <- nodes do
          case node do
            {:block, _, exprs} -> for i <- Enum.drop(exprs, -1), do: assert(has_type.(i), "dropped statement, " <> where.(i))
            {:case, _, subject, _} -> assert has_type.(subject), "case subject, " <> where.(subject)
            {:match, _, _, value} -> if elem(Enum.at(nodes, value), 0) not in [:var, :record, :tuple, :wild, :match], do: assert(has_type.(value), "match value, " <> where.(value))
            {:op, _, _, args} -> for i <- args, do: assert(has_type.(i), "operand, " <> where.(i))
            {:send, _, _, message} -> assert has_type.(message), "message, " <> where.(message)
            {:lambda, at, _} -> assert is_map_key(stated, at), "fn, " <> where.(at)
            {:record, at, _, _, base} when base >= 0 -> assert is_map_key(stated, at), "struct update, " <> where.(at)
            _ -> :ok
          end
        end

        # T8.11: the two operands of an arithmetic operator are both integers or both floats.
        # (a variable's type is the hint on its binding: the (:var) of that name that has one)
        binding = fn name -> Enum.find_value(nodes, fn node -> match?({:var, _, ^name}, node) && stated[elem(node, 1)] end) end

        kind = fn i ->
          case {Enum.at(nodes, i), stated[i]} do
            {{:var, _, name}, nil} ->
              case binding.(name) do
                {{:t_int, _}, _} -> :int
                {{:t_float, _}, _} -> :float
                _ -> :other
              end

            {{:int, _, _}, _} -> :int
            {{:float, _, _}, _} -> :float
            {{:op, _, "to_float", _}, _} -> :float
            {{:op, _, op, _}, _} when op in ["trunc", "round", "div", "rem"] -> :int
            {_, {{:t_int, _}, _}} -> :int
            {_, {{:t_float, _}, _}} -> :float
            _ -> :other
          end
        end

        for {:op, at, op, [l, r]} <- nodes, op in ["/"], do: assert({kind.(l), kind.(r)} == {:float, :float}, where.(at))
        for {:op, at, op, [l, r]} <- nodes, op in ["div", "rem"], do: assert(:float not in [kind.(l), kind.(r)], where.(at))
        for {:op, at, op, [l, r]} <- nodes, op in ["+", "-", "*", "<", ">", "=<", ">=", "=="], do: assert(Enum.sort([kind.(l), kind.(r)]) != [:float, :int], where.(at))
      end
    end
  end

  describe "the split (E2s.Split, contract T9.13a), trapped exits and Elixir's output (T9.16)" do
    test "code after a receive is a continuation: its parameters are the live variables and the receive's value" do
      frames = typed("""
        @spec f(pid(), integer(), integer()) :: integer()
        def f(to, unused, bonus) do
          send(to, :ready)
          n = receive do
            {:n, n} when is_integer(n) -> n
          end
          n + bonus + unused - unused
        end

        @spec g(pid(), integer(), integer()) :: integer()
        def g(to, unused, bonus) do
          send(to, :ready)
          n = receive do
            {:n, n} when is_integer(n) -> n
          end
          n + bonus
        end
      """)

      assert Codex.gaps(frames) == []
      g = function(frames, "g", 3)
      k = function(frames, "g__k1", 2)
      assert g.head.exported and not k.head.exported
      # the code before the receive stays; the receive is the last expression; its clause ends in the tail call
      assert {:clause, _, _, _, body} = Enum.at(g.code.nodes, hd(g.code.clauses))
      assert {:block, _, [_send, receive]} = Enum.at(g.code.nodes, body)
      assert {:receive, _, [clause], -1, -1} = Enum.at(g.code.nodes, receive)
      assert {:clause, _, _, _, call} = Enum.at(g.code.nodes, clause)
      assert {:call, _, "", "g__k1", [bonus, n]} = Enum.at(g.code.nodes, call)
      # only what the code after the receive uses is passed on: bonus and the value, not `to` or `unused`
      assert {:var, _, "bonus"} = Enum.at(g.code.nodes, bonus)
      assert {:var, _, "n"} = Enum.at(g.code.nodes, n)
      # the continuation has no @spec: its parameters are typed from that call, its result is g's @spec result
      assert hints(k)[-1] == {{:t_fun, [int(), int()], int()}, :inferred}
      assert hints(function(frames, "f__k1", 3))[-1] == {{:t_fun, [int(), int(), int()], int()}, :inferred}
    end

    test "a call of a function that receives, with code after it: a copy of the callee that ends in the continuation" do
      frames = typed("""
        @spec ask(pid(), integer()) :: {:ok, integer()} | {:no, integer()}
        def ask(to, q) do
          send(to, {:q, q, self()})
          receive do
            {:yes, n} when is_integer(n) -> {:ok, n}
            {:no, n} when is_integer(n) -> {:no, n}
          end
        end

        @spec client(pid(), integer()) :: integer()
        def client(to, bonus) do
          r = ask(to, 1)
          case r do
            {:ok, n} -> n + bonus
            {:no, n} -> n
          end
        end
      """)

      assert Codex.gaps(frames) == []
      names = for {:form, %{body: {:function, %{head: head}}}} <- frames, do: {head.name, head.arity}
      assert names == [{"ask", 2}, {"client", 2}, {"client__k1", 2}, {"ask__c1", 3}, {"ask__c1__k1", 1}]
      # client ends in the copy, which carries what the continuation needs (bonus) as one more parameter
      client = function(frames, "client", 2)
      assert [{:call, _, "", "ask__c1", [_to, _q, _bonus]}] = for({:call, _, _, _, _} = c <- client.code.nodes, do: c)
      # the copy sends, then waits in a function of its own that keeps only what its receive uses
      copy = function(frames, "ask__c1", 3)
      assert [{:call, _, "", "ask__c1__k1", [_]}] = for({:call, _, _, _, _} = c <- copy.code.nodes, do: c)
      wait = function(frames, "ask__c1__k1", 1)
      assert [{:receive, _, [_, _], -1, -1}] = for({:receive, _, _, _, _} = r <- wait.code.nodes, do: r)
      assert ["client__k1", "client__k1"] == for({:call, _, "", name, [_, _]} <- wait.code.nodes, do: name)
      # the continuation's value parameter has the union of the types the two calls give it (inferred)
      union = {:t_union, [{:t_tagged, "ok", [int()]}, {:t_tagged, "no", [int()]}]}
      assert hints(function(frames, "client__k1", 2))[-1] == {{:t_fun, [int(), union], int()}, :inferred}
      assert hints(copy)[-1] == {{:t_fun, [{:t_actor, {:t_basic, :dynamic}}, int(), int()], int()}, :inferred}
    end

    test "a receiving call as an argument is bound first when only variables and literals are evaluated before it" do
      frames = typed("""
        @spec get() :: integer()
        def get do
          receive do
            {:n, n} when is_integer(n) -> n
          end
        end

        @spec add(integer(), integer()) :: integer()
        def add(a, b), do: a + b

        @spec ok(integer()) :: integer()
        def ok(a), do: add(a, get())

        @spec piped(integer()) :: integer()
        def piped(a), do: a |> add(get()) |> add(1)

        @spec subject() :: integer()
        def subject do
          case get() do
            1 -> 10
            _ -> 20
          end
        end

        @spec no(integer()) :: integer()
        def no(a), do: add(add(a, 1), get())
      """)

      assert [{"T", "no/1", _, "call of a function that receives, inside an expression", note}] = Codex.gaps(frames)
      assert note =~ "bind its value to a variable with = first"
      # ok/1: get's copy, then add(a, value) in the continuation
      assert [{:call, _, "", "add", [_, _]}] = for({:call, _, _, _, _} = c <- function(frames, "ok__k1", 2).code.nodes, do: c)
      assert function(frames, "piped__k1", 2) && function(frames, "subject__k1", 1)
    end

    test "Process.flag(:trap_exit, true), spawn_link and receive {:EXIT, ...}: the linked copy of the child's function" do
      frames = typed("""
        @spec loop(integer()) :: :ok
        def loop(n) do
          receive do
            {:add, m} when is_integer(m) -> loop(n + m)
            :stop -> :ok
            :crash -> exit(:crashed)
          end
        end

        @spec sup(pid()) :: :done
        def sup(parent) do
          Process.flag(:trap_exit, true)
          child = spawn_link(fn -> loop(0) end)
          send(parent, {:child, child})

          receive do
            {:EXIT, ^child, :normal} -> :done
            {:EXIT, _pid, _reason} -> sup(parent)
          end
        end
      """)

      assert Codex.gaps(frames) == []
      sup = function(frames, "sup", 1)
      linked = function(frames, "loop__l", 2)
      pid = {:t_actor, {:t_basic, :dynamic}}
      assert hints(linked)[-1] == {{:t_fun, [int(), pid], {:t_symbols, ["ok"]}}, :inferred}
      # the parent is bound first, then an unlinked spawn of the linked copy with the parent as one more argument
      assert [{:spawn, _, lambda, [], false}] = for({:spawn, _, _, _, _} = s <- sup.code.nodes, do: s)
      assert {:lambda, _, [_]} = Enum.at(sup.code.nodes, lambda)
      assert [{:call, _, "", "loop__l", [_, parent]}] = for({:call, _, "", "loop__l", _} = c <- sup.code.nodes, do: c)
      assert {:var, _, "e2s_s1"} = Enum.at(sup.code.nodes, parent)
      assert Enum.any?(sup.code.nodes, &match?({:self, _}, &1))
      # the copy tells its parent before it ends: {:EXIT, self(), :normal} for a value, the atom of an exit/1
      reasons =
        for {:send, _, _, message} <- linked.code.nodes, {:tuple, _, [tag, _self, reason]} <- [Enum.at(linked.code.nodes, message)],
            {:symbol, _, "EXIT"} <- [Enum.at(linked.code.nodes, tag)], {:symbol, _, name} <- [Enum.at(linked.code.nodes, reason)], do: name

      assert reasons == ["normal", "crashed"]
      # the copy loops in itself
      assert [{:call, _, "", "loop__l", [_, _]}] = for({:call, _, "", "loop__l", _} = c <- linked.code.nodes, do: c)
      # what the receive takes is typed as the message the copy sends: `_pid` and `_reason` are variables with a type
      exits = for {_, {{:t_tagged, "EXIT", elems}, :inferred}} <- hints(sup), do: elems
      assert Enum.sort(exits) == Enum.sort([[pid, {:t_symbols, ["normal"]}], [pid, {:t_basic, :symbol}]])
      assert Enum.any?(sup.code.nodes, &match?({:var, _, "e2s_x1"}, &1))
    end

    test "a literal field in a struct pattern is a variable and === in the clause's guard" do
      frames = typed("""
        defmodule P do
          @type t :: %__MODULE__{x: integer(), y: integer()}
          defstruct x: 0, y: 0
        end

        @spec f(P.t()) :: integer()
        def f(%P{x: 0}), do: 0
        def f(%P{x: x, y: 1}) when x > 5, do: x
        def f(%P{x: x}), do: x + 1

        @spec g(P.t()) :: integer()
        def g(p) do
          case p do
            %P{y: -1} -> 0
            %P{y: y} -> y
          end
        end
      """)

      assert Codex.gaps(frames) == []
      f = function(frames, "f", 1)
      node = &Enum.at(f.code.nodes, &1)
      assert [c1, c2, _c3] = f.code.clauses
      assert {:clause, _, [record], guard, _} = node.(c1)
      assert {:record, _, "t_p", [{"x", field}], -1} = node.(record)
      assert {:var, _, "e2s_p1"} = node.(field)
      assert {:op, _, "=:=", [l, r]} = node.(guard)
      assert {{:var, _, "e2s_p1"}, {:int, _, 0}} = {node.(l), node.(r)}
      # the literal's test comes before the clause's own guard
      assert {:clause, _, _, guard2, _} = node.(c2)
      assert {:op, _, "andalso", [test, own]} = node.(guard2)
      assert {{:op, _, "=:=", _}, {:op, _, ">", _}} = {node.(test), node.(own)}
      assert Enum.any?(function(frames, "g", 1).code.nodes, &match?({:op, _, "=:=", _}, &1))
    end

    test "IO.puts and IO.inspect are L1 calls of Silica's print builtins, chosen by the argument's stated type (T9.16)" do
      frames = typed("""
        @spec f(String.t(), integer(), float(), atom(), boolean()) :: :ok
        def f(s, n, x, a, b) do
          IO.puts(s)
          IO.puts(n)
          IO.inspect(x)
          IO.inspect(a)
          IO.inspect({:pair, n, s, b})
          IO.puts("done")
        end
      """)

      f = function(frames, "f", 5)
      assert gap_nodes(f) == []
      refute Enum.any?(f.code.nodes, &match?({:call, _, "IO", _, _}, &1))

      prints =
        for {:sl_call, _, "", name, [arg]} <- f.code.nodes do
          case Enum.at(f.code.nodes, arg) do
            {:text, _, text} -> {name, text}
            {:var, _, var} -> {name, var}
            {:sl_call, _, "", inner, _} -> {name, {inner}}
          end
        end

      assert prints == [
               {"println", "s"},
               {"print_int64", "n"}, {"println", ""},
               {"print_float64", "x"}, {"println", ""},
               {"print", ":"}, {"atom_name", "a"}, {"print", {"atom_name"}}, {"println", ""},
               {"print", "{:pair, "}, {"print_int64", "e2s_i1"}, {"print", ", \""}, {"print", "e2s_i2"}, {"print", "\", "},
               {"print_boolean", "e2s_i3"}, {"print", "}"}, {"println", ""},
               {"println", "done"}
             ]

      # an (:sl_call) has the builtin's own type: no hint is written for it
      for {:sl_call, at, _, _, _} <- f.code.nodes, do: refute(is_map_key(hints(f), at))
    end

    test "IO.inspect of a union of tagged tuples is a case over its alternatives; its value is its argument" do
      frames = typed("""
        @spec f({:ok, integer()} | {:refused, integer()} | :none) :: :ok
        def f(r) do
          IO.inspect(r)
          :ok
        end

        @spec g(integer()) :: integer()
        def g(n), do: IO.inspect(n + 1) * 2
      """)

      f = function(frames, "f", 1)
      assert gap_nodes(f) == []
      assert [{:case, _, _, [_, _, _]}] = for({:case, _, _, _} = c <- f.code.nodes, do: c)
      texts = for {:sl_call, _, "", "print", [arg]} <- f.code.nodes, {:text, _, text} <- [Enum.at(f.code.nodes, arg)], do: text
      assert texts == ["{:ok, ", "}", "{:refused, ", "}", ":none"]
      # as a statement its value is dropped: the lowering ends with :ok, not with the value
      assert Enum.any?(f.code.nodes, fn
               {:block, _, [first, _newline, last]} -> match?({{:case, _, _, _}, {:symbol, _, "ok"}}, {Enum.at(f.code.nodes, first), Enum.at(f.code.nodes, last)})
               _ -> false
             end)
      # used for its value: the argument is bound once, printed, and is the value
      g = function(frames, "g", 1)
      assert gap_nodes(g) == []
      assert [{"+", _}, {"*", [{:block, _, [bind, _print, _newline, value]}, {:int, _, 2}]}] = ops(g)
      assert {:match, _, _, _} = Enum.at(g.code.nodes, bind)
      assert {:var, _, "_io_1"} = Enum.at(g.code.nodes, value)
    end

    test "IO output the sender cannot lower is a gap that says which type" do
      frames = typed("""
        defmodule P do
          @type t :: %__MODULE__{x: integer()}
          defstruct x: 0
        end

        @spec f(P.t(), pid()) :: :ok
        def f(p, q) do
          IO.inspect(p)
          IO.puts(q)
        end
      """)

      assert [{"IO.inspect/1", inspect_note}, {"IO.puts/1", puts_note}] = gap_nodes(function(frames, "f", 2))
      assert inspect_note =~ "IO.inspect of a value of the type the struct t_p is not lowered"
      assert puts_note =~ "IO.puts of a value of the type pid() is not lowered"
    end

    test "the fixture of every shape the split cuts: no gap, every frame passes check_frame" do
      frames = Codex.frames([@shapes], :check)
      for frame <- frames, do: assert(:check_frame.check(frame) == :ok, "#{inspect(frame, limit: 6)}")
      assert Codex.gaps(frames) == []
      names = for {:form, %{body: {:function, %{head: head}}}} <- frames, do: head.name
      # several receives; a receive in a case, an if, a cond and a receive clause; rebinding; a loop's copy
      for name <- ~w(two__k1 two__k2 in_case__k1 in_case__k2 in_if__k1 in_if__k2 nested__k1 in_cond__k1 rebind__k1 rebind__k2
                     subject__k1 loop__c1 loop__l after_loop__k1 timed__k1 main__k1),
          do: assert(name in names, "no function #{name}")

      # the receives stand in tail position: every (:receive) is the last node of its clause's body
      for {:form, %{body: {:function, %{head: head, code: %{nodes: nodes}}}}} <- frames, {:block, _, statements} <- nodes,
          i <- Enum.drop(statements, -1) do
        refute match?({:receive, _, _, _, _}, Enum.at(nodes, i)), "#{head.name}: a receive that is not the last of its block"
      end
    end

    @shapes_output ["{:a, 1, 2}", "9", "6", "50", "40", "5", "7", "16", "111", ":one", "{:total, 111}", "{:got, -1}", "107",
                    "3000", "0", "closed"]
    @actors_output ["{:refused, 30}", "{:ok, 40}", "ada: low", "{:balance, 40, :mean_move, 13.333333333333334}", "account closed"]

    # What E2s.Split makes is Elixir: compiled in place of the module it behaves as the module does. A change to
    # the splitter that changes a program's behaviour fails here, before any transpiler is involved.
    test "the split forms of the fixture and of examples/actors.ex run as Elixir and print what the modules print" do
      import ExUnit.CaptureIO

      for {file, module, expected} <- [{@shapes, Shapes, @shapes_output}, {@actors, Actors, @actors_output}] do
        {output, 0} = System.cmd("elixir", ["-r", file, "-e", "#{inspect(module)}.main()"], stderr_to_stdout: false)
        assert String.split(output, "\n", trim: true) == expected

        capture_io(:stderr, fn -> for quoted <- Codex.split(file), do: Code.compile_quoted(quoted) end)
        assert String.split(capture_io(fn -> assert apply(module, :main, []) == :ok end), "\n", trim: true) == expected
        # every receive of the split module is in tail position: none is bound, passed or followed by code
        refute Enum.join(Enum.map(Codex.split(file), &Macro.to_string/1)) =~ ~r/= *\n? *receive do/
      end
    end
  end

  describe "a static supervisor (E2s.Sup, contract T9.14b, T9.14c) and a fn that captures nothing (E2s.Lift)" do
    @sup """
      use Supervisor
      @spec start() :: :ok
      def start do
        {:ok, _pid} = Supervisor.start_link(__MODULE__, 5)
        :ok
      end
      @impl true
      def init(first) do
        Supervisor.init(CHILDREN, OPTIONS)
      end
      @spec start_a(integer()) :: {:ok, pid()}
      def start_a(n) do
        pid = spawn_link(__MODULE__, :loop, [n, :a])
        true = Process.register(pid, :worker_a)
        {:ok, pid}
      end
      @spec start_b(float()) :: {:ok, pid()}
      def start_b(f), do: {:ok, spawn_link(fn -> ticks(f, -2) end)}
      def child_spec(n), do: %{id: :spec_child, start: {T, :start_a, [n]}, restart: :temporary}
      @spec loop(integer(), atom()) :: :ok
      def loop(n, tag) do
        receive do
          {:more, m} when is_integer(m) -> loop(n + m, tag)
          :stop -> :ok
        end
      end
      @spec ticks(float(), integer()) :: :ok
      def ticks(f, n) do
        receive do
          :tick -> ticks(f, n + 1)
          :stop -> :ok
        end
      end
    """

    defp sup(children, options \\ "strategy: :one_for_one") do
      typed(@sup |> String.replace("CHILDREN", children) |> String.replace("OPTIONS", options))
    end

    defp static_children(frames) do
      f = function(frames, "start", 0)
      nodes = f.code.nodes

      for {:register, _, name, spawn} <- nodes do
        {:spawn, _, ref, args, false} = Enum.at(nodes, spawn)
        {:fun_ref, _, "T", run, arity} = Enum.at(nodes, ref)
        [%{requirement: :a4_4, choice: :chosen, detail: %{params: params}}] = Enum.filter(f.notes.overrides, &(&1.node == spawn))
        {name, run, arity, Enum.map(args, &Enum.at(nodes, &1) |> Tuple.delete_at(1)), Map.new(params)}
      end
    end

    test "examples/demo.ex: the supervisor's child is a (:register) of a (:spawn) with literal arguments and an a4_4 override", %{frames: frames} do
      f = function(frames, "start_sup", 0)

      assert [{:fun_ref, 0, "Demo", "counter", 1}, {:int, 1, 0}, {:spawn, 2, 0, [1], false}, {:register, 3, "tally", 2},
              {:symbol, 4, "ok"}, {:block, 5, [3, 4]}, {:clause, 6, [], -1, 5}] = f.code.nodes

      assert [%{node: 2, requirement: :a4_4, choice: :chosen, detail: %{params: [{"restart", "transient"}, {"strategy", "one_for_one"}], note: note}}] =
               f.notes.overrides

      assert is_binary(note)
      # what the supervisor's callbacks say is in the static child: they are not sent, and `use Supervisor` is no gap
      assert function(frames, "init", 1) == nil
      assert function(frames, "start_tally", 1) == nil
      refute Enum.any?(frames, &match?({:form, %{body: {:gap, _}}}, &1))
      # H39: the child is talked to by its name; the value of the send is the message
      assert [{:var, 0, "n"}, {:symbol, 1, "add"}, {:var, 2, "n"}, {:tuple, 3, [1, 2]}, {:send_named, 4, "tally", 3} | _] =
               function(frames, "tally_add", 1).code.nodes

      assert Enum.any?(function(frames, "tally_total", 0).code.nodes, &match?({:send_named, _, "tally", _}, &1))
      assert [{:symbol, 0, "stop"}, {:send_named, 1, "tally", 0} | _] = function(frames, "tally_stop", 0).code.nodes
    end

    test "examples/demo.ex runs as Elixir: the supervisor starts, its child answers by its name and stops" do
      {output, 0} =
        System.cmd("elixir", ["-r", @demo, "-e", """
        IO.inspect(Demo.start_sup())
        IO.inspect(Demo.tally_add(3))
        IO.inspect(Demo.tally_add(4))
        IO.inspect(Demo.tally_total())
        IO.inspect(Supervisor.count_children(Demo.Sup).active)
        IO.inspect(Demo.tally_stop())
        Process.sleep(100)
        IO.inspect({Process.whereis(:tally), Supervisor.count_children(Demo.Sup).active})
        IO.inspect(Demo.add_ten(1))
        """], stderr_to_stdout: false)

      assert String.split(output, "\n", trim: true) == [":ok", ":ok", ":ok", "7", "1", ":ok", "{nil, 0}", "11"]
    end

    test "child specifications: a map, OTP's defaults, {Module, argument} with child_spec/1, the id as the name" do
      # restart is :permanent when it is not written; the name is the registered one
      assert [{"worker_a", "loop", 2, [{:int, 7}, {:symbol, "a"}], %{"restart" => "permanent", "strategy" => "one_for_one"}}] =
               static_children(sup("[%{id: :one, start: {T, :start_a, [7]}}]"))

      # two children in the list's order; the parameter of init/1 is the argument of the start; a child that is
      # not registered is named by its id; a strategy and a restart as written
      assert [{"worker_a", "loop", 2, [{:int, 5}, {:symbol, "a"}], %{"restart" => "transient", "strategy" => "rest_for_one"}},
              {"b", "ticks", 2, [{:float, "1.5"}, {:int, -2}], %{"restart" => "temporary", "strategy" => "rest_for_one"}}] =
               static_children(sup("[%{id: :a, start: {__MODULE__, :start_a, [first]}, restart: :transient, type: :worker}, %{id: :b, start: {T, :start_b, [1.5]}, restart: :temporary}]",
                 "strategy: :rest_for_one, max_restarts: 1"))

      # {Module, argument} and the bare module: child_spec/1 is read
      assert [{"worker_a", "loop", 2, [{:int, 9}, {:symbol, "a"}], %{"restart" => "temporary"}}] = static_children(sup("[{T, 9}]"))
      frames = sup("[{__MODULE__, first}]")
      assert [{"worker_a", "loop", 2, [{:int, 5}, _], _}] = static_children(frames)
      # the functions that only describe the child are not sent; the ones the children run are
      for {name, arity} <- [{"init", 1}, {"start_a", 1}, {"child_spec", 1}], do: assert(function(frames, name, arity) == nil)
      assert function(frames, "loop", 2) != nil
      assert gaps(frames) == 0
    end

    test "a supervisor that cannot be read is a gap that says why; nothing of it is taken out" do
      for {children, options, why} <- [
            {"[%{id: :a, start: {T, :start_a, [1]}}]", "max_restarts: 3", "no strategy"},
            {"[%{id: :a, start: {T, :start_a, [1]}}]", "strategy: :simple_one_for_one", "a strategy the contract has no value for"},
            {"[%{id: :a, start: {T, :start_a, [1]}, restart: :sometimes}]", "strategy: :one_for_one", "a restart the contract has no value for"},
            {"[%{id: :a, start: {Other, :start_a, [1]}}]", "strategy: :one_for_one", "in another module"},
            {"[{Other, 1}]", "strategy: :one_for_one", "a child is another module"},
            {"[%{id: :a, start: {T, :start_a, [1]}, type: :supervisor}]", "strategy: :one_for_one", "a child that is a supervisor"},
            {"[%{id: :a, start: {T, :start_a, [\"text\"]}}]", "strategy: :one_for_one", "not an integer, a float or an atom"},
            {"[%{id: :a, start: {T, :loop, [1, :a]}}]", "strategy: :one_for_one", "is not spawn_link"},
            {"children(first)", "strategy: :one_for_one", "not literal data"},
            {"[%{id: 1, start: {T, :start_b, [1.5]}}]", "strategy: :one_for_one", "a child has no name"}
          ] do
        frames = sup(children, options)
        assert [{"T", "start/0", _, "Supervisor.start_link", note}] = for({_, "start/0", _, _, _} = gap <- Codex.gaps(frames), do: gap)
        assert note =~ why and note =~ "T9.14b", "#{children}: #{note}"
        assert function(frames, "init", 1) != nil or Enum.any?(Codex.gaps(frames), &match?({_, "init", _, _, _}, &1))
        assert Enum.any?(Codex.gaps(frames), &match?({_, "use", _, "use", _}, &1))
      end

      # an argument of another type than the child's function declares: the codex's gap
      frames = sup("[%{id: :a, start: {T, :start_b, [1]}}]")
      assert [{_, "start/0", _, "a supervisor's static child", note}] = for({_, "start/0", _, _, _} = gap <- Codex.gaps(frames), do: gap)
      assert note =~ "another type"
    end

    test "a supervisor's start whose value is used, and a name given anywhere else, stay gaps" do
      frames = typed("  use Supervisor\n  @spec start() :: pid()\n  def start do\n    {:ok, pid} = Supervisor.start_link(__MODULE__, [])\n    pid\n  end\n  def init(_), do: Supervisor.init([], strategy: :one_for_one)\n")
      assert [{_, "start/0", _, "Supervisor.start_link/2", "OTP behaviours" <> _}] = for({_, "start/0", _, _, _} = gap <- Codex.gaps(frames), do: gap)
      assert [{:gap_node, 0, "Process.register/2", note}, _] = body("Process.register(self(), :name)")
      assert note =~ "T9.14b"
      # H39 in a mapping test: the message, then the send to the name
      assert [{:symbol, 0, "hi"}, {:send_named, 1, "name", 0}, {:clause, 2, [], -1, 1}] = body("send(:name, :hi)")
    end

    test "a fn that captures nothing, written where an @spec declares a function type, is a function of the module" do
      frames =
        typed("""
          @spec twice((integer() -> integer()), integer()) :: integer()
          def twice(f, x), do: f.(f.(x))
          @spec add_ten(integer()) :: integer()
          def add_ten(n), do: twice(fn x -> x + 5 end, n)
          @spec signs(integer()) :: integer()
          def signs(n) do
            twice(fn
              0 -> 0
              x when x < 0 -> -1
              _ -> 1
            end, n)
          end
          @spec add_n(integer(), integer()) :: integer()
          def add_n(n, start), do: twice(fn x -> x + n end, start)
          @spec shadow(integer()) :: integer()
          def shadow(x), do: twice(fn x -> x + 1 end, x)
          @spec piped(integer()) :: integer()
          def piped(n), do: (fn x -> x + 1 end) |> twice(n)
        """)

      assert gaps(frames) == 0
      assert [{:var, 0, "n"}, {:fun_ref, 1, "", "add_ten__f1", 1}, {:var, 2, "n"}, {:call, 3, "", "twice", [1, 2]}, _] = function(frames, "add_ten", 1).code.nodes
      made = function(frames, "add_ten__f1", 1)
      assert %{head: %{exported: false, arity: 1}} = made
      assert [{:var, 0, "x"}, {:var, 1, "x"}, {:int, 2, 5}, {:op, 3, "+", [1, 2]}, {:clause, 4, [0], -1, 3}] = made.code.nodes
      assert hints(made)[-1] == {{:t_fun, [int()], int()}, :declared}
      # every clause of the fn is a clause of the function, with its guard
      assert %{code: %{clauses: [_, _, _]}} = function(frames, "signs__f1", 1)
      # a parameter that has the name of an outer variable is the fn's own
      assert function(frames, "shadow__f1", 1) != nil
      # a closure, and a fn that is not written as the argument, stay a (:lambda) with its type
      assert function(frames, "add_n__f1", 1) == nil
      assert Enum.any?(function(frames, "add_n", 2).code.nodes, &match?({:lambda, _, _}, &1))
      assert function(frames, "piped__f1", 1) == nil
      # the fn of a spawn is the contract's own shape (T9.14) and stays
      assert [{:call, 0, "", "f", []}, {:clause, 1, [], -1, 0}, {:lambda, 2, [1]}, {:spawn, 3, 2, [], false}, _] = body("spawn(fn -> f() end)")
    end
  end

  describe "names (E2s.Names)" do
    test "N1: the Silica unit is the prefix and the module path in snake case" do
      assert E2s.Names.silica_unit("ex_", "MyApp.HTTPServer") == "ex_my_app_http_server"
      assert E2s.Names.silica_unit("ex_", "Actors.Account") == "ex_actors_account"
      assert E2s.Names.snake("A1B") == "a1_b"
    end

    test "N4: ident/1 gives a valid identifier and leaves ordinary names as they are" do
      for name <- ~w(add sum_list is_ok Total_1 x_ _ _reason a_b_c camelCase), do: assert(E2s.Names.ident(name) == name)
      assert E2s.Names.ident("empty?") == "empty__q"
      assert E2s.Names.ident("fetch!") == "fetch__b"
      assert E2s.Names.ident("a-b") == "a__x2d_b"
      assert E2s.Names.ident("9lives") == "__x39_lives"
      assert E2s.Names.ident("") == "__e"
      assert E2s.Names.ident("a__b") == "a__x5f___x5f_b"
      assert E2s.Names.ident("a_?") == "a__x5f___q"
    end

    # The names the rule was written for, and more of the same kind.
    @awkward ["valid?", "valid__q", "valid_q", "a_?", "a__b", "_", "__", "+", "hello world", "1abc", "", "x_", "é", "save!",
              "valid", "valid_", "_valid", "__valid", "valid__", "a_b", "a__", "a___b", "?", "!", "?!", "_?", "?_", "__q", "__b",
              "__e", "__x5f_", "_x5f_", "x5f", "a__x3f_", "1", "12", "1_", "_1", "1__", "9lives", "é_", "_é", "é?", "é__q",
              "a.b", "a-b", "a b", "Total_1", "q", "b", "e", "x", "a_q", "a_b_", "__MODULE__", "日本", "a!b", "a_!", "empty?__2"]

    test "N4: ident/1 is injective: a left-to-right decoder reads every source name back" do
      for name <- @awkward do
        sent = E2s.Names.ident(name)
        assert sent =~ ~r/^[A-Za-z_][A-Za-z0-9_]*$/, "#{inspect(name)} -> #{sent}"
        assert decode(sent) == name, "#{inspect(name)} -> #{sent} -> #{inspect(decode(sent))}"
      end

      sent = Enum.map(@awkward, &E2s.Names.ident/1)
      assert Enum.uniq(sent) == sent
    end

    test "N4, arity: name__arity cannot be another name's spelling, and reads back" do
      names = for name <- @awkward, arity <- [0, 2, 12], do: {name, arity}
      sent = Enum.map(names, fn {name, arity} -> E2s.Names.function(name, arity, true) end)
      assert Enum.uniq(sent ++ Enum.map(@awkward, &E2s.Names.ident/1)) == sent ++ Enum.map(@awkward, &E2s.Names.ident/1)

      for {{name, arity}, sent} <- Enum.zip(names, sent) do
        assert [_, ident, digits] = Regex.run(~r/^(.*)__(\d+)$/s, sent)
        assert {decode(ident), String.to_integer(digits)} == {name, arity}
      end

      assert E2s.Names.function("fetch!", 2, true) == "fetch__b__2"
      assert E2s.Names.function("fetch!", 2, false) == "fetch__b"
    end

    test "N4, arity in frames: every arity of a name defined at several arities is name__arity, everywhere" do
      frames =
        typed("""
          @spec add(integer()) :: integer()
          def add(a), do: add(a, 1)

          @spec add(integer(), integer()) :: integer()
          def add(a, b), do: a + b

          @spec one(integer()) :: integer()
          def one(a), do: add(a)

          @spec adder() :: (integer(), integer() -> integer())
          def adder, do: &add/2

          @spec main() :: pid()
          def main, do: spawn(T, :add, [1])

          @spec main(integer()) :: integer()
          def main(n), do: one(n)
        """)

      names = for {:form, %{body: {:function, %{head: head}}}} <- frames, do: {head.name, head.arity}
      assert names == [{"add__1", 1}, {"add__2", 2}, {"one", 1}, {"adder", 0}, {"main__0", 0}, {"main__1", 1}]
      assert {:call, _, "", "add__2", [_, _]} = Enum.find(function(frames, "add__1", 1).code.nodes, &(elem(&1, 0) == :call))
      assert {:call, _, "", "add__1", [_]} = Enum.find(function(frames, "one", 1).code.nodes, &(elem(&1, 0) == :call))
      assert [{:fun_ref, 0, "", "add__2", 2} | _] = function(frames, "adder", 0).code.nodes
      assert [{:fun_ref, 0, "T", "add__1", 1} | _] = function(frames, "main__0", 0).code.nodes
      assert {:call, _, "", "one", [_]} = Enum.find(function(frames, "main__1", 1).code.nodes, &(elem(&1, 0) == :call))
      assert {:form, %{body: {:entry, %{function: "main__0", arity: 0}}}} = Enum.find(frames, &match?({:form, %{body: {:entry, _}}}, &1))
    end

    test "N4, arity: default arguments define several arities of the name (the function itself is still a gap)" do
      frames = Codex.string("defmodule T do\n  def f(a, b \\\\ 1), do: a + b\n  def g(a), do: f(a)\nend\n", "nofile", 0, strict: false)
      assert {:call, _, "", "f__1", [_]} = Enum.find(function(frames, "g", 1).code.nodes, &(elem(&1, 0) == :call))
    end

    test "N2, N3, N4, N5 in frames" do
      source = """
      defmodule My.Shop do
        defmodule Item do
          defstruct name: "", sold?: false
        end

        def sold?(%Item{sold?: sold?}), do: sold?
        def check!(item), do: {sold?(item), String.ends_with?(item.name, "!"), :EXIT, Item, &sold?/1}
      end
      """

      frames = Codex.string(source, "nofile", 0, strict: false)
      for frame <- frames, do: assert(:check_frame.check(frame) == :ok)
      assert [{:unit_begin, %{unit_name: "My.Shop", silica_unit: "ex_my_shop"}} | _] = frames
      assert [{:type, %{head: %{name: "my_shop_item"}, types: types}}] = for({:form, %{body: {:type, _} = t}} <- frames, do: t)
      assert {:t_record, [{"name", _}, {"sold__q", _}]} = List.last(types)
      assert [{:var, 0, "sold__q"}, {:record, 1, "my_shop_item", [{"sold__q", 0}], -1} | _] = function(frames, "sold__q", 1).code.nodes
      nodes = function(frames, "check__b", 1).code.nodes
      assert {:call, _, "", "sold__q", [_]} = Enum.find(nodes, &match?({:call, _, "", _, _}, &1))
      assert {:call, _, "String", "ends_with__q", [_, _]} = Enum.find(nodes, &match?({:call, _, "String", _, _}, &1))
      assert {:field, _, _, "name"} = Enum.find(nodes, &(elem(&1, 0) == :field))
      assert Enum.any?(nodes, &match?({:symbol, _, "EXIT"}, &1))
      assert Enum.any?(nodes, &match?({:symbol, _, "Elixir.My.Shop.Item"}, &1))
      assert Enum.any?(nodes, &match?({:fun_ref, _, "", "sold__q", 1}, &1))
    end
  end

  describe "release (M7, T6.13), against a stand-in listener inside the test (not a transpiler)" do
    test "sends (:release, {session}) as the only frame and returns the released reply" do
      port = stand_in_once(fn socket, frame -> reply(socket, {:released, %{session: elem(frame, 1).session, freed: true}}) end)
      assert {:ok, %{session: "intake_1:7", freed: true}} = E2s.Sender.release("127.0.0.1", port, "intake_1:7")
      assert_receive {:stand_in_got, {:release, %{session: "intake_1:7"}}}
    end

    test "freed false, a connection closed without a reply, and no listener are each reported" do
      port = stand_in_once(fn socket, _ -> reply(socket, {:released, %{session: "nope", freed: false}}) end)
      assert {:ok, %{freed: false}} = E2s.Sender.release("127.0.0.1", port, "nope")

      port = stand_in_once(fn _socket, _ -> :ok end)
      assert {:error, :closed_without_reply} = E2s.Sender.release("127.0.0.1", port, "intake_1:1")

      port = stand_in_once(fn socket, _ -> reply(socket, {:credit, 1}) end)
      assert {:error, {:unexpected_reply, {:credit, 1}}} = E2s.Sender.release("127.0.0.1", port, "intake_1:1")

      {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)
      :gen_tcp.close(listener)
      assert {:error, {:connect, _}} = E2s.Sender.release("127.0.0.1", port, "intake_1:1")
    end

    test "the command line: --release prints the reply; exit status 0 only when freed" do
      import ExUnit.CaptureIO
      port = stand_in_once(fn socket, _ -> reply(socket, {:released, %{session: "intake_2:3", freed: true}}) end)
      assert capture_io(fn -> assert E2s.CLI.run(["--port", "#{port}", "--release", "intake_2:3"]) == 0 end) =~ "released: session intake_2:3, freed true"

      port = stand_in_once(fn socket, _ -> reply(socket, {:released, %{session: "intake_2:3", freed: false}}) end)
      assert capture_io(fn -> assert E2s.CLI.run(["--port", "#{port}", "--release", "intake_2:3"]) == 1 end) =~ "freed false"

      port = stand_in_once(fn _socket, _ -> :ok end)
      assert capture_io(fn -> assert E2s.CLI.run(["--port", "#{port}", "--release", "intake_2:3"]) == 1 end) =~ "without a released frame"

      assert capture_io(fn -> assert E2s.CLI.run(["--release", "intake_2:3", "file.ex"]) == 2 end) =~ "usage"
    end
  end

  describe "sender, against a stand-in listener inside the test (not a transpiler)" do
    test "waits for the welcome, sends only under credit, reads until the result (T6.1, T6.2, T3.4)", %{frames: frames} do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: 4, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)
      test = self()

      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, hello} = :gen_tcp.recv(socket, 0)
        send(test, {:hello, :erlang.binary_to_term(hello)})
        # Nothing may follow the hello before the welcome.
        send(test, {:before_welcome, :gen_tcp.recv(socket, 0, 200)})
        reply(socket, {:welcome, %{session: "check-0-1", contract: 1, transpiler: "stand-in", flow: %{resume_from: 0, credit: 2, max_frame: 1_048_576}}})
        received = stand_in(socket, 2, [])
        reply(socket, {:rejected, %{seq: 1, reason: :bad_index, where: ".body"}})
        reply(socket, {:result, %{status: :failed, counts: %{units: 1, gaps: 4, rejected: 1}, session: "check-0-1", files: 0}})
        send(test, {:received, received})
      end)

      assert {:ok, %{welcome: %{session: "check-0-1"}, result: result, rejected: [%{seq: 1, reason: :bad_index}]}} =
               E2s.Sender.run("127.0.0.1", port, frames)

      assert result.status == :failed
      assert_received {:hello, hello}
      assert hello == hd(frames)
      assert_received {:before_welcome, {:error, :timeout}}
      assert_receive {:received, received}
      assert received == tl(frames)
    end

    test "reads replies while sending: more frames than the window, (:stored, n) then (:credit, 32) each half window (T6.3, T6.11a)" do
      source = "defmodule Big do\n" <> Enum.map_join(1..150, fn i -> "  @spec f#{i}(integer()) :: integer()\n  def f#{i}(a), do: a + #{i}\n" end) <> "end\n"
      frames = [Codex.hello(:transpile) | Codex.string(source)] ++ [{:end, %{seq: 152, units: 1}}]
      assert length(frames) == 154
      {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: 4, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)
      test = self()

      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _hello} = :gen_tcp.recv(socket, 0)
        reply(socket, {:welcome, %{session: "intake_1:42", contract: 1, transpiler: "stand-in", flow: %{resume_from: 0, credit: 64, max_frame: 1_048_576}}})
        received = window(socket, 64, 0, [])
        reply(socket, {:stored, length(received)})
        reply(socket, {:result, %{status: :ok, counts: %{units: 1, gaps: 0, rejected: 0}, session: "intake_1:42", files: 3}})
        send(test, {:received, received})
      end)

      assert {:ok, %{welcome: %{session: "intake_1:42"}, result: %{status: :ok, session: "intake_1:42"}, stored: 153, sent: 153, rejected: []}} =
               E2s.Sender.run("127.0.0.1", port, frames)

      assert_receive {:received, received}
      assert received == tl(frames)
    end

    test "resume (T6.5, T6.5a): the hello names the session, only the frames from resume_from are sent; a stored end sends nothing" do
      frames = Codex.frames([@demo], :transpile, session: "intake_1:42")
      assert {:hello, %{session: "intake_1:42"}} = hd(frames)
      {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: 4, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)
      test = self()
      result = {:result, %{status: :partial, counts: %{units: 1, gaps: 8, rejected: 0}, session: "intake_1:42", files: 3}}
      welcome = fn from, credit -> {:welcome, %{session: "intake_1:42", contract: 1, transpiler: "stand-in", flow: %{resume_from: from, credit: credit, max_frame: 1_048_576}}} end

      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, hello} = :gen_tcp.recv(socket, 0)
        send(test, {:hello, :erlang.binary_to_term(hello)})
        reply(socket, welcome.(30, 64))
        received = window(socket, 64, 0, [])
        reply(socket, result)
        send(test, {:received, received})

        # the same session again, its (:end) already stored: credit 0, the result follows
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _hello} = :gen_tcp.recv(socket, 0)
        reply(socket, welcome.(length(frames) - 1, 0))
        send(test, {:after_end, :gen_tcp.recv(socket, 0, 100)})
        reply(socket, result)
      end)

      assert {:ok, %{result: %{status: :partial}, sent: sent}} = E2s.Sender.run("127.0.0.1", port, frames)
      assert_receive {:hello, {:hello, %{session: "intake_1:42"}}}
      assert_receive {:received, received}
      assert received == Enum.drop(frames, 31)
      assert sent == length(received)

      assert {:ok, %{result: %{status: :partial}, sent: 0}} = E2s.Sender.run("127.0.0.1", port, frames)
      assert_receive {:after_end, {:error, :timeout}}
    end

    test "the command line prints the session id, the sender's gaps, T1002 and T4003 diagnostics, and a failed result (T5.3b, T6.8)" do
      import ExUnit.CaptureIO
      {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: 4, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)
      diagnostic = fn code, message -> {:diagnostic, %{seq: -1, unit_name: "Actors", finding: %{severity: :error, code: code, message: message}, place: %{file: "actors.ex", line: 0, column: 0}}} end

      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _hello} = :gen_tcp.recv(socket, 0)
        reply(socket, {:welcome, %{session: "intake_2:7", contract: 1, transpiler: "stand-in", flow: %{resume_from: 0, credit: 64, max_frame: 1_048_576}}})
        window(socket, 64, 0, [])
        reply(socket, diagnostic.("T1002", "unit_end says 3 forms, 15 were sent"))
        reply(socket, diagnostic.("T4003", "nothing of the unit could be written"))
        reply(socket, {:result, %{status: :failed, counts: %{units: 1, gaps: 2, rejected: 0}, session: "intake_2:7", files: 0}})
      end)

      output = capture_io(fn -> assert E2s.CLI.run(["--port", "#{port}", "--mode", "transpile", @actors]) == 1 end)
      assert output =~ "session intake_2:7 (stand-in): 28 of 28 frames sent"
      assert output =~ "gaps sent by this sender: 0 (0 for a type or conversion it could not state, 0 outside the subset)"
      assert output =~ "error T1002: unit_end says 3 forms, 15 were sent (actors.ex:0)"
      assert output =~ "error T4003: nothing of the unit could be written"
      assert output =~ "result: :failed (units 1, gaps 2, rejected 0, files 0)"
      assert capture_io(fn -> assert E2s.CLI.run(["--resume", "intake_2:7", @actors]) == 2 end) =~ "usage"
      assert capture_io(fn -> assert E2s.CLI.run(["--gaps", @gaps]) == 0 end) =~ "Gaps max_of line 24: missing type: function signature"
      assert capture_io(fn -> assert E2s.CLI.run(["--gaps", @demo]) == 0 end) =~ "gaps sent by this sender: 0 ("
      assert capture_io(fn -> assert E2s.CLI.run(["--split", @actors]) == 0 end) =~ "defp main/0-k1(account) do"
    end

    test "a refused hello and a closed port are reported" do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: 4, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)

      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _hello} = :gen_tcp.recv(socket, 0)
        reply(socket, {:refused, %{reason: :contract, detail: "version 1 only"}})
      end)

      assert {:refused, %{reason: :contract}} = E2s.Sender.run("127.0.0.1", port, [Codex.hello(:check)])
      :gen_tcp.close(listener)
      assert {:error, {:connect, _}} = E2s.Sender.run("127.0.0.1", port, [Codex.hello(:check)])
    end
  end

  describe "examples/actors.ex, the working application of three actors" do
    setup do
      %{actors: Codex.frames([@actors], :check)}
    end

    test "every frame passes check_frame; children come before parents (T9.2)", %{actors: frames} do
      for frame <- frames, do: assert(:check_frame.check(frame) == :ok, "#{inspect(frame, limit: 6)}")

      for {:form, %{body: {:function, %{head: head, code: %{nodes: nodes}}}}} <- frames, {node, i} <- Enum.with_index(nodes) do
        for child <- children(node), do: assert(child < i and child >= -1, "#{head.name}: node #{i} #{inspect(node)}")
      end
    end

    test "the unit, the struct as a type form, the entry (T9.6)", %{actors: frames} do
      assert [{:hello, _}, {:unit_begin, %{unit_name: "Actors", silica_unit: "ex_actors"}} | rest] = frames
      forms = for {:form, %{body: body}} <- rest, do: body
      assert [{:type, %{head: %{name: "actors_account"}, types: types, root: root}}] = for({:type, _} = t <- forms, do: t)
      assert {:t_record, [{"owner", _}, {"balance", _}, {"moves", _}]} = Enum.at(types, root)
      assert {:entry, %{function: "main", arity: 0}} in forms
    end

    test "the actors' nodes: spawn linked and not, send, receive with and without a timeout (H20..H23, H26)", %{actors: frames} do
      nodes = nodes(frames)
      kinds = nodes |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      for kind <- [:self, :spawn, :send, :receive, :fail, :record, :field, :match, :case, :cond, :lambda, :text, :float],
          do: assert(kind in kinds, "no #{kind} node")

      # supervisor/1 traps exits: its spawn_link is sent as an unlinked spawn of the linked copy account__l
      assert Enum.sort(for({:spawn, _, _, _, link} <- nodes, do: link)) == [false, false]
      assert Enum.sort(for({:spawn, _, _, args, false} <- nodes, do: length(args))) == [0, 1]
      # receives without a timeout (account/1, main/0, ...) and with one (withdraw_from/2, report/1 and their copies)
      assert Enum.uniq(for({:receive, _, _, timeout, _} <- nodes, do: timeout == -1)) |> Enum.sort() == [false, true]
      assert :sl_call in kinds
    end

    test "the application's idioms: an alias pattern in deposit/2, ^child in supervisor/1", %{actors: frames} do
      [clause] = function(frames, "deposit", 2).code.clauses
      nodes = function(frames, "deposit", 2).code.nodes
      assert {:clause, _, [alias, _amount], -1, _} = Enum.at(nodes, clause)
      assert {:match, _, record, var} = Enum.at(nodes, alias)
      assert {:record, _, "actors_account", [{"balance", _}, {"moves", _}], -1} = Enum.at(nodes, record)
      assert {:var, _, "account"} = Enum.at(nodes, var)

      nodes = function(frames, "supervisor", 1).code.nodes
      assert ["_pin_1", "_pin_2"] == for({:var, _, "_pin" <> _ = name} <- nodes, uniq: true, do: name)
      assert 2 == Enum.count(nodes, &match?({:op, _, "=:=", _}, &1))
    end

    test "no gap: the split, the trapped exit and the output are lowered by the sender", %{actors: frames} do
      assert gaps(frames) == 0
      assert Codex.gaps(frames) == []

      # 11 functions of the source and 12 the split made, in the order the split named them
      names = for {:form, %{body: {:function, %{head: head}}}} <- frames, do: {head.name, head.arity, head.exported}
      made = for {name, arity, false} <- names, do: {name, arity}

      assert made == [{"account__l", 2}, {"main__k1", 1}, {"main__k2", 2}, {"withdraw_from__c1", 3}, {"withdraw_from__c1__k1", 1},
                      {"main__k3", 2}, {"withdraw_from__c2", 3}, {"withdraw_from__c2__k1", 1}, {"main__k4", 2}, {"report__c1", 2},
                      {"report__c1__k1", 1}, {"main__k5", 0}]

      assert length(names) == 23
    end

    test "by eye: mean_move/2 (`/` on integers) is to_float on both operands under the zero guard", %{actors: frames} do
      f = function(frames, "mean_move", 2)
      assert [{"to_float", [{:var, _, "balance"}]}, {"to_float", [{:var, _, "moves"}]}, {"==", [{:op, _, "to_float", _}, {:float, _, "0.0"}]},
              {"to_float", [{:var, _, "moves"}]}, {"/", [{:op, _, "to_float", _}, {:op, _, "to_float", _}]}] = ops(f)

      assert [{:cond, at, [guard, division]}] = Enum.filter(f.code.nodes, &(elem(&1, 0) == :cond))
      assert {:clause, _, [], _, fail} = Enum.at(f.code.nodes, guard)
      assert {:fail, _, reason} = Enum.at(f.code.nodes, fail)
      assert {:symbol, _, "badarith"} = Enum.at(f.code.nodes, reason)
      assert {:clause, _, [], _, _} = Enum.at(f.code.nodes, division)
      assert hints(f)[at] == {float(), :inferred}
    end

    test "a received message is typed by its clause's literals, guards and pins (T8.10 e)", %{actors: frames} do
      f = function(frames, "account", 1)
      pid = {:t_actor, {:t_basic, :dynamic}}
      message_types = for {_, {{:t_tagged, tag, elems}, :inferred}} <- hints(f), tag in ~w(deposit withdraw report), do: {tag, elems}
      assert Enum.sort(message_types) == [{"deposit", [int()]}, {"report", [pid]}, {"withdraw", [int(), pid]}]
      refute Enum.any?(f.code.nodes, &match?({:call, _, "Kernel", _, _}, &1))
    end

    test "T8.16: a type test that only states a type is not sent as a guard; the other tests are", %{actors: frames} do
      f = function(frames, "account", 1)
      node = &Enum.at(f.code.nodes, &1)

      guards =
        for {:clause, _, [p], g, _} <- f.code.nodes, {:tuple, _, [tag | _]} <- [node.(p)], {:symbol, _, name} <- [node.(tag)], into: %{} do
          {name, if(g == -1, do: :none, else: node.(g))}
        end

      # `is_integer(amount) and amount > 0` is `amount > 0`; `is_integer(amount) and is_pid(from)` and `is_pid(from)`
      # are no guard: the types are the hints on the patterns.
      assert {:op, _, ">", _} = guards["deposit"]
      assert guards["withdraw"] == :none
      assert guards["report"] == :none
      refute Enum.any?(f.code.nodes, &match?({:boolean, _, true}, &1))
      refute Enum.any?(f.code.nodes, &match?({:op, _, "andalso", _}, &1))
    end

    test "T8.16: a type test the stated type does not answer is still sent" do
      frames = typed("""
        @spec f(integer() | atom()) :: integer()
        def f(x) when is_integer(x), do: 1
        def f(_), do: 0
      """)

      f = function(frames, "f", 1)
      assert Enum.any?(f.code.nodes, &match?({:call, _, "Kernel", "is_integer", _}, &1))
    end

    test "the application runs as Elixir and prints what its header says" do
      {output, 0} = System.cmd("elixir", ["-r", @actors, "-e", "Actors.main()"])

      assert String.split(output, "\n", trim: true) ==
               ["{:refused, 30}", "{:ok, 40}", "ada: low", "{:balance, 40, :mean_move, 13.333333333333334}", "account closed"]
    end

    unless System.get_env("TO_SILICA_PORT") do
      @tag skip: "TO_SILICA_PORT is not set: the check-mode session with a transpiler did not run"
    end

    test "online: check mode accepts every frame: result ok", %{actors: frames} do
      port = "TO_SILICA_PORT" |> System.fetch_env!() |> String.to_integer()
      assert {:ok, %{result: result, rejected: []}} = E2s.Sender.run("127.0.0.1", port, frames)
      assert %{status: :ok, counts: %{units: 1, gaps: 0, rejected: 0}, files: 0} = result
    end
  end

  describe "examples/three_nodes, a node program (E2s.Node, contract T9.17)" do
    setup do
      %{
        hub: Codex.frames(["examples/three_nodes/hub.ex"], :check),
        a: Codex.frames(["examples/three_nodes/edge_a.ex"], :check),
        c: Codex.frames(["examples/three_nodes/edge_c.ex"], :check)
      }
    end

    test "every frame of the three programs passes check_frame, and none is a gap", %{hub: hub, a: a, c: c} do
      for frames <- [hub, a, c] do
        for frame <- frames, do: assert(:check_frame.check(frame) == :ok, "#{inspect(frame, limit: 6)}")
        assert gaps(frames) == 0
      end
    end

    test "@silica_node is one (:node) form: the hub listens for a and c, which EPMD finds (port 0)", %{hub: hub} do
      assert [{:node, node}] = for({:form, %{body: {:node, _} = body}} <- hub, do: body)
      assert node.name == "hub@localhost"
      assert node.net.epmd_port == 4369
      assert for(p <- node.tables.peers, do: {p.name, p.role, p.port}) == [{"a@localhost", :listen, 0}, {"c@localhost", :listen, 0}]
      assert [%{name: "hub_in", tag: "request", fields: ["atom", "int64"]}] = node.tables.locals
      assert for(r <- node.tables.remotes, do: {r.name, r.peer, r.tag}) == [{"a_inbox", "a@localhost", "reply"}, {"c_inbox", "c@localhost", "reply"}]
    end

    test "send({name, node}, message) to a declared remote is H39 (:send_named)", %{hub: hub, a: a} do
      assert for({:send_named, _, name, _} <- nodes(hub), do: name) |> Enum.sort() == ["a_inbox", "c_inbox"]
      assert for({:send_named, _, name, _} <- nodes(a), do: name) == ["hub_in"]
    end

    test "a send to a node that is not declared is a gap that says so" do
      source = """
      defmodule Nn do
        @spec f() :: :ok
        def f do
          send({:x, :"z@nowhere"}, {:hello, 1})
          :ok
        end
      end
      """

      frames = Codex.string(source, "nn.ex")
      assert [{:gap_node, _, _, note}] = for({:gap_node, _, _, _} = n <- nodes(frames), do: n)
      assert note =~ "@silica_node"
    end
  end

  describe "examples/three_nodes_mesh, a complete mesh of three nodes" do
    setup do
      %{mesh: for(x <- ~w(a b c), do: Codex.frames(["examples/three_nodes_mesh/mesh_#{x}.ex"], :check))}
    end

    test "every frame of the three programs passes check_frame, and none is a gap", %{mesh: mesh} do
      for frames <- mesh do
        for frame <- frames, do: assert(:check_frame.check(frame) == :ok, "#{inspect(frame, limit: 6)}")
        assert gaps(frames) == 0
      end
    end

    test "a listens for both, b dials a and listens for c, c dials both; only a node that dials states redial", %{mesh: mesh} do
      decls = for frames <- mesh, do: hd(for({:form, %{body: {:node, node}}} <- frames, do: node))

      assert for(d <- decls, do: for(p <- d.tables.peers, do: {p.name, p.role})) == [
               [{"mb@localhost", :listen}, {"mc@localhost", :listen}],
               [{"ma@localhost", :dial}, {"mc@localhost", :listen}],
               [{"ma@localhost", :dial}, {"mb@localhost", :dial}]
             ]

      assert for(d <- decls, do: {d.timing.redial_initial_ms, d.timing.redial_max_ms}) == [{-1, -1}, {250, 4000}, {250, 4000}]
    end

    test "each node sends a request and an answer to both others (H39)", %{mesh: mesh} do
      assert for(frames <- mesh, do: for({:send_named, _, name, _} <- nodes(frames), do: name) |> Enum.sort()) == [
               ~w(b_in b_inbox c_in c_inbox),
               ~w(a_in a_inbox c_in c_inbox),
               ~w(a_in a_inbox b_in b_inbox)
             ]
    end
  end

  describe "examples/five_nodes_mesh, a complete mesh of five nodes (ten links)" do
    setup do
      %{five: for(x <- ~w(a b c d e), do: Codex.frames(["examples/five_nodes_mesh/mesh5_#{x}.ex"], :check))}
    end

    test "every frame of the five programs passes check_frame, and none is a gap", %{five: five} do
      for frames <- five do
        for frame <- frames, do: assert(:check_frame.check(frame) == :ok, "#{inspect(frame, limit: 6)}")
        assert gaps(frames) == 0
      end
    end

    test "every node has four peers and the nodes dial 0, 1, 2, 3 and 4 of them", %{five: five} do
      peers = for frames <- five, do: hd(for({:form, %{body: {:node, node}}} <- frames, do: node.tables.peers))
      assert Enum.map(peers, &length/1) == [4, 4, 4, 4, 4]
      assert for(ps <- peers, do: Enum.count(ps, &(&1.role == :dial))) == [0, 1, 2, 3, 4]
    end

    test "each node sends a request and an answer to all four others (H39)", %{five: five} do
      for frames <- five do
        assert for({:send_named, _, name, _} <- nodes(frames), do: name) |> Enum.uniq() |> length() == 8
      end
    end
  end

  describe "online" do
    unless System.get_env("TO_SILICA_PORT") do
      @tag skip: "TO_SILICA_PORT is not set: the check-mode session with a transpiler did not run"
    end

    test "check mode accepts every frame: result ok", %{frames: frames, gap_frames: gap_frames} do
      port = "TO_SILICA_PORT" |> System.fetch_env!() |> String.to_integer()
      assert {:ok, %{result: result, rejected: rejected, diagnostics: diagnostics}} = E2s.Sender.run("127.0.0.1", port, frames)
      assert rejected == [], inspect(diagnostics)
      assert %{status: :ok, counts: %{units: 1, gaps: 0, rejected: 0}, files: 0} = result
      # the fixture of the gaps: every gap is counted, none is rejected
      assert {:ok, %{result: result, rejected: []}} = E2s.Sender.run("127.0.0.1", port, gap_frames)
      assert %{status: :ok, counts: %{units: 1, gaps: @expected_gaps, rejected: 0}, files: 0} = result
      assert result.counts.gaps == gaps(gap_frames)
    end
  end

  # ------------------------------------------------------------------ helpers

  defp nodes(frames), do: for({:form, %{body: {:function, %{code: %{nodes: nodes}}}}} <- frames, node <- nodes, do: node)

  defp gaps(frames) do
    Enum.count(nodes(frames), &(elem(&1, 0) == :gap_node)) + Enum.count(frames, &match?({:form, %{body: {:gap, _}}}, &1))
  end

  defp functions(frames), do: for({:form, %{body: {:function, function}}} <- frames, do: function)

  defp function(frames, name, arity) do
    Enum.find_value(frames, fn
      {:form, %{body: {:function, %{head: %{name: ^name, arity: ^arity}} = function}}} -> function
      _ -> nil
    end)
  end

  # The inverse of E2s.Names.ident/1, reading left to right: `__` starts an escape, everything else is itself.
  defp decode("__e"), do: ""

  defp decode(sent) do
    Regex.replace(~r/__(q|b|x([0-9a-f]+)_)/, sent, fn
      _, "q", _ -> "?"
      _, "b", _ -> "!"
      _, _, hex -> <<String.to_integer(hex, 16)::utf8>>
    end)
  end

  defp reply(socket, term), do: :ok = :gen_tcp.send(socket, :erlang.term_to_binary(term))

  # Reads frames until {:end, ...}. It grants two more credits only when the sender has used up what it holds,
  # so a sender that ignores credit is caught: a frame arriving with no credit left fails the test.
  defp stand_in(socket, credit, acc) do
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 5000)
    frame = :erlang.binary_to_term(bytes)
    if credit == 0, do: raise("a frame was sent without credit: #{inspect(frame, limit: 4)}")

    cond do
      elem(frame, 0) == :end ->
        Enum.reverse([frame | acc])

      credit == 1 ->
        # Out of credit now: the sender must be silent until it is given more.
        {:error, :timeout} = :gen_tcp.recv(socket, 0, 20)
        reply(socket, {:credit, 2})
        stand_in(socket, 2, [frame | acc])

      true ->
        stand_in(socket, credit - 1, [frame | acc])
    end
  end

  # The transpiler's window as built (T6.3): reads frames until {:end, ...}; each time half the window (32) has
  # been used it answers (:stored, next) and then (:credit, 32). A frame that arrives when no credit is left
  # fails the test.
  defp window(socket, credit, used, acc) do
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 5000)
    frame = :erlang.binary_to_term(bytes)
    if credit == 0, do: raise("a frame was sent without credit: #{inspect(frame, limit: 4)}")
    acc = [frame | acc]

    cond do
      elem(frame, 0) == :end ->
        Enum.reverse(acc)

      used + 1 == 32 ->
        reply(socket, {:stored, elem(frame, 1).seq + 1})
        reply(socket, {:credit, 32})
        window(socket, credit - 1 + 32, 0, acc)

      true ->
        window(socket, credit - 1, used + 1, acc)
    end
  end

  # A listener that accepts one connection, reads one frame, tells the test and lets `answer` reply, then closes.
  defp stand_in_once(answer) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: 4, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    test = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      {:ok, bytes} = :gen_tcp.recv(socket, 0, 5000)
      frame = :erlang.binary_to_term(bytes)
      send(test, {:stand_in_got, frame})
      answer.(socket, frame)
      :gen_tcp.close(socket)
      :gen_tcp.close(listener)
    end)

    port
  end

  # The node table of the function f that `defs` defines (one or more `def f(...)` clauses).
  defp clauses(defs) do
    frames = Codex.string("defmodule T do\n  #{defs}\nend\n", "nofile", 0, strict: false)
    for frame <- frames, do: assert(:check_frame.check(frame) == :ok)
    {:form, %{body: {:function, %{code: %{nodes: nodes}}}}} = Enum.find(frames, &match?({:form, %{body: {:function, _}}}, &1))
    nodes
  end

  # The frames of a module whose body is `defs`, typed as the command line types (contract 8.6).
  defp typed(defs) do
    frames = Codex.string("defmodule T do\n#{defs}\nend\n")
    for frame <- frames, do: assert(:check_frame.check(frame) == :ok, inspect(frame, limit: :infinity))
    frames
  end

  # The hints of a function form, read back: node => {type written out, strength}.
  defp hints(%{types: types, notes: %{hints: hints}}), do: Map.new(hints, &{&1.node, {nested(types, &1.type), &1.strength}})

  defp nested(types, i) do
    case Enum.at(types, i) do
      {:t_tuple, is} -> {:t_tuple, Enum.map(is, &nested(types, &1))}
      {:t_tagged, tag, is} -> {:t_tagged, tag, Enum.map(is, &nested(types, &1))}
      {:t_union, is} -> {:t_union, Enum.map(is, &nested(types, &1))}
      {:t_fun, is, r} -> {:t_fun, Enum.map(is, &nested(types, &1)), nested(types, r)}
      {:t_actor, m} -> {:t_actor, nested(types, m)}
      {:t_named, name, is} -> {:t_named, name, Enum.map(is, &nested(types, &1))}
      leaf -> leaf
    end
  end

  defp int, do: {:t_int, :i64}
  defp float, do: {:t_float, :f64}

  # The gap nodes of a function form: [{construct, note}].
  defp gap_nodes(function), do: for({:gap_node, _, construct, note} <- function.code.nodes, do: {construct, note})

  # The operators of a function form, in order: [{op, [operand node]}].
  defp ops(function), do: for({:op, _, op, args} <- function.code.nodes, do: {op, Enum.map(args, &Enum.at(function.code.nodes, &1))})

  # The node table of `def f, do: <source>` in a module that defines nothing else.
  defp body(source) do
    frames = Codex.string("defmodule T do\n  def f do\n#{source}\n  end\nend\n", "nofile", 0, strict: false)
    for frame <- frames, do: assert(:check_frame.check(frame) == :ok)
    function(frames, "f", 0).code.nodes
  end

  # Every integer or list of integers after the location is a child index in the node kinds this codex writes,
  # except the literal of {:int, ...} and the arity of {:fun_ref, ...}.
  defp children({:int, _, _}), do: []
  defp children({:fun_ref, _, _, _, _}), do: []

  defp children(node) do
    [_tag, _at | fields] = Tuple.to_list(node)

    Enum.flat_map(fields, fn
      i when is_integer(i) -> [i]
      list when is_list(list) -> Enum.map(list, fn {_, i} -> i; i -> i end)
      _ -> []
    end)
  end
end
