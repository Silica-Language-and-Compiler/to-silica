%% check_frame (Erlang binding): validate terms or wire bytes against the Erlang binding tcp_transport_v1.erl.
%% Derived and non-normative, like the binding: the normative check is the Silica schema ../../tcp_transport_v1.silica.
%%
%% It interprets the schema's own -type definitions (read from the compiled module's debug_info), so it can never
%% disagree with the schema. It checks SHAPE only (rule T4.5 and the schema). Behaviour rules such as T5.1 (seq order)
%% and T9.2 (children before parents) are checked by the transpiler, not here.
%%
%% Build:   erlc +debug_info tcp_transport_v1.erl check_frame.erl
%% Use:     check_frame:check(Term)                      -> ok | {error, Path, Reason}   (as frame_to_transpiler())
%%          check_frame:check(Term, TypeName)            -> same, against any exported type of the schema
%%          check_frame:check_wire(Bytes)                -> ok | {error, FrameNumber, Path, Reason}
%%                                                          Bytes = concatenated <<Len:32/big, Etf:Len/binary>>
%% Path is a string such as ".body.nodes[4]" (as in the transpiler's `where`, rule R5).

-module(check_frame).
-export([check/1, check/2, check_wire/1]).

-define(SCHEMA, tcp_transport_v1).

check(Term) -> check(Term, frame_to_transpiler).

check(Term, TypeName) ->
    Types = types(),
    case maps:find(TypeName, Types) of
        {ok, Def} -> to_result(chk(Term, Def, Types, ""));
        error -> erlang:error({unknown_type, TypeName})
    end.

check_wire(Bytes) -> check_wire(Bytes, 0).

check_wire(<<>>, _N) -> ok;
check_wire(<<Len:32/big, Etf:Len/binary, Rest/binary>>, N) ->
    Term = try binary_to_term(Etf) catch error:badarg -> {'$bad_etf'} end,
    case Term of
        {'$bad_etf'} -> {error, N, "", "not a valid ETF term"};
        _ ->
            case check(Term) of
                ok -> check_wire(Rest, N + 1);
                {error, Path, Reason} -> {error, N, Path, Reason}
            end
    end;
check_wire(_, N) -> {error, N, "", "truncated frame"}.

to_result(ok) -> ok;
to_result({error, _, _} = E) -> E.

%% ------------------------------------------------------------------ schema loading

types() ->
    case get(check_frame_types) of
        undefined ->
            File = code:which(?SCHEMA),
            {ok, {_, [{debug_info, {debug_info_v1, Backend, Data}}]}} = beam_lib:chunks(File, [debug_info]),
            {ok, Forms} = Backend:debug_info(erlang_v1, ?SCHEMA, Data, []),
            T = maps:from_list([{Name, Def} || {attribute, _, type, {Name, Def, []}} <- Forms]),
            put(check_frame_types, T),
            T;
        T -> T
    end.

%% ------------------------------------------------------------------ the interpreter

chk(X, {ann_type, _, [_Var, T]}, Ts, P) -> chk(X, T, Ts, P);
chk(X, {paren_type, _, [T]}, Ts, P) -> chk(X, T, Ts, P);
chk(X, {atom, _, A}, _, P) -> expect(X =:= A, P, io_lib:format("the atom ~p", [A]));
chk(X, {integer, _, N}, _, P) -> expect(X =:= N, P, io_lib:format("the integer ~p", [N]));
chk(X, {op, _, '-', {integer, _, N}}, _, P) -> expect(X =:= -N, P, io_lib:format("the integer -~p", [N]));
chk(X, {type, _, binary, []}, _, P) -> expect(is_binary(X), P, "a binary");
chk(X, {type, _, integer, []}, _, P) -> int64(X, P, "an integer");
chk(X, {type, _, non_neg_integer, []}, _, P) -> int64(X, P, "a non-negative integer", fun(V) -> V >= 0 end);
chk(X, {type, _, pos_integer, []}, _, P) -> int64(X, P, "a positive integer", fun(V) -> V > 0 end);
chk(X, {type, _, arity, []}, _, P) -> int64(X, P, "an arity 0..255", fun(V) -> V >= 0 andalso V =< 255 end);
chk(X, {type, _, boolean, []}, _, P) -> expect(is_boolean(X), P, "true or false");
chk(X, {type, _, list, [T]}, Ts, P) ->
    case is_proper_list(X) of
        false -> err(P, "a proper list");
        true -> each(X, T, Ts, P, 0)
    end;
chk(X, {type, _, tuple, Es}, Ts, P) when is_list(Es) ->
    case is_tuple(X) andalso tuple_size(X) =:= length(Es) of
        false -> err(P, io_lib:format("a tuple of ~p elements", [length(Es)]));
        true -> elems(tuple_to_list(X), Es, Ts, P, 1)
    end;
chk(X, {type, _, map, Fields}, Ts, P) when is_list(Fields) ->
    case is_map(X) of
        false -> err(P, "a map");
        true ->
            Want = [{K, V} || {type, _, map_field_exact, [{atom, _, K}, V]} <- Fields],
            Keys = lists:sort([K || {K, _} <- Want]),
            case lists:sort(maps:keys(X)) of
                Keys -> fields(X, Want, Ts, P);
                Got ->
                    Missing = Keys -- Got,
                    Extra = Got -- Keys,
                    err(P, io_lib:format("a map with exactly the keys ~p (missing ~p, unknown ~p)",
                                         [Keys, Missing, Extra]))
            end
    end;
chk(X, {type, _, union, Alts}, Ts, P) -> union(X, Alts, Ts, P);
chk(X, {user_type, _, Name, []}, Ts, P) -> chk(X, maps:get(Name, Ts), Ts, P);
chk(X, {remote_type, _, [{atom, _, ?SCHEMA}, {atom, _, Name}, []]}, Ts, P) -> chk(X, maps:get(Name, Ts), Ts, P);
chk(_X, T, _Ts, _P) -> erlang:error({schema_construct_not_supported, T}).

int64(X, P, What) -> int64(X, P, What, fun(_) -> true end).
int64(X, P, What, Pred) ->
    expect(is_integer(X) andalso X >= -(1 bsl 63) andalso X < (1 bsl 63) andalso Pred(X), P, What).

each([], _T, _Ts, _P, _I) -> ok;
each([H | Rest], T, Ts, P, I) ->
    case chk(H, T, Ts, P ++ "[" ++ integer_to_list(I) ++ "]") of
        ok -> each(Rest, T, Ts, P, I + 1);
        E -> E
    end.

elems([], [], _Ts, _P, _I) -> ok;
elems([X | Xs], [T | Rest], Ts, P, I) ->
    case chk(X, T, Ts, P ++ "." ++ integer_to_list(I)) of
        ok -> elems(Xs, Rest, Ts, P, I + 1);
        E -> E
    end.

fields(_X, [], _Ts, _P) -> ok;
fields(X, [{K, T} | Rest], Ts, P) ->
    case chk(maps:get(K, X), T, Ts, P ++ "." ++ atom_to_list(K)) of
        ok -> fields(X, Rest, Ts, P);
        E -> E
    end.

%% A union of tagged tuples is resolved by tag, so the error points inside the matching alternative.
union(X, Alts, Ts, P) ->
    Flat = flatten_union(Alts, Ts),
    case lists:any(fun(A) -> chk(X, A, Ts, P) =:= ok end, Flat) of
        true -> ok;
        false ->
            case tagged(X, Flat) of
                {ok, Alt} -> chk(X, Alt, Ts, P);
                none -> err(P, "one of: " ++ describe(Flat))
            end
    end.

flatten_union(Alts, Ts) ->
    lists:flatmap(fun({type, _, union, As}) -> flatten_union(As, Ts);
                     ({user_type, _, N, []}) ->
                         case maps:get(N, Ts) of
                             {type, _, union, As} -> flatten_union(As, Ts);
                             D -> [D]
                         end;
                     (A) -> [A]
                  end, Alts).

tagged(X, Alts) when is_tuple(X), tuple_size(X) >= 1 ->
    Tag = element(1, X),
    case [A || {type, _, tuple, [{atom, _, T} | _]} = A <- Alts, T =:= Tag] of
        [One] -> {ok, One};
        _ -> none
    end;
tagged(_, _) -> none.

describe(Alts) ->
    string:join([desc(A) || A <- lists:sublist(Alts, 12)], ", ") ++
        case length(Alts) > 12 of true -> ", ..."; false -> "" end.

desc({atom, _, A}) -> atom_to_list(A);
desc({type, _, tuple, [{atom, _, T} | _]}) -> "{" ++ atom_to_list(T) ++ ", ...}";
desc({type, _, N, _}) -> atom_to_list(N) ++ "()";
desc({user_type, _, N, _}) -> atom_to_list(N) ++ "()";
desc(_) -> "?".

is_proper_list([]) -> true;
is_proper_list([_ | T]) -> is_proper_list(T);
is_proper_list(_) -> false.

expect(true, _P, _What) -> ok;
expect(false, P, What) -> err(P, What).

err(P, What) -> {error, P, lists:flatten(["expected ", What])}.
