%% e2s_test: the tests of erlang-to-silica-poc. Run with test/run_test.sh [port].
%%
%%   mappings()  one small test per construct mapping: a source snippet in, the expected nodes out.
%%               THIS IS THE TEMPLATE: when you add a mapping to e2s_codex, add one line here.
%%   typing()    one small test per typing rule (contract 8.6): the hints and the conversions a snippet must
%%               carry, and the gap it must become when Erlang gives no type. hinted/3 is the template.
%%   split()     what e2s_split does before anything is sent (README, "Processes: what this sender splits"): a
%%               receive with code after it, several receives, a call of a function that receives, trap_exit with
%%               spawn_link, a literal in a record pattern; and io:format as L1 calls (contract T9.16).
%%               split/3 is the template: a snippet and what its frames must hold.
%%   supervisor() what e2s_sup reads of OTP's supervisor behaviour (README, "A static supervisor"): a supervisor
%%               start is sent as its static children (contract T9.14b), with the restart and the strategy the
%%               source writes; what cannot be read is a gap that says so. sup/3 is the template.
%%   names()     the naming scheme (README, "Names"): ident/1 with its decoder, the arity suffix.
%%   demo()      examples/demo.erl: every frame passes the contract's Erlang binding checker
%%               (../contract/bindings/erlang/check_frame.erl), post-order (T9.2), seq (T5.1), coverage, gaps,
%%               and the typing rules T8.10 to T8.12 as typing_faults/1 below reads them.
%%   actors()    examples/actors.erl, the working application: what its frames must hold.
%%   flow()      e2s_sender:run/3 against stand-in listeners inside the test: credit, (:stored), resume.
%%   release()   e2s_sender:release/3 against a stand-in listener inside the test (M7, R9).
%%   online(P)   only with a port: both examples in check mode (contract 6.5) must end `ok`; a release of an
%%               unknown session must answer freed = false.
-module(e2s_test).
-export([main/0, main/1, typing_faults/1, decode/1]).

main() -> main([]).

main(Args) ->
    Online = case Args of
                 [Port] -> online(list_to_integer(atom_to_list(Port)));
                 [] -> io:format("(no port given: the online part did not run)~n"), []
             end,
    Results = mappings() ++ typing() ++ split() ++ supervisor() ++ names() ++ demo() ++ actors() ++ node_program() ++ flow() ++ release() ++ Online,
    [io:format("~s  ~s~n", [case Ok of true -> "ok  "; false -> "FAIL"; transpiler_fault -> "TRANSPILER FAULT" end, Name])
     || {Name, Ok} <- Results],
    Failed = length([x || {_, false} <- Results]),
    Faults = length([x || {_, transpiler_fault} <- Results]),
    io:format("~p tests, ~p failed, ~p not decided because the transpiler ended~n", [length(Results), Failed, Faults]),
    halt(case Failed of 0 -> 0; _ -> 1 end).

%% ------------------------------------------------------------------ one test per mapping (the template)

%% {Name, Source of a function f (with its -spec: a function without one is a gap), the nodes its frame must
%% contain (the `at` field is ignored)}.
mappings() ->
    [mapping("H7 the empty list", "-spec f() -> [integer()].\nf() -> [].", [{nil}]),
     mapping("H10 a literal list", "-spec f(integer()) -> [integer()].\nf(A) -> [A, 1].",
             [{var, <<"A">>}, {int, 1}, {list, [1, 2], -1}]),
     mapping("H9 a list cell with a computed tail", "-spec f(integer(), [integer()]) -> [integer()].\nf(H, T) -> [H | T].",
             [{cons, 2, 3}]),
     mapping("H9 a list cell as a pattern", "-spec f([integer()]) -> {integer(), [integer()]}.\nf([H | T]) -> {H, T}.",
             [{var, <<"H">>}, {var, <<"T">>}, {cons, 0, 1}]),
     mapping("H10 a string is a list of character codes", "-spec f() -> string().\nf() -> \"ab\".",
             [{int, $a}, {int, $b}, {list, [0, 1], -1}]),
     mapping("H4 a binary literal is bytes", "-spec f() -> binary().\nf() -> <<\"ab\">>.", [{bytes, <<"ab">>}]),
     mapping("Appendix B ++", "-spec f([integer()], [integer()]) -> [integer()].\nf(A, B) -> A ++ B.", [{op, <<"++">>, [2, 3]}]),
     mapping("H18 an alias pattern is a match in pattern position",
             "-spec f({integer(), integer()}) -> {{integer(), integer()}, integer()}.\nf(P = {X, _}) -> {P, X}.",
             [{var, <<"P">>}, {var, <<"X">>}, {wild}, {tuple, [1, 2]}, {match, 0, 3}]),
     mapping("H12 a record is named <module>_<record> (N3)", "-record(r, {a :: integer()}).\n-spec f() -> #r{}.\nf() -> #r{a = 1}.",
             [{record, <<"snippet_r">>, [{<<"a">>, 0}], -1}]),
     mapping("H13 field access", "-record(r, {a :: integer()}).\n-spec f(#r{}) -> integer().\nf(R) -> R#r.a.", [{field, 1, <<"a">>}]),
     mapping("H21 spawn_link is a linked spawn", "-spec f() -> pid().\nf() -> spawn_link(fun() -> ok end).", [{spawn, 2, [], true}]),
     mapping("H23 receive with after", "-spec f() -> integer() | late.\nf() -> receive X when is_integer(X) -> X after 10 -> late end.",
             [{'receive', [2], 3, 4}]),
     mapping("T8.16 a type test that only states the pattern's type is not sent as a guard",
             "-spec f() -> integer().\nf() -> receive {add, N} when is_integer(N) -> N end.",
             [{clause, [2], -1, 3}]),
     mapping("T8.16 the other tests of the guard are sent",
             "-spec f() -> integer().\nf() -> receive {add, N} when is_integer(N), N > 0 -> N end.",
             [{op, <<">">>, [3, 4]}, {clause, [2], 5, 6}]),
     mapping("H39 a send to a registered name", "-spec f(integer()) -> ok.\nf(N) -> keeper ! {add, N}, ok.",
             [{tuple, [1, 2]}, {send_named, <<"keeper">>, 3}]),
     mapping("T9.10 register/2 outside a supervisor's start function is a gap (T9.14b: only a static child has a name)",
             "-spec f(pid()) -> true.\nf(P) -> register(keeper, P).",
             [{gap_node, <<"erlang:register/2">>,
               <<"a name is given only to a supervisor's static child, in its start function (contract T9.14b: the "
                 "transpiler writes no other (:register)); a send to a name is sent (H39)">>}]),
     mapping("H26 exit/1 is fail", "-spec f() -> ok.\nf() -> exit(oops).", [{symbol, <<"oops">>}, {fail, 0}]),
     mapping("H32 a call to another module keeps the module as written (N2)",
             "-spec f([integer()]) -> [integer()].\nf(L) -> lists:reverse(L).", [{call, <<"lists">>, <<"reverse">>, [1]}]),
     mapping("H33 a call through a fun value", "-spec f(fun((integer()) -> integer())) -> integer().\nf(F) -> F(1).",
             [{apply, 1, [2]}]),
     mapping("T9.10 try is a gap (the contract's H27 does not give the shape of a catch clause)",
             "-spec f() -> ok | error.\nf() -> try g() catch _:_ -> error end.\n-spec g() -> ok.\ng() -> ok.",
             [{gap_node, <<"try">>, <<"outside the proof of concept">>}]),
     mapping("T9.10 process_flag/2 is a gap (the contract has no node for trapping exits)",
             "-spec f() -> boolean().\nf() -> process_flag(trap_exit, true).",
             [{gap_node, <<"erlang:process_flag/2">>, <<"outside the proof of concept">>}]),
     mapping("T9.10 a map is a gap", "-spec f() -> ok.\nf() -> #{}.", [{gap_node, <<"map">>, <<"outside the proof of concept">>}])].

mapping(Name, Source, Expected) ->
    Frames = snippet(Source),
    Nodes = [strip_at(N) || N <- function_nodes(<<"f">>, Frames)],
    Ok = sound(Frames) andalso [] =:= Expected -- Nodes,
    Ok orelse io:format("  ~s: wanted ~p in ~p~n  typing faults: ~p~n", [Name, Expected, Nodes, typing_faults(Frames)]),
    {"mapping: " ++ Name, Ok}.

%% What every frame of every test must satisfy: the binding's shape checker, T9.2, and the typing rules.
sound(Frames) ->
    lists:all(fun(F) -> check_frame:check(F) =:= ok end, Frames)
        andalso lists:all(fun post_order/1, Frames)
        andalso typing_faults(Frames) =:= [].

%% The frames of a module `snippet` holding Source.
snippet(Source) ->
    File = filename:join("ebin", "snippet.erl"),
    ok = file:write_file(File, ["-module(snippet).\n-compile(export_all).\n", Source, "\n"]),
    e2s_codex:frames([File], check).

function(Name, Frames) ->
    case [F || {form, #{body := {function, F = #{head := #{name := N}}}}} <- Frames, N =:= Name] of
        [F | _] -> F;
        [] -> none
    end.

function_nodes(Name, Frames) ->
    case function(Name, Frames) of
        #{code := #{nodes := Nodes}} -> Nodes;
        none -> []
    end.

strip_at(Node) -> erlang:delete_element(2, Node).

%% ------------------------------------------------------------------ typing (contract 8.6)

%% hinted(Name, Source, Expected): the function f must carry these hints, each written as
%% {the node without its `at`, the hinted type written out as a nested term, the strength}; and no gap.
typing() ->
    I = {t_int, i64}, F = {t_float, f64}, Bool = {t_basic, boolean},
    [hinted("T8.10 a: the -spec is the signature hint (declared)", "-spec f(integer(), float()) -> boolean().\nf(_, _) -> true.",
            [{signature, {t_fun, [I, F], Bool}, declared}]),
     hinted("T8.10 b: a local variable's binding is hinted with the type of what it is bound to (inferred)",
            "-spec f(integer()) -> integer().\nf(A) -> X = A + 1, X.",
            [{{var, <<"X">>}, I, inferred}, {{match, 4, 3}, I, inferred}, {{op, <<"+">>, [1, 2]}, I, inferred}]),
     hinted("T8.10 b, d: bound to a call, the type is the callee's -spec result (declared)",
            "-spec f(integer()) -> float().\nf(A) -> X = g(A), X.\n-spec g(integer()) -> float().\ng(_) -> 1.5.",
            [{{call, <<>>, <<"g">>, [1]}, F, declared}, {{var, <<"X">>}, F, declared}]),
     hinted("T8.10 b: a pattern takes the matched type apart, position by position",
            "-spec f({ok, integer()} | {error, atom()}) -> integer().\nf(R) -> case R of {ok, N} -> N; {error, _} -> 0 end.",
            [{{var, <<"N">>}, I, declared}, {{'case', 1, [6, 11]}, I, inferred}]),
     hinted("T8.10 d: a call whose value is dropped is hinted",
            "-spec f(integer()) -> integer().\nf(A) -> g(A), A.\n-spec g(integer()) -> ok.\ng(_) -> ok.",
            [{{call, <<>>, <<"g">>, [1]}, {t_symbols, [<<"ok">>]}, declared}]),
     hinted("T8.10 d: the result of a function the codex knows (bif_type/3)",
            "-spec f([integer()]) -> integer().\nf(L) -> length(L) + 1.",
            [{{call, <<"erlang">>, <<"length">>, [1]}, I, inferred}]),
     hinted("T8.10 e: a tuple that begins with an atom is a tagged tuple; a sent message is hinted",
            "-spec f(pid(), integer()) -> ok.\nf(P, N) -> P ! {add, N}, ok.",
            [{{tuple, [3, 4]}, {t_tagged, <<"add">>, [I]}, inferred}]),
     hinted("H22: the value of a send is the message: the send that is a function's value is hinted with the message's type",
            "-spec f(pid(), integer()) -> {add, integer()}.\nf(P, N) -> P ! {add, N}.",
            [{{tuple, [3, 4]}, {t_tagged, <<"add">>, [I]}, inferred}, {{send, 2, 5}, {t_tagged, <<"add">>, [I]}, inferred}]),
     hinted("T8.10 e: a receive clause's message is typed by its pattern and its type-test guards",
            "-spec f() -> integer().\nf() -> receive {add, N} when is_integer(N) -> N end.",
            [{{var, <<"N">>}, I, inferred}, {{tuple, [0, 1]}, {t_tagged, <<"add">>, [I]}, inferred}]),
     hinted("T8.10 a: a fun has a t_fun hint; its parameters are typed by the place it is passed to",
            "-spec f(integer()) -> integer().\nf(A) -> g(fun(X) -> X + A end).\n"
            "-spec g(fun((integer()) -> integer())) -> integer().\ng(F) -> F(1).",
            [{{lambda, [5]}, {t_fun, [I], I}, inferred}, {{var, <<"X">>}, I, inferred}]),
     hinted("T8.10 e: a literal takes the type its place states (ok where ok | error is expected, [] in a list of integers)",
            "-spec f(integer()) -> {ok | error, [integer()]}.\nf(A) -> X = g(ok, []), {X, [A]}.\n"
            "-spec g(ok | error, [integer()]) -> ok | error.\ng(R, _) -> R.",
            [{{nil}, {t_list, I}, inferred}, {{var, <<"X">>}, {t_symbols, [<<"error">>, <<"ok">>]}, declared}]),
     %% --- conversions (T8.11, T8.12) and the zero guard (T8.15)
     hinted("T8.12: float * integer converts the integer (to_float)",
            "-spec f(float(), integer()) -> float().\nf(F, N) -> F * N.",
            [{{op, <<"to_float">>, [3]}, F, inferred}, {{op, <<"*">>, [2, 4]}, F, inferred}]),
     hinted("T8.11: an integer literal next to a float is sent as a float literal",
            "-spec f(float()) -> float().\nf(F) -> 1 + F.", [{{op, <<"+">>, [1, 2]}, F, inferred}], [{float, <<"1.0">>}]),
     hinted("T8.12, T8.15: integer / integer is to_float on both, under a guard that fails on a zero divisor",
            "-spec f(integer(), integer()) -> float().\nf(A, B) -> A / B.",
            [{{op, <<"to_float">>, [2]}, F, inferred}, {{op, <<"==">>, [3, 4]}, Bool, inferred},
             {{op, <<"/">>, [11, 13]}, F, inferred}, {{'cond', [8, 15]}, F, inferred}],
            [{float, <<"0.0">>}, {symbol, <<"badarith">>}, {fail, 6}, {clause, [], 5, 7}, {boolean, true}, {clause, [], 9, 14}]),
     hinted("T8.15: a divisor that is a literal other than zero needs no guard",
            "-spec f(float()) -> float().\nf(X) -> X / 2.", [{{op, <<"/">>, [1, 2]}, F, inferred}], [{float, <<"2.0">>}]),
     hinted("T8.15: an operand of / that is not a variable or a literal is evaluated once, in Erlang's order",
            "-spec f(integer()) -> float().\nf(A) -> g(A) / g(A).\n-spec g(integer()) -> float().\ng(_) -> 1.5.",
            [{{var, <<"E2s__t1">>}, F, inferred}, {{var, <<"E2s__t2">>}, F, inferred}, {{match, 3, 2}, F, inferred},
             {{match, 7, 6}, F, inferred}, {{block, [4, 8, 20]}, F, inferred}]),
     hinted("T8.11: integer < float compares the numbers: the integer is converted",
            "-spec f(integer(), float()) -> boolean().\nf(N, F) -> N < F.",
            [{{op, <<"to_float">>, [2]}, F, inferred}, {{op, <<"<">>, [3, 4]}, Bool, inferred}]),
     hinted("Appendix B: integer =:= float is false whatever the values",
            "-spec f(integer(), float()) -> boolean().\nf(N, F) -> N =:= F.", [], [{boolean, false}]),
     hinted("Appendix B: integer =/= float is true; operands with effects are still evaluated",
            "-spec f(integer()) -> boolean().\nf(N) -> g(N) =/= 1.5.\n-spec g(integer()) -> integer().\ng(N) -> N.",
            [{{block, [2, 3, 4]}, Bool, inferred}], [{boolean, true}]),
     hinted("T8.11: == between an atom literal and a value of an atom union needs no conversion, either way round",
            "-spec f(ok | error) -> boolean().\nf(R) -> ok == R andalso R == ok.",
            [{{op, <<"==">>, [1, 2]}, Bool, inferred}, {{op, <<"==">>, [4, 5]}, Bool, inferred}]),
     hinted("T8.12: trunc/1 and round/1 of a float are the operators; float/1 of an integer is to_float",
            "-spec f(float(), integer()) -> float().\nf(X, N) -> float(trunc(X) + round(X)) + float(N).",
            [{{op, <<"trunc">>, [2]}, I, inferred}, {{op, <<"round">>, [4]}, I, inferred},
             {{op, <<"to_float">>, [6]}, F, inferred}, {{op, <<"to_float">>, [8]}, F, inferred}]),
     hinted("T8.12: trunc/1 of an integer and float/1 of a float are the operand itself",
            "-spec f(float(), integer()) -> float().\nf(X, N) -> float(X) + float(trunc(N)).",
            [{{op, <<"to_float">>, [3]}, F, inferred}, {{op, <<"+">>, [2, 4]}, F, inferred}]),
     hinted("T8.15: div and rem are integer operators and get no guard",
            "-spec f(integer(), integer()) -> integer().\nf(A, B) -> A div B + A rem B.",
            [{{op, <<"div">>, [2, 3]}, I, inferred}, {{op, <<"rem">>, [5, 6]}, I, inferred}]),
     %% --- no type, so a gap that says which type is missing and why
     gapped("T8.10 a: a function with no -spec is a gap form", "f(A) -> A.",
            <<"function f/1">>, <<"function f/1 has no -spec, so its signature type cannot be stated (T8.10 a)">>),
     gapped("T8.10 a: a -spec with term() states no type", "-spec f(term()) -> ok.\nf(_) -> ok.",
            <<"function f/1">>, <<"function f/1 has a -spec whose parameter 1 states no type (term() states no type), "
                                  "so its signature type cannot be stated (T8.10 a)">>),
     gapped("T8.11: number() is not a type the codex can state", "-spec f(number()) -> number().\nf(A) -> A + 1.",
            <<"function f/1">>, <<"function f/1 has a -spec whose parameter 1 states no type (number() is integer() or "
                                  "float(), and the codex must state which (T8.11)), so its signature type cannot be "
                                  "stated (T8.10 a)">>),
     gapped("T8.10 d: an operand that is a call to a function with no -spec",
            "-spec f(integer()) -> integer().\nf(A) -> helper(A) + 1.\nhelper(A) -> A.",
            <<"operator +">>, <<"its left operand has no type: local call helper/1 has no -spec, so its result type "
                                "cannot be stated (T8.10 d) (T8.10 c)">>),
     gapped("T8.10 b: a variable bound to a call into another module",
            "-spec f(integer()) -> integer().\nf(A) -> X = other:thing(A), X.",
            <<"=">>, <<"the value that = binds has no type: call other:thing/1 goes into a module that is not in this "
                       "session and is not in the codex's table of known results (bif_type/3), so its result type "
                       "cannot be stated (T8.10 d) (T8.10 b, e)">>),
     gapped("T8.10 e: a case on a value with no type",
            "-spec f(integer()) -> integer().\nf(A) -> case other:thing(A) of 1 -> 1; _ -> 0 end.",
            <<"case">>, <<"its subject has no type: call other:thing/1 goes into a module that is not in this session "
                          "and is not in the codex's table of known results (bif_type/3), so its result type cannot be "
                          "stated (T8.10 d) (T8.10 e)">>),
     gapped("T8.10 e: a call with no type whose value is dropped",
            "-spec f(integer()) -> integer().\nf(A) -> other:thing(A), A.",
            <<"expression whose value is dropped">>,
            <<"it has no type: call other:thing/1 goes into a module that is not in this session and is not in the "
              "codex's table of known results (bif_type/3), so its result type cannot be stated (T8.10 d) (T8.10 e)">>),
     gapped("T8.10 b, e: a receive whose message has no type (Erlang's messages are untyped)",
            "-spec f() -> ok.\nf() -> receive {add, N} -> g(N) end.\n-spec g(integer()) -> ok.\ng(_) -> ok.",
            <<"receive">>, <<"the variable N would be bound without a type: a received message has no declared type in "
                             "Erlang (give each variable the clause binds a type-test guard such as is_integer(N)) "
                             "(T8.10 b)">>),
     gapped("T8.10 a: a fun whose parameters nothing types",
            "-spec f() -> pid().\nf() -> spawn(fun(X) -> X end).",
            <<"fun">>, <<"the variable X would be bound without a type: the parameters of an Erlang fun carry no type "
                         "(pass the fun where a -spec states a fun type, or give each parameter a type-test guard) "
                         "(T8.10 b)">>),
     gapped("T8.10 e: an empty list whose element type nothing states",
            "-spec f() -> ok.\nf() -> other:thing([]).",
            <<"[]">>, <<"its type cannot be stated: nothing states the element type of the empty list (T8.10 e)">>),
     gapped("T8.11: a comparison of two different types has no operator",
            "-spec f(integer(), atom()) -> boolean().\nf(A, B) -> A < B.",
            <<"operator <">>, <<"its operands have different types, integer() and atom() (T8.11): Erlang compares any "
                                "two terms, and no operator of Appendix B does">>),
     gapped("T8.14: a record with an untyped field has no type form, and nothing of that type is sent untyped",
            "-record(r, {a}).\n-spec f(#r{}) -> ok.\nf(_) -> ok.",
            <<"-record">>, <<"no type can be stated for it: field a of #r{}: field a of #r{} has no type in the -record "
                             "declaration (T8.14)">>),
     gapped("T8.15: / in a guard is a gap (a failing guard is false in Erlang, the zero guard would end the process)",
            "-spec f(float()) -> ok.\nf(A) when A / A > 1.0 -> ok;\nf(_) -> ok.",
            <<"operator >">>, <<"its left operand has no type: / in a guard: Erlang makes a failing guard false, and "
                                "the zero-divisor guard the codex writes for / (T8.15) would end the process instead "
                                "(T8.10 c)">>),
     gapped("T8.15: div in a guard is a gap for the same reason, unless the divisor is a literal other than zero",
            "-spec f(integer()) -> ok.\nf(A) when A div 2 > 1, 4 rem A > 1 -> ok;\nf(_) -> ok.",
            <<"operator >">>, <<"its left operand has no type: rem in a guard: Erlang makes a failing guard false, and "
                                "a zero divisor would end the process instead (T8.15) (T8.10 c)">>),
     gapped("T8.9: a body that does not have the -spec's type is a gap, not a false hint",
            "-spec f() -> float().\nf() -> 1.",
            <<"function body">>, <<"the body's value is integer(), which is not the -spec's result float(): no type can "
                                   "be stated for both (T8.9)">>),
     type_forms_first()].

hinted(Name, Source, Expected) -> hinted(Name, Source, Expected, []).
hinted(Name, Source, Expected, Nodes) ->
    Frames = snippet(Source),
    Got = hints(function(<<"f">>, Frames)),
    Have = [strip_at(N) || N <- function_nodes(<<"f">>, Frames)],
    Ok = sound(Frames) andalso [] =:= Expected -- Got andalso [] =:= Nodes -- Have andalso gaps(Frames) =:= [],
    Ok orelse io:format("  ~s:~n  wanted hints ~p~n  in ~p~n  wanted nodes ~p~n  in ~p~n  typing faults: ~p~n  gaps: ~p~n",
                        [Name, Expected -- Got, Got, Nodes -- Have, Have, typing_faults(Frames), gaps(Frames)]),
    {"typing: " ++ Name, Ok}.

%% The snippet must send a gap with exactly this construct and note.
gapped(Name, Source, Construct, Note) ->
    Frames = snippet(Source),
    Ok = sound(Frames) andalso lists:member({Construct, Note}, gaps(Frames)),
    Ok orelse io:format("  ~s:~n  wanted ~p~n  in ~p~n  typing faults: ~p~n", [Name, {Construct, Note}, gaps(Frames), typing_faults(Frames)]),
    {"typing: " ++ Name, Ok}.

%% T8.14, T5.3: every (:type) form of a unit comes before every other form, and a type before a type that names
%% it, whatever the order in the source.
type_forms_first() ->
    Frames = snippet("-spec f(t()) -> integer().\nf(_) -> 1.\n-type t() :: #r{} | none.\n-record(r, {a :: u()}).\n"
                     "-type u() :: integer().\n-spec g(#r{}) -> ok.\ng(_) -> ok."),
    Forms = [case B of
                 {type, #{head := #{name := N}}} -> {type, N};
                 {Kind, _} -> Kind
             end || {form, #{body := B}} <- Frames],
    Ok = sound(Frames)
        andalso Forms =:= [{type, <<"snippet_u">>}, {type, <<"snippet_r">>}, {type, <<"snippet_t">>}, function, function],
    Ok orelse io:format("  type forms first: got ~p~n", [Forms]),
    {"typing: T8.14 type forms come first, each after the types it names", Ok}.

%% The hints of a function form as [{Node without `at` | signature, Type written out, Strength}].
hints(none) -> [];
hints(#{code := #{nodes := Nodes}, types := Types, notes := #{hints := Hints}}) ->
    [{case N of -1 -> signature; _ -> strip_at(lists:nth(N + 1, Nodes)) end, type_term(T, Types), S}
     || #{node := N, type := T, strength := S} <- Hints].

%% A type table entry with its indices replaced by the entries they name.
type_term(I, Types) ->
    case lists:nth(I + 1, Types) of
        {t_tuple, Es} -> {t_tuple, [type_term(E, Types) || E <- Es]};
        {t_tagged, Tag, Es} -> {t_tagged, Tag, [type_term(E, Types) || E <- Es]};
        {t_list, E} -> {t_list, type_term(E, Types)};
        {t_union, Es} -> {t_union, [type_term(E, Types) || E <- Es]};
        {t_fun, Ps, R} -> {t_fun, [type_term(P, Types) || P <- Ps], type_term(R, Types)};
        {t_actor, M} -> {t_actor, type_term(M, Types)};
        {t_named, N, As} -> {t_named, N, [type_term(A, Types) || A <- As]};
        Leaf -> Leaf
    end.

%% Every gap sent, as {Construct, Note}.
gaps(Frames) ->
    [{C, N} || {gap_node, _, C, N} <- node_list(Frames)]
        ++ [{C, N} || {form, #{body := {gap, #{construct := C, note := N}}}} <- Frames].

%% ------------------------------------------------------------------ the typing rules, read from the frames
%%
%% typing_faults(Frames) -> [] when every function form states what contract 8.6 requires, as this test reads
%% it: it walks each form from its clauses and works out each node's STATED type by T8.9 alone (a hint, a
%% literal, a variable's binding, an operator), the way the transpiler must. It is the sender's own stand-in for
%% the transpiler's T3101 (a required type is missing), T3102 (operands of different types) and T3103 (a
%% conversion with the wrong operand, a signature that is not a t_fun of the arity).
typing_faults(Frames) ->
    lists:append([form_faults(F) || {form, #{body := {function, F}}} <- Frames]).

form_faults(#{head := #{name := Name, arity := Arity}, code := #{nodes := Nodes, clauses := Clauses}, types := Types,
              notes := #{hints := Hints}}) ->
    H = maps:from_list([{N, type_term(T, Types)} || #{node := N, type := T} <- Hints]),
    Sig = case H of
              #{-1 := {t_fun, Ps, _}} when length(Ps) =:= Arity -> [];
              _ -> [{Name, t3103, signature}]
          end,
    put(e2s_faults, []),
    put(e2s_vars, #{}),
    Ctx = {list_to_tuple(Nodes), H},
    [walk_clause(C, Ctx) || C <- Clauses],
    Sig ++ [{Name, Code, Node} || {Code, Node} <- lists:reverse(get(e2s_faults))].

fault(Code, I) -> put(e2s_faults, [{Code, I} | get(e2s_faults)]).

nd(I, {Nodes, _}) -> element(I + 1, Nodes).

walk_clause(C, Ctx) ->
    {clause, _, Patterns, Guard, Body} = nd(C, Ctx),
    [walk_pattern(P, Ctx) || P <- Patterns],
    Guard =:= -1 orelse walk(Guard, Ctx),
    walk(Body, Ctx).

%% A pattern: a (:var) with a hint is a binding with that type (T8.10 b).
walk_pattern(I, Ctx = {_, H}) ->
    case nd(I, Ctx) of
        {var, _, Name} -> case H of #{I := T} -> put(e2s_vars, (get(e2s_vars))#{Name => T}); _ -> ok end;
        {tuple, _, Es} -> [walk_pattern(E, Ctx) || E <- Es];
        {cons, _, Hd, Tl} -> walk_pattern(Hd, Ctx), walk_pattern(Tl, Ctx);
        {list, _, Es, _} -> [walk_pattern(E, Ctx) || E <- Es];
        {record, _, _, Fields, _} -> [walk_pattern(E, Ctx) || {_, E} <- Fields];
        {match, _, L, R} -> walk_pattern(L, Ctx), walk_pattern(R, Ctx);
        _ -> ok
    end.

%% The stated type of a node (T8.9): a type term, `literal` for a symbol (it takes the type its place states),
%% `whatever` for a node that may stand anywhere (fail, a gap), or none.
stated(I, Ctx = {_, H}) ->
    case {H, nd(I, Ctx)} of
        {#{I := T}, _} -> T;
        {_, {int, _, _}} -> {t_int, i64};
        {_, {float, _, _}} -> {t_float, f64};
        {_, {boolean, _, _}} -> {t_basic, boolean};
        {_, {symbol, _, _}} -> literal;
        {_, {fail, _, _}} -> whatever;
        {_, {gap_node, _, _, _}} -> whatever;
        {_, {var, _, Name}} -> maps:get(Name, get(e2s_vars), none);
        _ -> none
    end.

need(I, Rule, Ctx) ->
    case stated(I, Ctx) of
        none -> fault({t3101, Rule}, I);
        _ -> ok
    end.

walk(I, Ctx = {_, H}) ->
    case nd(I, Ctx) of
        {op, _, Op, Args} ->
            [walk(A, Ctx) || A <- Args],
            Ts = [stated(A, Ctx) || A <- Args],
            Class = op_class(Op),
            [fault({t3101, c}, A) || A <- Args, stated(A, Ctx) =:= none, Class =/= other],
            case {Class, Ts} of
                {to_float, [T]} when T =/= {t_int, i64} -> fault(t3103, I);
                {to_int, [T]} when T =/= {t_float, f64} -> fault(t3103, I);
                {two, [A, B]} when A =/= B, A =/= none, B =/= none, A =/= literal, B =/= literal, A =/= whatever,
                                   B =/= whatever -> fault(t3102, I);
                {float_only, [A, B]} when A =/= {t_float, f64}; B =/= {t_float, f64} -> fault(t3102, I);
                {int_only, [A, B]} when A =/= {t_int, i64}; B =/= {t_int, i64} -> fault(t3102, I);
                _ -> ok
            end;
        {match, _, P, V} -> walk(V, Ctx), need(V, e, Ctx), walk_pattern(P, Ctx);
        {block, _, Es} -> [begin walk(E, Ctx), need(E, e, Ctx) end || E <- lists:droplast(Es)], walk(lists:last(Es), Ctx);
        {'case', _, S, Cs} -> walk(S, Ctx), need(S, e, Ctx), [walk_clause(C, Ctx) || C <- Cs];
        {'cond', _, Cs} -> [walk_clause(C, Ctx) || C <- Cs];
        {lambda, _, Cs} ->
            case H of #{I := {t_fun, _, _}} -> ok; _ -> fault({t3101, a}, I) end,
            [walk_clause(C, Ctx) || C <- Cs];
        {'receive', _, Cs, Timeout, After} ->
            [begin
                 {clause, _, [P], _, _} = nd(C, Ctx),
                 walk_pattern(P, Ctx),
                 need(P, e, Ctx),
                 walk_clause(C, Ctx)
             end || C <- Cs],
            [walk(X, Ctx) || X <- [Timeout, After], X =/= -1];
        {send, _, To, M} -> walk(To, Ctx), walk(M, Ctx), need(M, e, Ctx);
        {record, _, _, Fields, Base} -> [walk(E, Ctx) || {_, E} <- Fields], Base =:= -1 orelse walk(Base, Ctx), need(I, e, Ctx);
        {list, _, Es, _} -> [walk(E, Ctx) || E <- Es], need(I, e, Ctx);
        {cons, _, Hd, Tl} -> walk(Hd, Ctx), walk(Tl, Ctx), need(I, e, Ctx);
        {nil, _} -> need(I, e, Ctx);
        Node ->
            [walk(C, Ctx) || C <- children(Node)]
    end.

op_class(<<"to_float">>) -> to_float;
op_class(Op) when Op =:= <<"trunc">>; Op =:= <<"round">> -> to_int;
op_class(<<"/">>) -> float_only;
op_class(Op) when Op =:= <<"div">>; Op =:= <<"rem">> -> int_only;
op_class(Op) when Op =:= <<"+">>; Op =:= <<"-">>; Op =:= <<"*">>; Op =:= <<"==">>; Op =:= <<"/=">>; Op =:= <<"<">>;
                  Op =:= <<"=<">>; Op =:= <<">">>; Op =:= <<">=">>; Op =:= <<"=:=">>; Op =:= <<"=/=">> -> two;
op_class(<<"neg">>) -> one;
op_class(_) -> other.

%% ------------------------------------------------------------------ processes: what the sender splits (T9.13a)

%% split(Name, Source, Check): the snippet's frames are sound and Check(Frames) holds. names/1 gives the sent
%% function names in order; has/3 says whether a function's nodes hold all of the given ones (without `at`).
split() ->
    Recv = "-spec f(integer()) -> integer().\nf(A) -> X = receive {a, N} when is_integer(N) -> N end, X + A.",
    [split("a receive with code after it: the code is the continuation f__k1, with the live variable and the value", Recv,
           fun(Fs) ->
                   names(Fs) =:= [<<"f">>, <<"f__k1">>]
                       andalso has(<<"f">>, Fs, [{call, <<>>, <<"f__k1">>, [4, 5]}, {'receive', [7], -1, -1}])
                       andalso has(<<"f__k1">>, Fs, [{var, <<"A">>}, {var, <<"X">>}, {op, <<"+">>, [2, 3]}])
                       andalso gaps(Fs) =:= []
           end),
     split("the continuation's signature: the types of the call's arguments, the source function's result; inferred", Recv,
           fun(Fs) ->
                   lists:member({signature, {t_fun, [{t_int, i64}, {t_int, i64}], {t_int, i64}}, inferred},
                                hints(function(<<"f__k1">>, Fs)))
                       andalso [E || #{head := #{name := <<"f__k1">>, exported := E}} <- functions(Fs)] =:= [false]
           end),
     split("the receive is the last expression of the first piece: the code before it stays before it",
           "-spec f(pid()) -> integer().\nf(P) -> P ! {hello, self()}, X = receive {a, N} when is_integer(N) -> N end, X + 1.",
           fun(Fs) ->
                   Nodes = [element(1, N) || N <- function_nodes(<<"f">>, Fs)],
                   lists:last(Nodes) =:= clause andalso lists:nth(length(Nodes) - 1, Nodes) =:= block
                       andalso [] =:= [self, send, 'receive'] -- Nodes
                       andalso [x || {'receive', _, _, _, _} <- function_nodes(<<"f__k1">>, Fs)] =:= []
           end),
     split("several receives: one continuation for each",
           "-spec f() -> integer().\nf() -> A = receive {a, N} when is_integer(N) -> N end,\n"
           "  B = receive {b, M} when is_integer(M) -> M end, A + B.",
           fun(Fs) ->
                   names(Fs) =:= [<<"f">>, <<"f__k1">>, <<"f__k2">>]
                       andalso has(<<"f__k1">>, Fs, [{call, <<>>, <<"f__k2">>, [4, 5]}])
                       andalso gaps(Fs) =:= []
           end),
     split("a value that differs from clause to clause: the continuation's parameter is their common type",
           "-spec f() -> ok | error.\nf() -> X = receive a -> ok; b -> error end, X.",
           fun(Fs) ->
                   lists:member({signature, {t_fun, [{t_symbols, [<<"error">>, <<"ok">>]}],
                                             {t_symbols, [<<"error">>, <<"ok">>]}}, inferred},
                                hints(function(<<"f__k1">>, Fs)))
           end),
     split("a variable a receive clause binds is passed on when the code after the receive uses it",
           "-spec f() -> integer().\nf() -> receive {a, N} when is_integer(N) -> ok end, N + 1.",
           fun(Fs) -> has(<<"f">>, Fs, [{call, <<>>, <<"f__k1">>, [3]}]) andalso gaps(Fs) =:= [] end),
     split("a call of a function that receives, not in tail position: a copy of it that goes on in the continuation",
           "-spec g(pid()) -> integer().\ng(P) -> P ! hello, receive {a, N} when is_integer(N) -> N end.\n"
           "-spec f(pid()) -> integer().\nf(P) -> X = g(P), X + 1.",
           fun(Fs) ->
                   names(Fs) =:= [<<"g">>, <<"f">>, <<"f__k1">>, <<"g__c1">>, <<"g__c1__k1">>]
                       andalso has(<<"f">>, Fs, [{call, <<>>, <<"g__c1">>, [1]}])
                       andalso has(<<"g__c1">>, Fs, [{call, <<>>, <<"g__c1__k1">>, []}])
                       andalso has(<<"g__c1__k1">>, Fs, [{call, <<>>, <<"f__k1">>, [3]}])
                       andalso gaps(Fs) =:= []
           end),
     split("a function that loops, called before more code: its copy calls itself, and the continuation at its end",
           "-spec g(integer()) -> integer().\ng(T) -> receive {add, N} when is_integer(N) -> g(T + N); stop -> T end.\n"
           "-spec f() -> integer().\nf() -> X = g(0), X * 2.",
           fun(Fs) ->
                   has(<<"g__c1">>, Fs, [{call, <<>>, <<"g__c1">>, [6]}, {call, <<>>, <<"f__k1">>, [10]}])
                       andalso gaps(Fs) =:= []
           end),
     split("a piece keeps only the variables its receive uses: the receive is a function of its own",
           "-spec f(integer(), integer()) -> integer().\nf(A, B) -> X = receive {a, N} when is_integer(N) -> N end,\n"
           "  Y = X + A, receive {b, M} when is_integer(M) -> M + B end.",
           fun(Fs) ->
                   names(Fs) =:= [<<"f">>, <<"f__k1">>, <<"f__k2">>]
                       andalso [A || #{head := #{name := <<"f__k2">>, arity := A}} <- functions(Fs)] =:= [1]
           end),
     split("a function with a receive in tail position only is sent as it is written",
           "-spec f(pid()) -> integer().\nf(P) -> P ! hello, receive {a, N} when is_integer(N) -> N end.",
           fun(Fs) -> names(Fs) =:= [<<"f">>] end),
     split("a receive inside an expression is this sender's gap, which says what to write",
           "-spec f() -> {ok, integer()}.\nf() -> Y = {ok, receive {a, N} when is_integer(N) -> N end}, Y.",
           fun(Fs) -> lists:member(<<"receive inside an expression">>, [C || {C, _} <- gaps(Fs)]) end),
     split("trap_exit and spawn_link: the child is the linked copy g__l, spawned unlinked with its parent, bound before the spawn",
           "-spec g(integer()) -> ok.\ng(_) -> receive stop -> ok end.\n"
           "-spec f() -> done | again.\nf() -> process_flag(trap_exit, true), C = spawn_link(fun() -> g(1) end),\n"
           "  receive {'EXIT', C, normal} -> done; {'EXIT', C, _R} -> again end.",
           fun(Fs) ->
                   has(<<"f">>, Fs, [{self}, {var, <<"E2s_s1">>}, {match, 1, 0}, {call, <<>>, <<"g__l">>, [3, 4]},
                                     {spawn, 7, [], false}, {symbol, <<"EXIT">>}])
                       andalso has(<<"g__l">>, Fs, [{symbol, <<"EXIT">>}, {self}, {symbol, <<"normal">>}, {tuple, [4, 5, 6]},
                                                    {send, 3, 7}])
                       andalso lists:member({{tuple, [12, 13, 14]}, {t_tagged, <<"EXIT">>, [{t_actor, {t_basic, dynamic}},
                                                                                    {t_symbols, [<<"normal">>]}]}, inferred},
                                            hints(function(<<"f">>, Fs)))
                       andalso gaps(Fs) =:= []
           end),
     split("the pid of an 'EXIT' pattern that has a value already is compared in the guard",
           "-spec g() -> ok.\ng() -> ok.\n"
           "-spec f() -> done.\nf() -> process_flag(trap_exit, true), C = spawn_link(fun() -> g() end),\n"
           "  receive {'EXIT', C, normal} -> done end.",
           fun(Fs) -> has(<<"f">>, Fs, [{var, <<"E2s_x1">>}, {var, <<"C">>}, {op, <<"=:=">>, [15, 16]}]) end),
     split("exit(Atom) in a linked copy tells the parent the reason first",
           "-spec g() -> ok.\ng() -> receive stop -> ok; die -> exit(boom) end.\n"
           "-spec f() -> pid().\nf() -> process_flag(trap_exit, true), spawn_link(fun() -> g() end).",
           fun(Fs) -> [] =:= [{symbol, <<"boom">>}, {symbol, <<"normal">>}] -- [strip_at(N) || N <- function_nodes(<<"g__l">>, Fs)] end),
     split("a literal in a record pattern is a variable and an exact comparison in the guard",
           "-record(r, {a :: integer(), b :: integer()}).\n-spec f(#r{}) -> integer().\nf(#r{a = 0}) -> 0;\nf(#r{b = B}) -> B.",
           fun(Fs) ->
                   has(<<"f">>, Fs, [{var, <<"E2s_p1">>}, {record, <<"snippet_r">>, [{<<"a">>, 0}], -1}, {int, 0},
                                     {op, <<"=:=">>, [2, 3]}, {clause, [1], 4, 5}])
                       andalso gaps(Fs) =:= []
           end),
     split("io:format with a literal format is L1 calls of Silica's print builtins, then ok (T9.16)",
           "-spec f(integer(), float(), small | large) -> ok.\nf(N, F, A) -> io:format(\"n ~p, f ~p: ~p~~~n\", [N, F, A]).",
           fun(Fs) ->
                   has(<<"f">>, Fs, [{text, <<"n ">>}, {sl_call, <<>>, <<"print">>, [3]}, {sl_call, <<>>, <<"print_int64">>, [5]},
                                     {text, <<", f ">>}, {sl_call, <<>>, <<"print_float64">>, [9]}, {text, <<": ">>},
                                     {sl_call, <<>>, <<"atom_name">>, [13]}, {sl_call, <<>>, <<"print">>, [14]},
                                     {text, <<"~\n">>}, {symbol, <<"ok">>}])
                       andalso lists:member({{sl_call, <<>>, <<"atom_name">>, [13]}, {t_basic, text}, inferred},
                                            hints(function(<<"f">>, Fs)))
                       andalso gaps(Fs) =:= []
           end),
     split("io:format: an argument that is a call is evaluated before anything is printed",
           "-spec g() -> integer().\ng() -> 1.\n-spec f() -> ok.\nf() -> io:format(\"a ~p~n\", [g()]).",
           fun(Fs) ->
                   Kinds = [element(1, N) || N <- function_nodes(<<"f">>, Fs)],
                   lists:sublist(Kinds, 4) =:= [call, var, match, text] andalso gaps(Fs) =:= []
           end),
     split("io:format with a control sequence that is not lowered is a gap that names it",
           "-spec f(integer()) -> ok.\nf(N) -> io:format(\"~10.2f~n\", [N]).",
           fun(Fs) -> [C || {C, _} <- gaps(Fs)] =:= [<<"io:format">>] end),
     split_runs()].

%% The functions e2s_split makes are Erlang: compiled in place of the module, examples/actors.erl must print and
%% return what the module itself does. (This checks the rewriting, not the transpiler.)
split_runs() ->
    File = "examples/actors.erl",
    {ok, Forms} = epp:parse_file(File, [{location, {1, 1}}]),
    {Split, _Gen} = e2s_split:forms(Forms),
    Run = fun(Fs) ->
                  Exports = [{N, A} || {function, _, N, A, _} <- Fs],
                  Keep = [F || F <- Fs, not (element(1, F) =:= attribute andalso lists:member(element(3, F), [export, spec]))],
                  All = lists:flatmap(fun({attribute, _, module, _} = M) -> [M, {attribute, 1, export, Exports}];
                                         (F) -> [F]
                                      end, Keep),
                  {ok, Mod, Bin} = compile:forms(All, [nowarn_unused_vars]),
                  {module, Mod} = code:load_binary(Mod, File, Bin),
                  captured(fun() -> Mod:main() end)
          end,
    Original = Run(Forms),
    Ok = Original =:= Run(Split) andalso element(1, Original) =:= {restarts, 0},
    Ok orelse io:format("  split, run as Erlang: the module gives ~p~n  its split forms give ~p~n", [Original, Run(Split)]),
    {"split: the split forms of examples/actors.erl, compiled as Erlang, print and return what the module does", Ok}.

%% {the value of Fun, what it and the processes it started wrote to standard output}, or timeout after 5 s.
captured(Fun) ->
    Me = self(),
    Collector = spawn(fun() -> collect(Me, []) end),
    Runner = spawn(fun() -> group_leader(Collector, self()), Me ! {value, Fun()} end),
    receive
        {value, V} ->
            Collector ! {done, self()},
            receive {output, Out} -> {V, unicode:characters_to_binary(Out)} end
    after 5000 -> exit(Runner, kill), timeout
    end.

collect(Owner, Acc) ->
    receive
        {io_request, From, ReplyAs, Request} ->
            From ! {io_reply, ReplyAs, ok},
            collect(Owner, [Acc, written(Request)]);
        {done, Owner} -> Owner ! {output, Acc}
    end.

written({put_chars, _, Chars}) -> Chars;
written({put_chars, _, M, F, A}) -> apply(M, F, A);
written({requests, Requests}) -> [written(R) || R <- Requests];
written(_) -> [].

split(Name, Source, Check) ->
    Frames = snippet(Source),
    Ok = sound(Frames) andalso Check(Frames),
    Ok orelse io:format("  ~s:~n  functions ~p~n  ~p~n  gaps ~p~n  typing faults: ~p~n",
                        [Name, names(Frames), [{N, [strip_at(X) || X <- function_nodes(N, Frames)], hints(function(N, Frames))} || N <- names(Frames)],
                         gaps(Frames), typing_faults(Frames)]),
    {"split: " ++ Name, Ok}.

functions(Frames) -> [F || {form, #{body := {function, F}}} <- Frames].

names(Frames) -> [N || #{head := #{name := N}} <- functions(Frames)].

has(Name, Frames, Nodes) -> [] =:= Nodes -- [strip_at(N) || N <- function_nodes(Name, Frames)].

%% ------------------------------------------------------------------ OTP's supervisor behaviour (T9.14b)

%% sup(Name, Source, Check): as split/3. sup_source/3 writes a supervisor module: its init/1 body, the body of
%% the child's start function start_w/1, and the start in go/0.
supervisor() ->
    Map = "{ok, {#{strategy => one_for_one}, [#{id => w, start => {snippet, start_w, [7]}, restart => transient}]}}",
    Plain = sup_source(Map, "{ok, spawn_link(snippet, loop, [Start])}", "{ok, _} = supervisor:start_link({local, s}, snippet, [])"),
    Override = fun(Fs) -> [{N, lists:sort(Ps)} || #{notes := #{overrides := Os}} <- [function(<<"go">>, Fs)],
                                                  #{node := N, requirement := a4_4, choice := chosen, detail := #{params := Ps}} <- Os]
               end,
    [sup("a supervisor start is its static child: a (:register) under the child's id of an unlinked (:spawn) with the "
         "literal arguments of the child specification", Plain,
         fun(Fs) ->
                 has(<<"go">>, Fs, [{fun_ref, <<"snippet">>, <<"loop">>, 1}, {int, 7}, {spawn, 0, [1], false},
                                    {register, <<"w">>, 2}])
                     andalso gaps(Fs) =:= []
         end),
     sup("the child's restart and the supervisor's strategy, as init/1 writes them, are an A4.4 override on the (:spawn) (T7.6)", Plain,
         fun(Fs) -> Override(Fs) =:= [{2, [{<<"restart">>, <<"transient">>}, {<<"strategy">>, <<"one_for_one">>}]}] end),
     sup("init/1 and the child's start function are not sent: what they say is in the static child; -behaviour is no gap", Plain,
         fun(Fs) -> names(Fs) =:= [<<"go">>, <<"specs">>, <<"loop">>] end),
     sup("the child is named as its start function registers it; what init/1 does not write has OTP's default "
         "(restart permanent); flags and specification as tuples",
         sup_source("{ok, {{one_for_all, 1, 5}, [{w, {snippet, start_w, [7]}, permanent, 5000, worker, [snippet]}]}}",
                    "Pid = spawn_link(fun() -> loop(Start) end), true = register(keeper, Pid), {ok, Pid}",
                    "{ok, _Sup} = supervisor:start_link(snippet, [])"),
         fun(Fs) ->
                 has(<<"go">>, Fs, [{register, <<"keeper">>, 2}])
                     andalso Override(Fs) =:= [{2, [{<<"restart">>, <<"permanent">>}, {<<"strategy">>, <<"one_for_all">>}]}]
                     andalso gaps(Fs) =:= []
         end),
     sup("a default restart: a child specification without `restart` is permanent",
         sup_source("{ok, {#{}, [#{id => w, start => {snippet, start_w, [7]}}]}}", "{ok, spawn_link(snippet, loop, [Start])}",
                    "{ok, _} = supervisor:start_link({local, s}, snippet, [])"),
         fun(Fs) -> Override(Fs) =:= [{2, [{<<"restart">>, <<"permanent">>}, {<<"strategy">>, <<"one_for_one">>}]}] end),
     sup("an init/1 that calls a function is not read: the start is a gap that says what a supervisor must look like",
         sup_source("{ok, {#{}, specs()}}", "{ok, spawn_link(snippet, loop, [Start])}",
                    "{ok, _} = supervisor:start_link({local, s}, snippet, [])"),
         fun(Fs) ->
                 [N || {_, N} <- gaps(Fs), binary:match(N, <<"e2s_sup could not read this one">>) =/= nomatch] =/= []
                     andalso [x || {register, _, _, _} <- node_list(Fs)] =:= []
         end),
     sup("a start whose value is used is not read (the supervisor's own pid has no node): a gap",
         sup_source(Map, "{ok, spawn_link(snippet, loop, [Start])}", "{ok, Sup} = supervisor:start_link({local, s}, snippet, []), is_pid(Sup)"),
         fun(Fs) -> [N || {_, N} <- gaps(Fs), binary:match(N, <<"e2s_sup could not read this one">>) =/= nomatch] =/= [] end),
     {"sup: e2s_sup:read/2 answers the children of examples/demo.erl",
      begin
          {ok, Forms} = epp:parse_file("examples/demo.erl", [{location, {1, 1}}]),
          case e2s_sup:read(Forms, {{atom, 1, demo}, {nil, 1}}) of
              {ok, [#{name := tally, restart := transient, strategy := one_for_one, function := counter,
                      args := [{integer, _, 0}], start_function := {start_tally, 1}}]} -> true;
              _ -> false
          end
      end}].

sup_source(Init, StartBody, Start) ->
    "-behaviour(supervisor).\n-spec go() -> ok.\ngo() -> " ++ Start ++ ", ok.\n"
    "init([]) -> " ++ Init ++ ".\n-spec specs() -> [integer()].\nspecs() -> [].\n"
    "start_w(Start) -> " ++ StartBody ++ ".\n"
    "-spec loop(integer()) -> integer().\nloop(N) -> receive {add, M} when is_integer(M) -> loop(N + M); stop -> N end.".

sup(Name, Source, Check) ->
    {"split: " ++ Rest, Ok} = split(Name, Source, Check),
    {"sup: " ++ Rest, Ok}.

%% ------------------------------------------------------------------ names (README, "Names")

names() ->
    Frames = snippet("-record(my_rec, {'a-b' :: integer()}).\n-spec 'is-ok?'(#my_rec{}) -> ok.\n'is-ok?'(R) -> R#my_rec.'a-b', ok."),
    Awkward = [<<"valid?">>, <<"valid__q">>, <<"valid_q">>, <<"a_?">>, <<"a__b">>, <<"_">>, <<"__">>, <<"___">>, <<"+">>,
               <<"hello world">>, <<"1abc">>, <<>>, <<"x_">>, <<"é"/utf8>>, <<"add">>, <<"sum_list">>, <<"is_ok">>,
               <<"fetch!">>, <<"_x">>, <<"_Reason">>, <<"a_b_c">>, <<"a__x5f_b">>, <<"__e">>, <<"__q">>, <<"__x">>,
               <<"x__2">>, <<"x_2">>, <<"9">>, <<"99lives">>, <<"a?_b">>, <<"a!_">>, <<"_?">>, <<"?_">>, <<"a-b">>,
               <<"a_-b">>, <<"a-_b">>, <<"-_">>, <<"_-">>, <<"E2s__t1">>, <<"日本"/utf8>>, <<"a.b">>, <<"A@b">>, <<"q">>,
               <<"x5f_">>, <<"__x5f_">>, <<"a_1">>, <<"a__1">>, <<"_1">>, <<"1_">>, <<"1__2">>],
    Idents = [e2s_codex:ident(N) || N <- Awkward],
    Multi = snippet("-export([main/0]).\n-spec main() -> integer().\nmain() -> one(2), main(1).\n"
                    "-spec main(integer()) -> integer().\nmain(N) -> F = fun main/1, F(N).\n"
                    "-spec one(integer()) -> pid().\none(N) -> spawn(snippet, main, [N])."),
    [{"names: N1 silica_unit is the prefix and the module in snake_case",
      e2s_codex:unit_ident(<<"myApp.HTTPServer">>) =:= <<"my_app_http_server">>
      andalso [] =/= [x || {unit_begin, #{unit_name := <<"snippet">>, silica_unit := <<"erl_snippet">>}} <- Frames]},
     {"names: N3 a record's type is <module>_<record>, in the type form and in t_named",
      [] =/= [x || {form, #{body := {type, #{head := #{name := <<"snippet_my_rec">>}}}}} <- Frames]
      andalso [] =/= [x || {form, #{body := {function, #{types := Ts}}}} <- Frames, {t_named, <<"snippet_my_rec">>, []} <- Ts]},
     {"names: N4 ordinary names are unchanged",
      [e2s_codex:ident(N) || N <- [<<"add">>, <<"sum_list">>, <<"is_ok">>, <<"x_">>, <<"_Reason">>, <<"a_1">>]]
      =:= [<<"add">>, <<"sum_list">>, <<"is_ok">>, <<"x_">>, <<"_Reason">>, <<"a_1">>]},
     {"names: N4 the escapes are the ones the three senders agreed on",
      [e2s_codex:ident(N) || N <- [<<"valid?">>, <<"fetch!">>, <<"valid__q">>, <<"a_?">>, <<"_">>, <<"__">>, <<"+">>,
                                   <<"1abc">>, <<>>, <<"é"/utf8>>, <<"hello world">>]]
      =:= [<<"valid__q">>, <<"fetch__b">>, <<"valid__x5f___x5f_q">>, <<"a__x5f___q">>, <<"_">>, <<"__x5f___x5f_">>,
           <<"__x2b_">>, <<"__x31_abc">>, <<"__e">>, <<"__xe9_">>, <<"hello__x20_world">>]},
     {"names: N4 decode(ident(S)) == S on " ++ integer_to_list(length(Awkward)) ++ " awkward names",
      [decode(I) || I <- Idents] =:= Awkward},
     {"names: N4 ident is injective and gives [A-Za-z0-9_] not starting with a digit",
      length(lists:usort(Idents)) =:= length(lists:usort(Awkward))
      andalso lists:all(fun(I) -> re:run(I, "^[A-Za-z_][A-Za-z0-9_]*$") =/= nomatch end, Idents)},
     {"names: N4 __ before a digit never comes out of ident (the arity suffix is free)",
      lists:all(fun(I) -> re:run(I, "__[0-9]") =:= nomatch end, Idents)},
     {"names: N4 function and field names in the frames",
      [] =/= function_nodes(<<"is__x2d_ok__q">>, Frames)
      andalso lists:member({field, <<"a__x2d_b">>},
                           [erlang:delete_element(2, strip_at(N)) || N = {field, _, _, _} <- function_nodes(<<"is__x2d_ok__q">>, Frames)])},
     {"names: N5 a symbol is the atom's own text",
      lists:member({symbol, <<"EXIT">>}, [strip_at(N) || N <- function_nodes(<<"f">>, snippet("-spec f() -> 'EXIT'.\nf() -> 'EXIT'."))])},
     {"names: N6 a name with two arities carries the arity at both: head, local call, fun_ref, spawn/3, entry",
      sound(Multi)
      andalso lists:sort([N || {form, #{body := {function, #{head := #{name := N}}}}} <- Multi])
      =:= [<<"main__0">>, <<"main__1">>, <<"one">>]
      andalso [] =:= [{call, <<>>, <<"one">>, [0]}, {call, <<>>, <<"main__1">>, [2]}] -- [strip_at(N) || N <- function_nodes(<<"main__0">>, Multi)]
      andalso lists:member({fun_ref, <<>>, <<"main__1">>, 1}, [strip_at(N) || N <- function_nodes(<<"main__1">>, Multi)])
      andalso lists:member({fun_ref, <<"snippet">>, <<"main__1">>, 1}, [strip_at(N) || N <- function_nodes(<<"one">>, Multi)])
      andalso lists:member({entry, #{function => <<"main__0">>, arity => 0}}, [B || {form, #{body := B}} <- Multi])},
     {"names: N6 the suffix decodes: name and arity come back",
      [split_arity(N) || N <- [<<"main__0">>, <<"x___2">>, <<"valid__q__12">>, <<"one">>]]
      =:= [{<<"main">>, 0}, {<<"x_">>, 2}, {<<"valid?">>, 12}, {<<"one">>, none}]}].

%% The inverse of e2s_codex:ident/1, reading left to right: __ starts an escape, everything else is itself.
decode(<<"__e">>) -> <<>>;
decode(Ident) -> unicode:characters_to_binary(dec(Ident)).

dec(<<"__q", Rest/binary>>) -> [$? | dec(Rest)];
dec(<<"__b", Rest/binary>>) -> [$! | dec(Rest)];
dec(<<"__x", Rest/binary>>) ->
    [Hex, After] = binary:split(Rest, <<"_">>),
    [binary_to_integer(Hex, 16) | dec(After)];
dec(<<C/utf8, Rest/binary>>) -> [C | dec(Rest)];
dec(<<>>) -> [].

%% A sent function name back to the source name and, when the name has several arities, the arity.
split_arity(Name) ->
    case re:run(Name, "^(.*)__([0-9]+)$", [{capture, all_but_first, binary}]) of
        {match, [Base, Arity]} -> {decode(Base), binary_to_integer(Arity)};
        nomatch -> {decode(Name), none}
    end.

%% ------------------------------------------------------------------ examples/demo.erl

demo() ->
    Demo = "examples/demo.erl",
    Frames = e2s_codex:frames([Demo], check),
    Ops = [{Op, [stated_in(F, A) || A <- Args]}
           || {form, #{body := {function, F = #{code := #{nodes := Nodes}}}}} <- Frames, {op, _, Op, Args} <- Nodes],
    [{"demo: every frame passes check_frame", lists:all(fun(F) -> check_frame:check(F) =:= ok end, Frames)},
     {"demo: children come before parents (T9.2)", lists:all(fun post_order/1, Frames)},
     {"demo: seq counts from 0 (T5.1)", [S || {_, #{seq := S}} <- Frames] =:= lists:seq(0, length(Frames) - 2)},
     {"demo: identifiers are binaries, never atoms (T4.4)", lists:all(fun names_are_binaries/1, node_list(Frames))},
     {"demo: the example covers the subset", [] =:= missing_kinds(Frames)},
     {"demo: every type T8.10 requires is stated, no operator mixes types (T8.11), conversions fit (T8.12)",
      typing_faults(Frames) =:= []},
     {"demo: the conversions are sent: to_float, trunc, round",
      [] =:= [<<"to_float">>, <<"trunc">>, <<"round">>] -- [Op || {Op, _} <- Ops]},
     {"demo: scale/2 (float * integer * 1.5) multiplies floats only, the integer under to_float",
      [{Op, [type_of_hint(function(<<"scale">>, Frames), A) || A <- Args]} || {op, _, Op, Args} <- function_nodes(<<"scale">>, Frames)]
      =:= [{<<"to_float">>, [none]}, {<<"*">>, [none, {t_float, f64}]}, {<<"*">>, [{t_float, f64}, none]}]
      andalso lists:member({<<"to_float">>, [{t_int, i64}]}, Ops)},
     {"demo: the type forms come first (T8.14)",
      [element(1, B) || {form, #{body := B}} <- lists:sublist(Frames, 3, 2)] =:= [type, type]
      andalso [] =:= [x || {form, #{body := {type, _}}} <- lists:nthtail(4, Frames)]},
     {"demo: nothing is a gap (the deliberate gap examples were removed from demo.erl)",
      gap_constructs(Frames) =:= []},
     {"demo: the supervisor is sent as the static child tally of start_sup/0, running counter(0), transient, "
      "one_for_one; init/1 and start_tally/1 are not sent (T9.14b)",
      has(<<"start_sup">>, Frames, [{fun_ref, <<"demo">>, <<"counter">>, 1}, {int, 0}, {spawn, 0, [1], false},
                                    {register, <<"tally">>, 2}])
      andalso [Ps || #{notes := #{overrides := Os}} <- [function(<<"start_sup">>, Frames)], #{node := 2, detail := #{params := Ps}} <- Os]
          =:= [[{<<"restart">>, <<"transient">>}, {<<"strategy">>, <<"one_for_one">>}]]
      andalso function(<<"init">>, Frames) =:= none andalso function(<<"start_tally">>, Frames) =:= none},
     {"demo: the supervised child is talked to by its name: three (:send_named) to tally (H39)",
      [N || {send_named, _, N, _} <- node_list(Frames)] =:= [<<"tally">>, <<"tally">>, <<"tally">>]},
     demo_runs(),
     {"demo: total/1 and total/2 are sent as total__1 and total__2 (N6)",
      function(<<"total__1">>, Frames) =/= none andalso function(<<"total__2">>, Frames) =/= none
      andalso function(<<"total">>, Frames) =:= none},
     {"demo: the same source gives the same bytes", term_to_binary(Frames) =:= term_to_binary(e2s_codex:frames([Demo], check))}].

%% examples/demo.erl is an Erlang program: its supervisor starts, its static child answers by name, and stops.
demo_runs() ->
    {ok, demo, Bin} = compile:file("examples/demo.erl", [binary]),
    {module, demo} = code:load_binary(demo, "examples/demo.erl", Bin),
    Me = self(),
    Runner = spawn(fun() ->
                           ok = demo:start_sup(),
                           Child = whereis(tally),
                           ok = demo:tally_add(3), ok = demo:tally_add(4),
                           Total = demo:tally_total(),
                           Listed = [Id || {Id, Pid, worker, _} <- supervisor:which_children(demo_sup), Pid =:= Child],
                           ok = demo:tally_stop(),
                           Ref = monitor(process, Child),
                           receive {'DOWN', Ref, process, Child, Why} -> Me ! {ran, Total, Listed, Why} end
                   end),
    Ok = receive {ran, 7, [tally], normal} -> true; {ran, _, _, _} -> false after 5000 -> false end,
    exit(Runner, kill),
    {"demo: as Erlang, the supervisor starts its static child, which answers by its name (3 + 4 = 7) and stops normally", Ok}.

type_of_hint(#{types := Types, notes := #{hints := Hints}}, Node) ->
    case [T || #{node := N, type := T} <- Hints, N =:= Node] of
        [T] -> type_term(T, Types);
        [] -> none
    end.

%% The stated type of an operand, for the report only: its hint, a literal's type, else the hint of the binding
%% of the variable of that name.
stated_in(F = #{code := #{nodes := Nodes}}, I) ->
    case {type_of_hint(F, I), lists:nth(I + 1, Nodes)} of
        {none, {int, _, _}} -> {t_int, i64};
        {none, {float, _, _}} -> {t_float, f64};
        {none, {var, _, Name}} ->
            hd([T || {var, J, N} <- Nodes, N =:= Name, T <- [type_of_hint(F, J)], T =/= none] ++ [none]);
        {T, _} -> T
    end.

%% ------------------------------------------------------------------ examples/three_nodes: a node program (contract T9.17)

node_program() ->
    Hub = e2s_codex:frames(["examples/three_nodes/hub.erl"], check),
    A = e2s_codex:frames(["examples/three_nodes/edge_a.erl"], check),
    Nodes = [B || {form, #{body := B = {node, _}}} <- Hub],
    [{node, #{name := <<"hub@localhost">>, net := Net, tables := #{peers := Peers, remotes := Remotes, locals := Locals}}}] = Nodes,
    Sends = [Name || {send_named, _, Name, _} <- node_list(Hub)],
    Gaps = fun(Frames) -> [C || {form, #{body := {gap, #{construct := C}}}} <- Frames] end,
    [{"nodes: every frame of the hub and of both edges passes check_frame",
      lists:all(fun(F) -> check_frame:check(F) =:= ok end,
                Hub ++ A ++ e2s_codex:frames(["examples/three_nodes/edge_c.erl"], check))},
     {"nodes: -silica_node is one (:node) form: the hub listens for a and c, which EPMD finds (port 0)",
      length(Nodes) =:= 1 andalso [{N, R, P} || #{name := N, role := R, port := P} <- Peers]
      =:= [{<<"a@localhost">>, listen, 0}, {<<"c@localhost">>, listen, 0}]
      andalso maps:get(epmd_port, Net) =:= 4369},
     {"nodes: a registered name and its fields cross as a tag and field types",
      [{N, T, F} || #{name := N, tag := T, fields := F} <- Locals] =:= [{<<"hub_in">>, <<"request">>, [<<"atom">>, <<"int64">>]}]
      andalso [{N, Pe, T} || #{name := N, peer := Pe, tag := T} <- Remotes]
      =:= [{<<"a_inbox">>, <<"a@localhost">>, <<"reply">>}, {<<"c_inbox">>, <<"c@localhost">>, <<"reply">>}]},
     {"nodes: {Name, Node} ! Message to a declared remote is H39 (:send_named); the hub sends to a_inbox and c_inbox",
      lists:sort(Sends) =:= [<<"a_inbox">>, <<"c_inbox">>]},
     {"nodes: the edge sends one (:send_named) to hub_in, and nothing in the three programs is a gap",
      [<<"hub_in">>] =:= [Name || {send_named, _, Name, _} <- node_list(A)] andalso Gaps(Hub) =:= [] andalso Gaps(A) =:= []},
     {"nodes: a send to a node that is not declared is a gap that says so",
      begin
          Src = "-module(nn).\n-export([f/0]).\n-spec f() -> ok.\nf() -> {x, 'z@nowhere'} ! {hello, 1}, ok.\n",
          File = filename:join("ebin", "nn.erl"),
          ok = file:write_file(File, Src),
          Fs = e2s_codex:frames([File], check),
          lists:any(fun(N) -> case N of {gap_node, _, _, Note} -> binary:match(Note, <<"-silica_node">>) =/= nomatch; _ -> false end end, node_list(Fs))
      end}].

%% ------------------------------------------------------------------ examples/actors.erl

actors() ->
    Frames = e2s_codex:frames(["examples/actors.erl"], check),
    Kinds = lists:usort([element(1, N) || N <- node_list(Frames)]),
    Forms = [B || {form, #{body := B}} <- Frames],
    [{"actors: every frame passes check_frame", lists:all(fun(F) -> check_frame:check(F) =:= ok end, Frames)},
     {"actors: children come before parents (T9.2)", lists:all(fun post_order/1, Frames)},
     {"actors: every type T8.10 requires is stated, no operator mixes types (T8.11)", typing_faults(Frames) =:= []},
     {"actors: self, spawn, send, receive, fail, record, field, match, tuple, cond, text and sl_call nodes are sent",
      [] =:= [self, spawn, send, 'receive', fail, record, field, match, tuple, 'cond', text, sl_call] -- Kinds},
     {"actors: no linked spawn is sent: the supervisor's child is the linked copy counter__l (H21, T9.15)",
      lists:usort([L || {spawn, _, _, _, L} <- node_list(Frames)]) =:= [false]
      andalso function(<<"counter__l">>, Frames) =/= none},
     {"actors: main/0 is sent in pieces, each with its receive in tail position (T9.13a)",
      [N || N <- names(Frames), binary:match(N, <<"__">>) =/= nomatch]
      =:= [<<"counter__l">>, <<"main__k1">>, <<"main__k2">>, <<"ask__c1">>, <<"ask__c1__k1">>, <<"main__k3">>,
           <<"ask__c2">>, <<"ask__c2__k1">>, <<"main__k4">>]
      andalso lists:all(fun(#{code := #{nodes := Nodes, clauses := [C]}}) ->
                                %% a receive is the body of its function's one clause
                                case [I || {I, {'receive', _, _, _, _}} <- lists:zip(lists:seq(0, length(Nodes) - 1), Nodes)] of
                                    [] -> true;
                                    [R] -> element(5, lists:nth(C + 1, Nodes)) =:= R;
                                    _ -> false
                                end;
                           (_) -> true
                        end, [F || F = #{head := #{name := N}} <- functions(Frames), binary:match(N, <<"__k">>) =/= nomatch])},
     {"actors: spawn/3 carries its arguments (H21)", [] =/= [x || {spawn, _, _, [_, _], false} <- node_list(Frames)]},
     {"actors: a receive with a timeout and one without (H23)",
      lists:usort([T =:= -1 || {'receive', _, _, T, _} <- node_list(Frames)]) =:= [false, true]},
     {"actors: the record is the first form, a type form; main/0 is the entry (T8.14, T9.6)",
      [x || {type, #{head := #{name := <<"actors_tally">>}}} <- [hd(Forms)]] =:= [x]
      andalso lists:member({entry, #{function => <<"main">>, arity => 0}}, Forms)},
     {"actors: average/1 (integer / integer) converts both operands and guards the divisor (T8.12, T8.15)",
      [] =:= [{op, <<"/">>, [19, 21]}, {op, <<"to_float">>, [18]}, {op, <<"to_float">>, [20]}, {symbol, <<"badarith">>},
              {fail, 14}, {'cond', [16, 23]}] -- [strip_at(N) || N <- function_nodes(<<"average">>, Frames)]},
     {"actors: nothing is a gap", gap_constructs(Frames) =:= []},
     {"actors: every function is sent, with a declared hint on its signature",
      length([x || {function, #{notes := #{hints := [#{node := -1, strength := declared} | _]}}} <- Forms]) =:= 8
      andalso [] =:= [x || {gap, _} <- Forms]}].

%% ------------------------------------------------------------------ flow control and resume, against stand-in listeners

%% A session of 153 frames (150 functions): more than two credit windows of 64.
many_frames() ->
    File = filename:join("ebin", "many.erl"),
    ok = file:write_file(File, ["-module(many).\n-compile(export_all).\n",
                                [io_lib:format("-spec f~b(integer()) -> integer().\nf~b(A) -> A + ~b.\n", [I, I, I])
                                 || I <- lists:seq(1, 150)]]),
    e2s_codex:frames([File], transpile).

flow() ->
    Frames = [_Hello | Rest] = many_frames(),
    N = length(Rest),
    Result = #{status => ok, counts => #{units => 1, gaps => 0, rejected => 0}, session => <<"intake_1:42">>, files => 3},
    Welcome = fun(From, Credit) ->
                      {welcome, #{session => <<"intake_1:42">>, contract => 1, transpiler => <<"stand-in">>,
                                  flow => #{resume_from => From, credit => Credit, max_frame => 1048576}}}
              end,
    %% The transpiler as built (T6.3): a window of 64; after each 32 frames (:stored, n) then (:credit, 32).
    AsBuilt = fun(S) ->
                      {ok, _} = gen_tcp:recv(S, 0, 5000),
                      reply(S, Welcome(0, 64)),
                      Seqs = serve(S, 64, 0, 32, 0, []),
                      reply(S, {result, Result}),
                      Seqs
              end,
    %% A transpiler that gives 4 at a time and only when all are used. Before it gives more it listens: a frame
    %% arriving while the sender holds no credit is a breach of T6.2.
    Stingy = fun(S) ->
                     {ok, _} = gen_tcp:recv(S, 0, 5000),
                     reply(S, Welcome(0, 4)),
                     Seqs = serve(S, 4, 0, 4, 150, []),
                     reply(S, {result, Result}),
                     Seqs
             end,
    Resumed = fun(S) ->
                      {ok, Bin} = gen_tcp:recv(S, 0, 5000),
                      {hello, #{session := <<"intake_1:42">>}} = binary_to_term(Bin),
                      reply(S, Welcome(100, 64)),
                      Seqs = serve(S, 64, 0, 32, 0, []),
                      reply(S, {result, Result}),
                      Seqs
              end,
    Finished = fun(S) ->
                       {ok, _} = gen_tcp:recv(S, 0, 5000),
                       reply(S, Welcome(N, 0)),
                       reply(S, {result, Result}),
                       {error, _TimeoutOrClosed} = gen_tcp:recv(S, 0, 300),      %% nothing may be sent (T6.5a)
                       []
               end,
    Run = fun(Fs) -> fun(Port) -> e2s_sender:run("127.0.0.1", Port, Fs) end end,
    {A1, A2} = with_listener2(AsBuilt, Run(Frames)),
    {S1, S2} = with_listener2(Stingy, Run(Frames)),
    Again = [e2s_codex:hello(transpile, <<"intake_1:42">>) | Rest],
    {R1, R2} = with_listener2(Resumed, Run(Again)),
    {F1, F2} = with_listener2(Finished, Run(Again)),
    [{"flow: " ++ integer_to_list(N) ++ " frames through a window of 64: (:stored) and (:credit, 32) are read while sending (T6.3)",
      N > 128 andalso A1 =:= lists:seq(0, N - 1)
      andalso case A2 of {ok, #{result := Result, sent := N, stored := St}} -> St =:= (N div 32) * 32; _ -> false end},
     {"flow: no frame is sent without credit (T6.2)",
      S1 =:= lists:seq(0, N - 1) andalso case S2 of {ok, #{result := Result, sent := N}} -> true; _ -> false end},
     {"flow: a resumed session sends from the welcome's resume_from, with the session id in the hello (T6.5)",
      R1 =:= lists:seq(100, N - 1) andalso case R2 of {ok, #{result := Result, sent := Sent}} -> Sent =:= N - 100; _ -> false end},
     {"flow: a resumed session that had ended sends nothing and takes the result (T6.5a)",
      F1 =:= [] andalso case F2 of {ok, #{result := Result, sent := 0}} -> true; _ -> false end}].

reply(S, Term) -> ok = gen_tcp:send(S, term_to_binary(Term)).

%% Takes frames until (:end): Credit is what the sender still holds, Used how many it used since the last grant;
%% after Grant frames it sends (:stored, n) and (:credit, Grant). With Quiet > 0 it grants only when the sender's
%% credit is 0, after listening Quiet ms for a frame that must not come. Returns the seqs in arrival order.
serve(S, Credit, Used, Grant, Quiet, Seqs) ->
    {ok, Bin} = gen_tcp:recv(S, 0, 5000),
    {Tag, #{seq := Seq}} = binary_to_term(Bin),
    true = Credit > 0,
    Seqs1 = [Seq | Seqs],
    case Tag of
        'end' -> lists:reverse(Seqs1);
        _ when Used + 1 =:= Grant ->
            Quiet =:= 0 orelse ({error, timeout} = gen_tcp:recv(S, 0, Quiet)),
            reply(S, {stored, Seq + 1}),
            reply(S, {credit, Grant}),
            serve(S, Credit - 1 + Grant, 0, Grant, Quiet, Seqs1);
        _ -> serve(S, Credit - 1, Used + 1, Grant, Quiet, Seqs1)
    end.

%% Runs Client(Port) against a listener that serves one connection with Serve(Socket): {what Serve returned,
%% what Client returned}. A Serve that fails gives {{failed, Reason}, ...}.
with_listener2(Serve, Client) ->
    {ok, L} = gen_tcp:listen(0, [binary, {packet, 4}, {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(L),
    Self = self(),
    Pid = spawn(fun() ->
                        {ok, S} = gen_tcp:accept(L, 5000),
                        R = try Serve(S) catch C:E -> {failed, {C, E}} end,
                        Self ! {self(), R},
                        receive after 500 -> ok end,
                        gen_tcp:close(S)
                end),
    R2 = Client(Port),
    R1 = receive {Pid, R} -> R after 10000 -> no_answer end,
    gen_tcp:close(L),
    {R1, R2}.

%% ------------------------------------------------------------------ release (M7, R9), against a stand-in listener

release() ->
    Id = <<"intake_1:42">>,              %% a session id as the transpiler makes them (T6.5b); opaque to the sender
    [{"release: the frame is (:release, {session}) alone, and (:released, ...) is returned",
      with_listener(fun(S) ->
                            {ok, Bin} = gen_tcp:recv(S, 0, 5000),
                            {release, #{session := Session}} = binary_to_term(Bin),
                            gen_tcp:send(S, term_to_binary({released, #{session => Session, freed => true}}))
                    end,
                    fun(Port) -> e2s_sender:release("127.0.0.1", Port, Id) end)
      =:= {ok, #{session => Id, freed => true}}},
     {"release: a connection closed without an answer is an error, not a crash",
      with_listener(fun(S) -> {ok, _} = gen_tcp:recv(S, 0, 5000) end,
                    fun(Port) -> e2s_sender:release("127.0.0.1", Port, Id) end)
      =:= {error, closed_without_reply}},
     {"release: nobody listening is an error",
      element(1, e2s_sender:release("127.0.0.1", 1, Id)) =:= error}].

%% Runs Client(Port) against a listener on 127.0.0.1 that serves one connection with Serve(Socket), then closes it.
with_listener(Serve, Client) ->
    {ok, L} = gen_tcp:listen(0, [binary, {packet, 4}, {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(L),
    spawn(fun() -> {ok, S} = gen_tcp:accept(L, 5000), Serve(S), gen_tcp:close(S) end),
    R = Client(Port),
    gen_tcp:close(L),
    R.

%% ------------------------------------------------------------------ online: a transpiler in check mode

online(Port) ->
    [check_mode("demo", ["examples/demo.erl"], Port),
     check_mode("actors", ["examples/actors.erl"], Port),
     check_mode("three_nodes hub", ["examples/three_nodes/hub.erl"], Port),
     check_mode("three_nodes edge_a", ["examples/three_nodes/edge_a.erl"], Port),
     check_mode("three_nodes edge_c", ["examples/three_nodes/edge_c.erl"], Port),
     check_mode("150 functions, more than two credit windows", [filename:join("ebin", "many.erl")], Port),
     {"online: release of an unknown session answers freed = false",
      case e2s_sender:release("127.0.0.1", Port, <<"no-such-session">>) of
          {ok, #{session := <<"no-such-session">>, freed := false}} -> true;
          %% A transpiler that ends on a release connection is not this sender's failure, and it is not a pass
          %% either: it is reported apart.
          {error, closed_without_reply} -> transpiler_fault;
          Other -> io:format("  transpiler answered: ~p~n", [Other]), false
      end}].

check_mode(Name, Files, Port) ->
    _ = many_frames(),
    Frames = e2s_codex:frames(Files, check),
    Want = #{status => ok, counts => #{units => 1, gaps => length(gap_constructs(Frames)), rejected => 0}, files => 0},
    Ok = case e2s_sender:run("127.0.0.1", Port, Frames) of
             {ok, #{result := R, rejected := []}} when is_map(R) -> maps:remove(session, R) =:= Want;
             Other -> io:format("  transpiler answered: ~p~n", [Other]), false
         end,
    {"online: " ++ Name ++ ": check mode accepts every frame: result ok", Ok}.

%% ------------------------------------------------------------------ helpers

node_list(Frames) ->
    lists:append([Nodes || {form, #{body := {function, #{code := #{nodes := Nodes}}}}} <- Frames]).

%% The constructs of every gap sent, node gaps and form gaps, sorted.
gap_constructs(Frames) -> lists:sort([C || {C, _} <- gaps(Frames)]).

missing_kinds(Frames) ->
    Kinds = lists:usort([element(1, N) || N <- node_list(Frames)]),
    [int, float, bytes, symbol, boolean, nil, tuple, cons, list, record, field, var, wild, match, block, 'case',
     clause, 'cond', op, call, apply, lambda, fun_ref, self, spawn, send, 'receive', fail] -- Kinds.

post_order({form, #{body := {function, #{code := #{nodes := Nodes}}}}}) ->
    lists:all(fun({I, Node}) -> lists:all(fun(C) -> C < I end, children(Node)) end,
              lists:zip(lists:seq(0, length(Nodes) - 1), Nodes));
post_order(_) -> true.

%% Every integer or list of integers after the location is a child index in the node kinds this codex writes,
%% except the literal of (:int, ...) and the arity of (:fun_ref, ...). -1 is "absent" (T9.4).
children({int, _, _}) -> [];
children({fun_ref, _, _, _, _}) -> [];
children(Node) ->
    [_Tag, _At | Fields] = tuple_to_list(Node),
    [C || C <- lists:flatten([case F of
                                  I when is_integer(I) -> [I];
                                  L when is_list(L) -> [case E of {_, I} -> I; I -> I end || E <- L];
                                  _ -> []
                              end || F <- Fields]), C =/= -1].

names_are_binaries(Node) ->
    lists:all(fun(F) -> not is_atom(F) orelse is_boolean(F) end, tl(tuple_to_list(Node))).
