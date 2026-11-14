%% p3_trial: the trial of "the sender decides every type" (contract 8.6, T8.8 to T8.15): one transpile session
%% whose functions state their types with hints, send numeric conversions as operators, name declared types and
%% build lists; and functions whose typing is missing or inconsistent, each of which must get its T31xx
%% diagnostic at its own file and line and must not be written.
%%
%% Run:  erl -noshell -pa <dir> -s p3_trial main <port> <file to write the session id to>
%% run_trials.sh then exports the session's unit, compiles it with a caller and compares what the program prints.
-module(p3_trial).
-export([main/1, frames/0]).

-define(UNIT, <<"types">>).
-define(FILE_NAME, <<"types.erl">>).

%% ------------------------------------------------------------------ forms

i64() -> {t_int, i64}.
f64() -> {t_float, f64}.

%% A function form. Every node sits at location 0 ({Line, 1}) unless its `at` is 1 ({Line, 9}).
fn(Name, Arity, Line, Nodes, Types, Hints) ->
    {function, #{head => #{name => Name, arity => Arity, exported => true, file => ?FILE_NAME},
                 code => #{locations => [{Line, 1}, {Line, 9}], nodes => Nodes, clauses => [length(Nodes) - 1]},
                 types => Types,
                 notes => #{hints => [#{node => N, type => T, strength => declared, policy => default} || {N, T} <- Hints],
                            overrides => []}}}.

type(Name, Params, Line, Types) ->
    {type, #{head => #{name => Name, params => Params, exported => true, file => ?FILE_NAME},
             at_line => Line, types => Types, root => length(Types) - 1}}.

%% {Name, what is expected of it, the form}. Expected: ok, or {Code, Line, Column}.
forms() ->
    [
     %% declared types first (contract T8.14)
     {"type types_point", ok,
      type(<<"types_point">>, [], 2, [f64(), {t_record, [{<<"x">>, 0}, {<<"y">>, 0}]}])},
     {"type types_pair(a)", ok,
      type(<<"types_pair">>, [<<"a">>], 3, [{t_var, <<"a">>}, {t_tuple, [0, 0]}])},
     {"type types_tree names itself", {<<"T4002">>, 4, 0},
      type(<<"types_tree">>, [], 4, [i64(), {t_tagged, <<"leaf">>, [0]}, {t_named, <<"types_tree">>, []},
                                     {t_tagged, <<"node">>, [2, 2]}, {t_union, [1, 3]}])},
     %% mean(A, B) -> to_float(A) / to_float(B)
     {"mean/2: to_float on each operand of /", ok,
      fn(<<"mean">>, 2, 10,
         [{var, 0, <<"A">>}, {var, 0, <<"B">>}, {var, 0, <<"A">>}, {op, 0, <<"to_float">>, [2]},
          {var, 0, <<"B">>}, {op, 0, <<"to_float">>, [4]}, {op, 1, <<"/">>, [3, 5]}, {clause, 0, [0, 1], -1, 6}],
         [i64(), f64(), {t_fun, [0, 0], 1}], [{-1, 2}])},
     %% mixed(F, N) -> F * N: no conversion
     {"mixed/2: float * integer with no conversion", {<<"T3102">>, 11, 9},
      fn(<<"mixed">>, 2, 11,
         [{var, 0, <<"F">>}, {var, 0, <<"N">>}, {var, 0, <<"F">>}, {var, 0, <<"N">>}, {op, 1, <<"*">>, [2, 3]},
          {clause, 0, [0, 1], -1, 4}],
         [i64(), f64(), {t_fun, [1, 0], 1}], [{-1, 2}])},
     %% helper(A) -> A * 2
     {"helper/1", ok,
      fn(<<"helper">>, 1, 12,
         [{var, 0, <<"A">>}, {var, 0, <<"A">>}, {int, 0, 2}, {op, 0, <<"*">>, [1, 2]}, {clause, 0, [0], -1, 3}],
         [i64(), {t_fun, [0], 0}], [{-1, 1}])},
     %% nohint(A) -> X = helper(A), X + 1: neither X nor the call is hinted
     {"nohint/1: a local binding with no stated type", {<<"T3101">>, 13, 9},
      fn(<<"nohint">>, 1, 13, bound_call(), [i64(), {t_fun, [0], 0}], [{-1, 1}])},
     %% the same with a hint on the binding
     {"hinted/1: the binding's hint states the type", ok,
      fn(<<"hinted">>, 1, 14, bound_call(), [i64(), {t_fun, [0], 0}], [{-1, 1}, {1, 0}])},
     %% callop(A) -> helper(A) + 1: the call is an operand and has no hint
     {"callop/1: a call result used as an operand with no hint", {<<"T3101">>, 15, 9},
      fn(<<"callop">>, 1, 15, call_operand(), [i64(), {t_fun, [0], 0}], [{-1, 1}])},
     {"callop2/1: the same with a hint on the call", ok,
      fn(<<"callop2">>, 1, 16, call_operand(), [i64(), {t_fun, [0], 0}], [{-1, 1}, {2, 0}])},
     %% intdiv(A, B) -> A / B on integers
     {"intdiv/2: / on integers", {<<"T3103">>, 17, 9},
      fn(<<"intdiv">>, 2, 17,
         [{var, 0, <<"A">>}, {var, 0, <<"B">>}, {var, 0, <<"A">>}, {var, 0, <<"B">>}, {op, 1, <<"/">>, [2, 3]},
          {clause, 0, [0, 1], -1, 4}],
         [i64(), f64(), {t_fun, [0, 0], 1}], [{-1, 2}])},
     {"nosig/1: no signature hint", {<<"T3101">>, 18, 1},
      fn(<<"nosig">>, 1, 18, [{var, 0, <<"A">>}, {var, 0, <<"A">>}, {clause, 0, [0], -1, 1}], [], [])},
     %% norm1(P) -> P.x + P.y with P a declared record
     {"norm1/1: a declared record type", ok,
      fn(<<"norm1">>, 1, 19,
         [{var, 0, <<"P">>}, {var, 0, <<"P">>}, {field, 0, 1, <<"x">>}, {var, 0, <<"P">>}, {field, 0, 3, <<"y">>},
          {op, 0, <<"+">>, [2, 4]}, {clause, 0, [0], -1, 5}],
         [{t_named, <<"types_point">>, []}, f64(), {t_fun, [0], 1}], [{-1, 2}])},
     %% first({X, _}) -> X with a declared generic type
     {"first/1: a declared type with an argument", ok,
      fn(<<"first">>, 1, 20,
         [{var, 0, <<"X">>}, {wild, 0}, {tuple, 0, [0, 1]}, {var, 0, <<"X">>}, {clause, 0, [2], -1, 3}],
         [i64(), {t_named, <<"types_pair">>, [0]}, {t_fun, [1], 0}], [{-1, 2}])},
     {"unknown/1: a declared type nobody declared", {<<"T3104">>, 21, 1},
      fn(<<"unknown">>, 1, 21, [{var, 0, <<"A">>}, {int, 0, 1}, {clause, 0, [0], -1, 1}],
         [{t_named, <<"types_nowhere">>, []}, i64(), {t_fun, [0], 1}], [{-1, 2}])},
     {"early/1: a declared type that is declared later", {<<"T3104">>, 22, 1},
      fn(<<"early">>, 1, 22, [{var, 0, <<"A">>}, {int, 0, 1}, {clause, 0, [0], -1, 1}],
         [{t_named, <<"types_late">>, []}, i64(), {t_fun, [0], 1}], [{-1, 2}])},
     {"type types_late", ok, type(<<"types_late">>, [], 23, [i64()])},
     {"wrongargs/1: a declared type with the wrong number of arguments", {<<"T3104">>, 24, 1},
      fn(<<"wrongargs">>, 1, 24, [{var, 0, <<"A">>}, {int, 0, 1}, {clause, 0, [0], -1, 1}],
         [{t_named, <<"types_pair">>, []}, i64(), {t_fun, [0], 1}], [{-1, 2}])},
     %% sum([]) -> 0; sum([H | T]) -> H + sum(T).  One clause with a case: the trial's fn has one clause.
     {"sum/1: a list, [] and [H | T]", ok,
      fn(<<"sum">>, 1, 25,
         [{var, 0, <<"L">>}, {var, 0, <<"L">>}, {nil, 0}, {int, 0, 0}, {clause, 0, [2], -1, 3},
          {var, 0, <<"H">>}, {var, 0, <<"T">>}, {cons, 0, 5, 6}, {var, 0, <<"H">>}, {var, 0, <<"T">>},
          {call, 0, <<>>, <<"sum">>, [9]}, {op, 0, <<"+">>, [8, 10]}, {clause, 0, [7], -1, 11},
          {'case', 0, 1, [4, 12]}, {clause, 0, [0], -1, 13}],
         [i64(), {t_list, 0}, {t_fun, [1], 0}], [{-1, 2}, {10, 0}])},
     {"three/0: a list built from elements", ok,
      fn(<<"three">>, 0, 26,
         [{int, 0, 1}, {int, 0, 2}, {int, 0, 3}, {list, 0, [0, 1], -1}, {cons, 0, 2, 3}, {clause, 0, [], -1, 4}],
         [i64(), {t_list, 0}, {t_fun, [], 1}], [{-1, 2}, {3, 1}])},
     {"rnd/1: round", ok,
      fn(<<"rnd">>, 1, 27, [{var, 0, <<"F">>}, {var, 0, <<"F">>}, {op, 0, <<"round">>, [1]}, {clause, 0, [0], -1, 2}],
         [i64(), f64(), {t_fun, [1], 0}], [{-1, 2}])},
     {"tr/1: trunc", ok,
      fn(<<"tr">>, 1, 28, [{var, 0, <<"F">>}, {var, 0, <<"F">>}, {op, 0, <<"trunc">>, [1]}, {clause, 0, [0], -1, 2}],
         [i64(), f64(), {t_fun, [1], 0}], [{-1, 2}])},
     %% safe_div(A, B) -> case B == 0.0 of true -> fail(badarith); false -> A / B end
     {"safe_div/2: the sender's own guard on a float division", ok,
      fn(<<"safe_div">>, 2, 29,
         [{var, 0, <<"A">>}, {var, 0, <<"B">>}, {var, 0, <<"B">>}, {float, 0, <<"0.0">>}, {op, 0, <<"==">>, [2, 3]},
          {boolean, 0, true}, {symbol, 0, <<"badarith">>}, {fail, 0, 6}, {clause, 0, [5], -1, 7},
          {boolean, 0, false}, {var, 0, <<"A">>}, {var, 0, <<"B">>}, {op, 0, <<"/">>, [10, 11]},
          {clause, 0, [9], -1, 12}, {'case', 0, 4, [8, 13]}, {clause, 0, [0, 1], -1, 14}],
         [f64(), {t_fun, [0, 0], 0}], [{-1, 1}])},
     {"one/0: an integer literal where a float is stated", {<<"T3103">>, 30, 9},
      fn(<<"one">>, 0, 30, [{int, 1, 1}, {clause, 0, [], -1, 0}], [f64(), {t_fun, [], 0}], [{-1, 1}])},
     {"ping/2: a process reference in the signature", ok,
      fn(<<"ping">>, 2, 31, [{var, 0, <<"P">>}, {var, 0, <<"N">>}, {var, 0, <<"N">>}, {clause, 0, [0, 1], -1, 2}],
         [i64(), {t_actor, 0}, {t_fun, [1, 0], 0}], [{-1, 2}])},
     {"wrongconv/1: to_float on a float", {<<"T3103">>, 32, 9},
      fn(<<"wrongconv">>, 1, 32, [{var, 0, <<"F">>}, {var, 0, <<"F">>}, {op, 1, <<"to_float">>, [1]}, {clause, 0, [0], -1, 2}],
         [f64(), {t_fun, [0], 0}], [{-1, 1}])},
     {"cmp/2: a comparison of an integer with a float", {<<"T3102">>, 33, 9},
      fn(<<"cmp">>, 2, 33,
         [{var, 0, <<"A">>}, {var, 0, <<"F">>}, {var, 0, <<"A">>}, {var, 0, <<"F">>}, {op, 1, <<"<">>, [2, 3]},
          {clause, 0, [0, 1], -1, 4}],
         [i64(), f64(), {t_basic, boolean}, {t_fun, [0, 1], 2}], [{-1, 3}])},
     {"cmp2/2: the same with to_float on the integer", ok,
      fn(<<"cmp2">>, 2, 34,
         [{var, 0, <<"A">>}, {var, 0, <<"F">>}, {var, 0, <<"A">>}, {op, 0, <<"to_float">>, [2]}, {var, 0, <<"F">>},
          {op, 1, <<"<">>, [3, 4]}, {clause, 0, [0, 1], -1, 5}],
         [i64(), f64(), {t_basic, boolean}, {t_fun, [0, 1], 2}], [{-1, 3}])}
    ].

%% f(A) -> X = helper(A), X + 1.   Node 1 is the binding's (:var), at location 1.
bound_call() ->
    [{var, 0, <<"A">>}, {var, 1, <<"X">>}, {var, 0, <<"A">>}, {call, 0, <<>>, <<"helper">>, [2]}, {match, 0, 1, 3},
     {var, 0, <<"X">>}, {int, 0, 1}, {op, 0, <<"+">>, [5, 6]}, {block, 0, [4, 7]}, {clause, 0, [0], -1, 8}].

%% f(A) -> helper(A) + 1.   Node 2 is the call, at location 1.
call_operand() ->
    [{var, 0, <<"A">>}, {var, 0, <<"A">>}, {call, 1, <<>>, <<"helper">>, [1]}, {int, 0, 1}, {op, 0, <<"+">>, [2, 3]},
     {clause, 0, [0], -1, 4}].

frames() ->
    Forms = forms(),
    N = length(Forms),
    [{unit_begin, #{seq => 0, unit_name => ?UNIT, silica_unit => <<"erl_types">>, source => ?FILE_NAME}}] ++
        [{form, #{seq => Seq, unit_name => ?UNIT, body => Body}} || {Seq, {_, _, Body}} <- lists:zip(lists:seq(1, N), Forms)] ++
        [{unit_end, #{seq => N + 1, unit_name => ?UNIT, forms => N}}, {'end', #{seq => N + 2, units => 1}}].

%% ------------------------------------------------------------------ the session

recv(S) ->
    case gen_tcp:recv(S, 0, 120000) of
        {ok, Bin} -> binary_to_term(Bin);
        {error, Why} -> Why
    end.

%% Sends under credit (contract T6.2) and reads to the result.
go(S, [], _Credit, Acc) -> finish(S, Acc);
go(S, Frames, 0, Acc) ->
    case recv(S) of
        {credit, N} -> go(S, Frames, N, Acc);
        Other when is_atom(Other) -> lists:reverse([Other | Acc]);
        Other -> go(S, Frames, 0, [Other | Acc])
    end;
go(S, [F | Rest], Credit, Acc) ->
    ok = gen_tcp:send(S, term_to_binary(F)),
    go(S, Rest, Credit - 1, Acc).

finish(S, Acc) ->
    case recv(S) of
        {result, _} = R -> lists:reverse([R | Acc]);
        Other when is_atom(Other) -> lists:reverse([Other | Acc]);
        Other -> finish(S, [Other | Acc])
    end.

main([PortArg, IdFile]) ->
    Port = list_to_integer(atom_to_list(PortArg)),
    {ok, S} = gen_tcp:connect("127.0.0.1", Port, [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(S, term_to_binary(p0_trial:hello(transpile))),
    {welcome, #{session := Id, flow := #{credit := Credit}}} = recv(S),
    Replies = go(S, frames(), Credit, []),
    gen_tcp:close(S),
    ok = file:write_file(atom_to_list(IdFile), Id),
    Forms = forms(),
    Diags = [D || {diagnostic, D} <- Replies],
    check("no frame is rejected", [R || {rejected, _} = R <- Replies] =:= [], Replies),
    lists:foreach(
      fun({Seq, {Name, Expect, _}}) ->
              Mine = [{C, L, Col, Sev} || #{seq := Q, finding := #{code := C, severity := Sev},
                                             place := #{line := L, column := Col}} <- Diags, Q =:= Seq],
              case Expect of
                  ok -> check(Name ++ ": written, no diagnostic", Mine =:= [], Mine);
                  {Code, Line, Column} ->
                      Sev = case Code of <<"T31", _/binary>> -> error; _ -> warning end,
                      check(lists:flatten(io_lib:format("~s: ~s at ~s:~b:~b", [Name, Code, ?FILE_NAME, Line, Column])),
                            Mine =:= [{Code, Line, Column, Sev}], Mine)
              end
      end, lists:zip(lists:seq(1, length(Forms)), Forms)),
    Files = [F || #{place := #{file := F}} <- Diags],
    check("every diagnostic names the sender's file", lists:usort(Files) =:= [?FILE_NAME], Files),
    Messages = [M || #{finding := #{message := M}} <- Diags],
    check("the missing-type diagnostics name the construct and the rule",
          lists:any(fun(M) -> binary:match(M, <<"the binding of the variable X">>) =/= nomatch andalso
                                  binary:match(M, <<"T8.10 b">>) =/= nomatch end, Messages)
          andalso lists:any(fun(M) -> binary:match(M, <<"the left operand (:call) of the operator +">>) =/= nomatch end, Messages)
          andalso lists:any(fun(M) -> binary:match(M, <<"its left operand has the type float64 and its right operand the type int64">>) =/= nomatch end, Messages),
          Messages),
    Bad = length([E || {_, E, _} <- Forms, E =/= ok]),
    Result = [R || {result, R} <- Replies],
    check("the result is partial, one file, and counts each unwritten form as a gap",
          case Result of
              [#{status := partial, files := 1, counts := #{units := 1, gaps := Bad, rejected := 0}}] -> true;
              _ -> false
          end, Result),
    case get(failed) of
        true -> halt(1);
        _ -> halt(0)
    end.

check(Name, true, _) -> io:format("ok    ~s~n", [Name]);
check(Name, _, Got) -> put(failed, true), io:format("FAIL  ~s~n      got ~p~n", [Name, Got]).
