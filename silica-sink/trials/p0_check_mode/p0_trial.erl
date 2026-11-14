%% p0_trial: the P0 trial of the to-silica transpiler (app design section 9): check mode, end to end over TCP.
%% A test sender in Erlang. It speaks the contract exactly as a sender must (4-byte length + ETF, wait for the
%% welcome, respect credit) and compares what the transpiler answers with what the contract says.
%%
%% Run:  erlc -o <dir> ../../../contract/examples/add_example.erl p0_trial.erl
%%       erl -noshell -pa <dir> -s p0_trial main <port>          (a transpiler must be listening on <port>)
%% Exit status 0 when every case passes.
-module(p0_trial).
-export([main/1, session/2, raw/2, wire/1, hello/1, hello/2, unit_begin/3, unit_end/3, the_end/2]).

main([PortArg]) ->
    Port = list_to_integer(to_list(PortArg)),
    Results = [run(Port, Case) || Case <- cases()],
    Failed = [N || {N, false} <- Results],
    io:format("~p cases, ~p failed~n", [length(Results), length(Failed)]),
    halt(case Failed of [] -> 0; _ -> 1 end).

to_list(A) when is_atom(A) -> atom_to_list(A);
to_list(L) -> L.

run(Port, {Name, Fun, Want}) ->
    Got = try Fun(Port) catch C:R:St -> {crashed, C, R, St} end,
    case Got =:= Want of
        true -> io:format("ok    ~s~n", [Name]), {Name, true};
        false -> io:format("FAIL  ~s~n      want ~p~n      got  ~p~n", [Name, Want, Got]), {Name, false}
    end.

%% ------------------------------------------------------------------ the sender

%% Sends the hello, waits for the welcome, then sends Frames under credit and reads until the transpiler finishes.
%% Answers {Welcome | Refused, Replies}; credit frames are left out of Replies.
session(Port, {Hello, Frames}) ->
    {ok, S} = gen_tcp:connect("127.0.0.1", Port, [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(S, term_to_binary(Hello)),
    R = case recv(S) of
            {welcome, #{flow := #{credit := Credit}}} = W -> {W, send_all(S, Frames, Credit, [])};
            Other -> {Other, []}
        end,
    gen_tcp:close(S),
    R.

send_all(S, [], _Credit, Acc) -> finish(S, Acc);
send_all(S, Frames, 0, Acc) ->
    case recv(S) of
        {credit, N} -> send_all(S, Frames, N, Acc);
        closed -> lists:reverse([closed | Acc]);
        timeout -> lists:reverse([timeout_waiting_for_credit | Acc]);
        Other -> send_all(S, Frames, 0, [Other | Acc])
    end;
send_all(S, [F | Rest], Credit, Acc) ->
    ok = gen_tcp:send(S, term_to_binary(F)),
    send_all(S, Rest, Credit - 1, Acc).

finish(S, Acc) ->
    case recv(S) of
        {credit, _} -> finish(S, Acc);
        {result, _} = R -> lists:reverse([R | Acc]);
        closed -> lists:reverse([closed | Acc]);
        timeout -> lists:reverse([timeout | Acc]);
        Other -> finish(S, [Other | Acc])
    end.

recv(S) ->
    case gen_tcp:recv(S, 0, 3000) of
        {ok, Bin} -> binary_to_term(Bin);
        {error, closed} -> closed;
        {error, timeout} -> timeout
    end.

%% Sends raw bytes (no framing added) and answers every frame received until the transpiler closes.
raw(Port, Chunks) ->
    {ok, S} = gen_tcp:connect("127.0.0.1", Port, [binary, {packet, raw}, {active, false}]),
    [begin ok = gen_tcp:send(S, C), timer:sleep(30) end || C <- Chunks],
    R = raw_recv(S, <<>>),
    gen_tcp:close(S),
    R.

raw_recv(S, Buf) ->
    case gen_tcp:recv(S, 0, 3000) of
        {ok, Bin} -> raw_recv(S, <<Buf/binary, Bin/binary>>);
        {error, closed} -> unframe(Buf) ++ [closed];
        {error, timeout} -> unframe(Buf) ++ [timeout]
    end.

unframe(<<Len:32/big, Etf:Len/binary, Rest/binary>>) -> [binary_to_term(Etf) | unframe(Rest)];
unframe(<<>>) -> [];
unframe(Other) -> [{leftover, Other}].

wire(Term) -> B = term_to_binary(Term), <<(byte_size(B)):32/big, B/binary>>.

%% ------------------------------------------------------------------ frames

add_frames() -> add_example:frames().

hello(Mode) -> hello(Mode, fun(H) -> H end).
hello(Mode, Change) ->
    {hello, H} = hd(add_frames()),
    O = maps:get(options, H),
    {hello, Change(H#{options := O#{run := #{mode => Mode, max_frame => 1048576}}})}.

silica_hello() ->
    hello(check, fun(H) ->
        O = maps:get(options, H),
        H#{options := O#{profile := silica,
                         choices := [C || C = #{requirement := R} <- maps:get(choices, O), R =:= a3_4 orelse R =:= a6_8],
                         hints := #{proven => trust, declared => check, inferred => check}}}
    end).

unit_begin(Seq, Name, Silica) ->
    {unit_begin, #{seq => Seq, unit_name => Name, silica_unit => Silica, source => <<Name/binary, ".erl">>}}.
unit_end(Seq, Name, Forms) -> {unit_end, #{seq => Seq, unit_name => Name, forms => Forms}}.
the_end(Seq, Units) -> {'end', #{seq => Seq, units => Units}}.

%% A function form named f/0 in unit Unit with these nodes; the last node must be its clause.
form(Seq, Unit, Nodes) -> form(Seq, Unit, Nodes, [], []).
form(Seq, Unit, Nodes, Types, Hints) ->
    {form, #{seq => Seq, unit_name => Unit,
             body => {function, #{head => #{name => <<"f">>, arity => 0, exported => true, file => <<"x.erl">>},
                                  code => #{locations => [{1, 1}], nodes => Nodes, clauses => [length(Nodes) - 1]},
                                  types => Types,
                                  notes => #{hints => Hints, overrides => []}}}}}.

add_form(Seq) ->
    {form, F} = lists:nth(3, add_frames()),
    {form, F#{seq := Seq}}.

rejected(Seq, Reason, Where) -> {rejected, #{seq => Seq, reason => Reason, where => Where}}.
%% Runs a check session and answers its replies with the session id checked and taken out.
check(Port, Frames) -> check(Port, hello(check), Frames).
check(Port, Hello, Frames) ->
    case session(Port, {Hello, Frames}) of
        {{welcome, #{session := Id, contract := 1, flow := #{resume_from := 0, credit := 64, max_frame := 1048576}}},
         Replies} when is_binary(Id), byte_size(Id) > 0 ->
            [case R of
                 {result, M = #{session := Id}} -> {result, maps:remove(session, M)};
                 _ -> R
             end || R <- Replies];
        Other -> {unexpected, Other}
    end.

res(Status, Units, Gaps, Rejected) ->
    {result, #{status => Status, counts => #{units => Units, gaps => Gaps, rejected => Rejected}, files => 0}}.

refusal(Port, Hello) ->
    case session(Port, {Hello, []}) of
        {{refused, #{reason := R, detail := D}}, []} when is_binary(D) -> {refused, R};
        Other -> Other
    end.

%% ------------------------------------------------------------------ the cases: {name, fun(Port), expected}

cases() ->
    D = <<"demo">>, U = <<"erl_demo">>,
    [
     {"worked example (contract 12) in check mode is accepted: status ok (T6.11)",
      fun(P) -> check(P, tl(add_frames())) end,
      [res(ok, 1, 0, 0)]},

     {"offline: every frame of the worked example passes the Erlang binding's checker",
      fun(_) -> [check_frame:check(F) || F <- add_frames()] end,
      [ok, ok, ok, ok, ok]},

     {"two units, a gap form and a gap node are counted (T9.10)",
      fun(P) -> check(P, [unit_begin(0, D, U), add_form(1),
                          {form, #{seq => 2, unit_name => D,
                                   body => {gap, #{name => <<"g/1">>, place => #{file => <<"demo.erl">>, line => 9},
                                                   construct => <<"list comprehension">>, note => <<"out of scope">>}}}},
                          unit_end(3, D, 2),
                          unit_begin(4, <<"two">>, <<"erl_two">>),
                          form(5, <<"two">>, [{gap_node, 0, <<"map">>, <<"out of scope">>}, {clause, 0, [], -1, 0}]),
                          unit_end(6, <<"two">>, 1), the_end(7, 2)]) end,
      [res(ok, 2, 2, 0)]},

     {"a seq that is not the next expected is rejected seq_gap and uses no seq (T5.1)",
      fun(P) -> check(P, [unit_begin(0, D, U), add_form(5), add_form(1), unit_end(2, D, 1), the_end(3, 1)]) end,
      [rejected(5, seq_gap, <<".seq">>), res(failed, 1, 0, 1)]},

     {"a form with no unit open, a unit begin inside a unit, an end inside a unit: unit_order (T5.3)",
      fun(P) -> check(P, [add_form(0), unit_begin(1, D, U), unit_begin(2, <<"b">>, <<"erl_b">>),
                          {form, #{seq => 3, unit_name => <<"other">>, body => {entry, #{function => <<"f">>, arity => 0}}}},
                          the_end(4, 1), unit_end(5, <<"other">>, 0), unit_end(6, D, 0), the_end(7, 1)]) end,
      [rejected(0, unit_order, <<".unit_name">>), rejected(2, unit_order, <<".unit_name">>),
       rejected(3, unit_order, <<".unit_name">>), rejected(4, unit_order, <<>>),
       rejected(5, unit_order, <<".unit_name">>), res(failed, 1, 0, 5)]},

     {"silica_unit without the prefix, not an identifier, or repeated: bad_unit_name (T5.2)",
      fun(P) -> check(P, [unit_begin(0, D, <<"demo">>), unit_begin(1, D, <<"erl_de-mo">>), unit_begin(2, D, <<>>),
                          unit_begin(3, D, U), unit_end(4, D, 0), unit_begin(5, <<"again">>, U), the_end(6, 1)]) end,
      [rejected(0, bad_unit_name, <<".silica_unit">>), rejected(1, bad_unit_name, <<".silica_unit">>),
       rejected(2, bad_unit_name, <<".silica_unit">>), rejected(5, bad_unit_name, <<".silica_unit">>),
       res(failed, 1, 0, 4)]},

     {"a child index not below its parent, a location out of range, a clause out of range: bad_index (T9.2, T9.3)",
      fun(P) -> check(P, [unit_begin(0, D, U),
                          form(1, D, [{int, 0, 1}, {tuple, 0, [0, 1]}, {clause, 0, [], -1, 1}]),
                          form(2, D, [{int, 7, 1}, {clause, 0, [], -1, 0}]),
                          form(3, D, [{int, 0, 1}, {clause, 0, [], -1, 1}]),
                          {form, #{seq => 4, unit_name => D,
                                   body => {function, #{head => #{name => <<"f">>, arity => 0, exported => true, file => <<"x.erl">>},
                                                        code => #{locations => [], nodes => [{int, -1, 1}, {clause, -1, [], -1, 0}],
                                                                  clauses => [2]},
                                                        types => [], notes => #{hints => [], overrides => []}}}}},
                          form(5, D, [{int, 0, 1}, {clause, 0, [], -1, 0}], [{t_tuple, [0]}], []),
                          {form, #{seq => 6, unit_name => D,
                                   body => {type, #{head => #{name => <<"t">>, params => [], exported => true, file => <<"x.erl">>},
                                                    at_line => 3, types => [{t_basic, boolean}, {t_list, 0}], root => 2}}}},
                          unit_end(7, D, 6), the_end(8, 1)]) end,
      [rejected(1, bad_index, <<".body.code.nodes[1]">>), rejected(2, bad_index, <<".body.code.nodes[0]">>),
       rejected(3, bad_index, <<".body.code.nodes[1]">>), rejected(4, bad_index, <<".body.code.clauses">>),
       rejected(5, bad_index, <<".body.types[0]">>), rejected(6, bad_index, <<".body.root">>),
       res(failed, 1, 0, 6)]},

     {"a hint whose node or type index is out of range: bad_hint (contract 8.4)",
      fun(P) -> check(P, [unit_begin(0, D, U),
                          form(1, D, [{int, 0, 1}, {clause, 0, [], -1, 0}], [{t_int, i64}],
                               [#{node => 0, type => 0, strength => declared, policy => default},
                                #{node => 0, type => 1, strength => declared, policy => default}]),
                          form(2, D, [{int, 0, 1}, {clause, 0, [], -1, 0}], [{t_int, i64}],
                               [#{node => 2, type => 0, strength => proven, policy => trust}]),
                          unit_end(3, D, 2), the_end(4, 1)]) end,
      [rejected(1, bad_hint, <<".body.notes.hints[1]">>), rejected(2, bad_hint, <<".body.notes.hints[0]">>),
       res(failed, 1, 0, 2)]},

     {"a silica session: plain code accepted, a process construct rejected profile (T7.10)",
      fun(P) -> check(P, silica_hello(),
                      [unit_begin(0, D, U), add_form(1),
                       form(2, D, [{self, 0}, {int, 0, 1}, {send, 0, 0, 1}, {clause, 0, [], -1, 2}]),
                       unit_end(3, D, 2), the_end(4, 1)]) end,
      [rejected(2, profile, <<".body.code.nodes[0]">>), res(failed, 1, 0, 1)]},

     {"frames the schema's decoder rejects use their seq (R5): missing field, unknown field, unknown tag, wrong kinds",
      fun(P) -> check(P, [{unit_begin, #{seq => 0, unit_name => D, silica_unit => U}},
                          {unit_begin, #{seq => 1, unit_name => D, silica_unit => U, source => <<>>, extra => 1}},
                          {surprise_message_tag_zzz, #{seq => 2}},
                          unit_begin(3, D, U),
                          form(4, D, [{var, 0, an_atom_not_a_binary_zzz}, {clause, 0, [], -1, 0}]),
                          form(5, D, [{int, 0, <<"not an integer">>}, {clause, 0, [], -1, 0}]),
                          unit_end(6, D, 2), the_end(7, 1)]) end,
      [rejected(0, missing_field, <<>>), rejected(1, unknown_field, <<>>), rejected(2, bad_variant, <<>>),
       rejected(4, bad_tag, <<>>), rejected(5, bad_tag, <<>>), res(failed, 1, 0, 5)]},

     {"a second hello inside a session is rejected bad_variant with seq -1 and uses no seq",
      fun(P) -> check(P, [hello(check), unit_begin(0, D, U), unit_end(1, D, 0), the_end(2, 1)]) end,
      [rejected(-1, bad_variant, <<>>), res(failed, 1, 0, 1)]},

     {"credit: 200 frames sent under credit all arrive; the window is 64 and is refilled (T6.2)",
      fun(P) -> check(P, [unit_begin(0, D, U)] ++ [add_form(N) || N <- lists:seq(1, 197)]
                         ++ [unit_end(198, D, 197), the_end(199, 1)]) end,
      [res(ok, 1, 0, 0)]},

     {"refused: contract version 2 (T10.1)",
      fun(P) -> refusal(P, hello(check, fun(H) -> H#{contract := 2} end)) end, {refused, contract}},

     {"refused: a bees session with a requirement missing, and with one given twice (T7.1)",
      fun(P) -> Drop = fun(H) -> O = maps:get(options, H), H#{options := O#{choices := tl(maps:get(choices, O))}} end,
                Twice = fun(H) -> O = maps:get(options, H), Cs = maps:get(choices, O),
                                  H#{options := O#{choices := [hd(Cs) | tl(tl(Cs))] ++ [hd(Cs)]}} end,
                [refusal(P, hello(check, Drop)), refusal(P, hello(check, Twice))] end,
      [{refused, choices}, {refused, choices}]},

     {"refused: a silica session with eleven choices (T7.1), and with an advisory policy (T8.4)",
      fun(P) -> {hello, SH} = silica_hello(), O = maps:get(options, SH),
                [refusal(P, hello(check, fun(H) -> O1 = maps:get(options, H), H#{options := O1#{profile := silica}} end)),
                 refusal(P, {hello, SH#{options := O#{hints := #{proven => trust, declared => advisory, inferred => check}}}})] end,
      [{refused, choices}, {refused, bad_hello}]},

     {"refused: a check hello with a session id (T6.12), a hello that does not decode, a first frame that is no hello",
      fun(P) -> [refusal(P, hello(check, fun(H) -> H#{session := <<"s1">>} end)),
                 session(P, {{hello, #{contract => 1}}, []}),
                 refusal(P, unit_begin(0, D, U))] end,
      [{refused, bad_hello}, {{refused, #{reason => bad_hello, detail => <<"missing_field">>}}, []}, {refused, bad_hello}]},

     {"release of an unknown session answers freed false and closes (T6.13, R9)",
      fun(P) -> raw(P, [wire({release, #{session => <<"intake_0:1">>}})]) end,
      [{released, #{session => <<"intake_0:1">>, freed => false}}, closed]},

     {"abort ends the session with no result (M6)",
      fun(P) -> check(P, [unit_begin(0, D, U), {abort, #{reason => <<"gave up">>}}]) end,
      [closed]},

     {"framing: a whole session in one TCP write, and one cut into 7-byte pieces, both end ok",
      fun(P) -> All = iolist_to_binary([wire(F) || F <- [hello(check) | tl(add_frames())]]),
                Last = fun(L) -> [R || {result, _} = R <- L] =/= [] andalso
                                 maps:get(status, element(2, hd([R || {result, _} = R <- L]))) end,
                [Last(raw(P, [All])), Last(raw(P, pieces(All, 7)))] end,
      [ok, ok]},

     {"a frame longer than max_frame cannot be framed: rejected too_large, then closed (T4.3)",
      fun(P) -> [R || R <- raw(P, [wire(hello(check)), <<16#7fffffff:32/big, 1, 2, 3>>]), not (is_tuple(R) andalso element(1, R) =:= welcome)] end,
      [rejected(0, too_large, <<>>), closed]}
    ].

pieces(<<A:7/binary, Rest/binary>>, 7) -> [A | pieces(Rest, 7)];
pieces(<<>>, _) -> [];
pieces(Rest, _) -> [Rest].
