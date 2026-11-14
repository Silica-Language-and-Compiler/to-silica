%% p2_trial: the trial of the transpiler's actors (app design 3, 4): transpile mode end to end over TCP on a pool
%% of store regions. Uses the frames of ../p0_check_mode/p0_trial.erl and the contract's worked example.
%%
%% The transpiler must be freshly started, built with TS_TRIAL_FAULTS=1 and TS_REGIONS=2 (run_trials.sh does both).
%%
%% Run:  erl -noshell -pa <dir> -s p2_trial main <port> memory|backing <transpiler stdout log>
%%       erl -noshell -pa <dir> -s p2_trial after_restart <port> <file written by the backing run>
-module(p2_trial).
-export([main/1, after_restart/1]).

-define(FAULT_SESSION, <<"__ts_fault_session__">>).
-define(FAULT_ONCE, <<"__ts_fault_transpile_once__">>).
-define(FAULT_ALWAYS, <<"__ts_fault_transpile_always__">>).

%% ------------------------------------------------------------------ a sender, one step at a time

open(Port) ->
    {ok, S} = gen_tcp:connect("127.0.0.1", Port, [binary, {packet, 4}, {active, false}]),
    S.

send(S, Term) -> gen_tcp:send(S, term_to_binary(Term)).

recv(S) -> recv(S, 60000).
recv(S, Wait) ->
    case gen_tcp:recv(S, 0, Wait) of
        {ok, Bin} -> binary_to_term(Bin);
        {error, closed} -> closed;
        {error, timeout} -> timeout
    end.

%% Reads until Stop(Reply) is true; answers every reply read, credit frames left out.
until(S, Stop) -> until(S, Stop, []).
until(S, Stop, Acc) ->
    case recv(S) of
        {credit, _} -> until(S, Stop, Acc);
        R -> case Stop(R) orelse R =:= closed orelse R =:= timeout of
                 true -> lists:reverse([R | Acc]);
                 false -> until(S, Stop, [R | Acc])
             end
    end.

is_result({result, _}) -> true;
is_result(_) -> false.

hello() -> p0_trial:hello(transpile).
hello(Session) -> {hello, H} = hello(), {hello, H#{session := Session}}.

example() -> tl(add_example:frames()).

ub(Seq, Name, Silica) ->
    {unit_begin, #{seq => Seq, unit_name => Name, silica_unit => Silica, source => <<Name/binary, ".erl">>}}.
ue(Seq, Name, Forms) -> {unit_end, #{seq => Seq, unit_name => Name, forms => Forms}}.
fin(Seq, Units) -> {'end', #{seq => Seq, units => Units}}.
form(Seq, Name) ->
    {form, F} = lists:nth(3, add_example:frames()),
    {form, F#{seq := Seq, unit_name := Name}}.

%% A whole session of one unit named Name with the worked example's function in it.
unit(Name, Silica) -> [ub(0, Name, Silica), form(1, Name), ue(2, Name, 1), fin(3, 1)].

%% Opens a transpile session; answers {Socket, Id} or {refused, Reason}.
begin_session(Port, Hello) ->
    S = open(Port),
    ok = send(S, Hello),
    case recv(S) of
        {welcome, #{session := Id, flow := #{resume_from := From, credit := Credit}}} -> {S, Id, From, Credit};
        {refused, #{reason := R}} -> gen_tcp:close(S), {refused, R};
        Other -> gen_tcp:close(S), {unexpected, Other}
    end.

%% A whole session; answers {Id, Replies}.
whole(Port, Frames) ->
    case begin_session(Port, hello()) of
        {S, Id, 0, _} ->
            [ok = send(S, F) || F <- Frames],
            R = until(S, fun is_result/1),
            gen_tcp:close(S),
            {Id, R};
        Other -> {<<>>, Other}
    end.

release(Port, Id) ->
    S = open(Port),
    ok = send(S, {release, #{session => Id}}),
    R = recv(S),
    gen_tcp:close(S),
    R.

freed(Port, Id) -> release(Port, Id) =:= {released, #{session => Id, freed => true}}.

result_of(Replies) ->
    case [M || {result, M} <- Replies] of
        [#{status := St, counts := C, files := Fi}] -> {St, C, Fi};
        _ -> none
    end.

codes(Replies) -> [C || {diagnostic, #{finding := #{code := C}}} <- Replies].

region_of(Id) -> hd(binary:split(Id, <<":">>)).

log_has(Log, Text) ->
    {ok, Bin} = file:read_file(Log),
    binary:match(Bin, Text) =/= nomatch.

%% ------------------------------------------------------------------ the cases

main([PortArg, MediumArg, LogArg]) ->
    Port = list_to_integer(atom_to_list(PortArg)),
    Log = atom_to_list(LogArg),
    D = <<"demo">>, U = <<"erl_demo">>,

    %% 1. one session
    {Id1, R1} = whole(Port, example()),
    check("the worked example transpiles: (:stored, 4), result ok, one file; the id names a region (design 4.2)",
          lists:member({stored, 4}, R1) andalso result_of(R1) =:= {ok, #{units => 1, gaps => 0, rejected => 0}, 1}
          andalso binary:match(Id1, <<"intake_">>) =:= {0, 7}, {Id1, R1}),

    %% 2. it holds its region until released; a second runs in the other region AT THE SAME TIME as a third is refused
    {Sa, Ida, 0, _} = begin_session(Port, hello()),
    Third = begin_session(Port, hello()),
    check("with both regions held (one finished, one open) a third session is refused busy (T5.6)",
          Third =:= {refused, busy}, Third),
    check("releasing the finished session frees its region (T6.13)", freed(Port, Id1), Id1),

    %% 3. two sessions open at once, their frames interleaved
    {Sb, Idb, 0, _} = begin_session(Port, hello()),
    [begin ok = send(Sa, Fa), ok = send(Sb, Fb) end || {Fa, Fb} <- lists:zip(unit(D, U), unit(<<"other">>, <<"erl_other">>))],
    Ra = until(Sa, fun is_result/1), Rb = until(Sb, fun is_result/1),
    gen_tcp:close(Sa), gen_tcp:close(Sb),
    check("two sessions at once, frames interleaved, in different regions: both stored and both end ok",
          region_of(Ida) =/= region_of(Idb)
          andalso result_of(Ra) =:= {ok, #{units => 1, gaps => 0, rejected => 0}, 1}
          andalso result_of(Rb) =:= {ok, #{units => 1, gaps => 0, rejected => 0}, 1}
          andalso lists:member({stored, 4}, Ra) andalso lists:member({stored, 4}, Rb), {Ida, Ra, Idb, Rb}),
    check("both are released", freed(Port, Ida) andalso freed(Port, Idb), {Ida, Idb}),
    check("a session cannot be released twice, and an id that names no region is not freed (R9)",
          release(Port, Ida) =:= {released, #{session => Ida, freed => false}}
          andalso release(Port, <<"nobody">>) =:= {released, #{session => <<"nobody">>, freed => false}}, Ida),

    %% 4. many release connections in a row (APP_GAPS C1: the earlier build ended on the 9th)
    Many = [release(Port, <<"intake_0:", (integer_to_binary(N))/binary>>) || N <- lists:seq(1000, 1039)],
    check("40 release connections in a row are each answered freed false; the transpiler is still there",
          lists:all(fun({released, #{freed := false}}) -> true; (_) -> false end, Many)
          andalso element(1, begin_session_and_abort(Port)) =:= ok, Many),

    %% 5. resume after a dropped connection (T6.5)
    {Sc, Idc, 0, _} = begin_session(Port, hello()),
    ok = send(Sc, ub(0, D, U)), ok = send(Sc, form(1, D)),
    timer:sleep(300),
    gen_tcp:close(Sc),
    timer:sleep(500),
    Mis = begin_session(Port, begin {hello, H} = hello(Idc), {hello, H#{sender := (maps:get(sender, H))#{codex_version := <<"other">>}}} end),
    Unk = begin_session(Port, hello(<<"intake_1:999999">>)),
    Unk2 = begin_session(Port, hello(<<"not an id">>)),
    check("a resuming hello that differs is refused session_mismatch (T5.4); an unknown id unknown_session",
          Mis =:= {refused, session_mismatch} andalso Unk =:= {refused, unknown_session} andalso Unk2 =:= {refused, unknown_session},
          {Mis, Unk, Unk2}),
    Resumed = begin_session(Port, hello(Idc)),
    Rc = case Resumed of
             {Sc2, Idc, 2, 64} ->
                 %% frame 1 again (a duplicate below resume_from: dropped without reply), then the rest
                 [ok = send(Sc2, F) || F <- [form(1, D), ue(2, D, 1), fin(3, 1)]],
                 X = until(Sc2, fun is_result/1), gen_tcp:close(Sc2), X;
             _ -> Resumed
         end,
    check("a dropped session is resumed with the same id: resume_from 2, a resent frame is dropped, result ok",
          is_list(Rc) andalso Rc =:= [{stored, 4}, hd([R || R = {result, _} <- Rc])]
          andalso result_of(Rc) =:= {ok, #{units => 1, gaps => 0, rejected => 0}, 1}, {Resumed, Rc}),
    Again = begin_session(Port, hello(Idc)),
    RAgain = case Again of
                 {Sc3, Idc, 4, 0} -> Y = until(Sc3, fun is_result/1), gen_tcp:close(Sc3), Y;
                 _ -> Again
             end,
    check("resuming a finished session: resume_from 4, no credit, and the result again",
          is_list(RAgain) andalso result_of(RAgain) =:= {ok, #{units => 1, gaps => 0, rejected => 0}, 1}, {Again, RAgain}),
    check("released", freed(Port, Idc), Idc),

    %% 6. a session actor fails: its supervisor restarts it, the session stays resumable
    {Sd, Idd, 0, _} = begin_session(Port, hello()),
    ok = send(Sd, ub(0, ?FAULT_SESSION, <<"erl_fault">>)),
    Dead = recv(Sd, 2000),
    gen_tcp:close(Sd),
    timer:sleep(500),
    CheckAfter = p0_trial:session(Port, {p0_trial:hello(check), example()}),
    check("a session actor that fails answers nothing more on its connection (which stays open until the sender closes it); a check session right after ends ok",
          Dead =:= timeout andalso
          (case CheckAfter of {{welcome, _}, [{result, #{status := ok}}]} -> true; _ -> false end), {Dead, CheckAfter}),
    check("the supervisor restarted the session actor (the transpiler's log says so)",
          log_has(Log, <<"to-silica: restarted ts_session_">>), Log),
    Rd = case begin_session(Port, hello(Idd)) of
             {Sd2, Idd, 0, 64} -> [ok = send(Sd2, F) || F <- unit(D, U)], Z = until(Sd2, fun is_result/1), gen_tcp:close(Sd2), Z;
             O6 -> O6
         end,
    check("the session of the failed actor is resumed (resume_from 0: the fatal frame was not stored) and ends ok",
          is_list(Rd) andalso result_of(Rd) =:= {ok, #{units => 1, gaps => 0, rejected => 0}, 1}, Rd),
    check("released", freed(Port, Idd), Idd),

    %% 7. a transpile actor fails on the first attempt: restarted, the second attempt gives the result
    {Ide, Re} = whole(Port, unit(?FAULT_ONCE, <<"erl_once">>)),
    check("a transpile actor that fails once is restarted and the session still ends ok (design 3.4)",
          result_of(Re) =:= {ok, #{units => 1, gaps => 0, rejected => 0}, 1}
          andalso log_has(Log, <<"to-silica: restarted ts_transpile_">>), Re),
    check("released", freed(Port, Ide), Ide),
    {Idf, Rf} = whole(Port, unit(?FAULT_ALWAYS, <<"erl_always">>)),
    check("a transpile actor that fails on every attempt: the session ends failed with a T5002 diagnostic, no file",
          (case result_of(Rf) of {failed, _, 0} -> true; _ -> false end) andalso codes(Rf) =:= [<<"T5002">>], Rf),
    check("released", freed(Port, Idf), Idf),

    %% 8. counts (T5.3b, T1002), a rejected frame stored, abort
    {Idg, Rg} = whole(Port, [ub(0, D, U), form(1, D), {form, #{seq => 2, unit_name => <<"elsewhere">>, body => {entry, #{function => <<"f">>, arity => 0}}}},
                             ue(3, D, 5), fin(4, 3)]),
    check("unit_end.forms and end.units that are wrong: accepted, a T1002 diagnostic each, the result partial",
          codes(Rg) =:= [<<"T1002">>, <<"T1002">>]
          andalso result_of(Rg) =:= {partial, #{units => 1, gaps => 0, rejected => 1}, 1}
          andalso lists:member({rejected, #{seq => 2, reason => unit_order, where => <<".unit_name">>}}, Rg), Rg),
    check("released", freed(Port, Idg), Idg),
    {Sh, _Idh, 0, _} = begin_session(Port, hello()),
    ok = send(Sh, ub(0, D, U)), ok = send(Sh, {abort, #{reason => <<"gave up">>}}),
    Closed = recv(Sh, 5000), gen_tcp:close(Sh), timer:sleep(300),
    {Si, Idi, 0, _} = begin_session(Port, hello()),
    {Sj, Idj, 0, _} = begin_session(Port, hello()),
    check("an aborted session gives its region back: two new sessions get both regions (M6)",
          Closed =:= closed andalso region_of(Idi) =/= region_of(Idj), {Closed, Idi, Idj}),

    %% 9. credit follows storage (T6.3): 200 frames, (:stored, n) at every half window
    ok = send(Sj, {abort, #{reason => <<"done">>}}), gen_tcp:close(Sj),
    Frames = [ub(0, D, U)] ++ [form(N, D) || N <- lists:seq(1, 197)] ++ [ue(198, D, 197), fin(199, 1)],
    Rk = send_under_credit(Si, Frames, 64, []),
    gen_tcp:close(Si),
    Stored = [N || {stored, N} <- Rk],
    check("200 frames under credit: (:stored, n) rises to 200 and the result is ok with one file",
          Stored =/= [] andalso lists:last(Stored) =:= 200 andalso length(Stored) >= 6 andalso Stored =:= lists:usort(Stored)
          andalso result_of(Rk) =:= {ok, #{units => 1, gaps => 0, rejected => 0}, 1}, {Stored, result_of(Rk)}),
    case atom_to_list(MediumArg) of
        "backing" ->
            %% leave: Idi finished and held; a second session open with 40 frames sent, for the restart trial
            {Sm, Idm, 0, _} = begin_session(Port, hello()),
            Rm = send_some(Sm, [ub(0, D, U)] ++ [form(N, D) || N <- lists:seq(1, 39)], 64, []),
            timer:sleep(500),
            ok = file:write_file(Log ++ ".ids", term_to_binary({Idi, Idm, [N || {stored, N} <- Rm]}));
        _ ->
            check("released", freed(Port, Idi), Idi)
    end,
    halt(case get(failed) of undefined -> 0; _ -> 1 end).

%% After the transpiler was killed and started again on the same backing store (app design 4.3).
after_restart([PortArg, IdsArg]) ->
    Port = list_to_integer(atom_to_list(PortArg)),
    {ok, Bin} = file:read_file(atom_to_list(IdsArg)),
    {IdDone, IdOpen, StoredBefore} = binary_to_term(Bin),
    D = <<"demo">>,
    A = begin_session(Port, hello(IdDone)),
    Ra = case A of
             {S, IdDone, 200, 0} -> X = until(S, fun is_result/1), gen_tcp:close(S), X;
             _ -> A
         end,
    check("after a kill and a restart the finished session is still there: resumed, it answers its result",
          is_list(Ra) andalso result_of(Ra) =:= {ok, #{units => 1, gaps => 0, rejected => 0}, 1}, {A, Ra}),
    B = begin_session(Port, hello(IdOpen)),
    Rb = case B of
             {S2, IdOpen, From, 64} when From >= 32, From =< 40 ->
                 Rest = [form(N, D) || N <- lists:seq(From, 39)] ++ [ue(40, D, 39), fin(41, 1)],
                 Y = send_under_credit(S2, Rest, 64, []), gen_tcp:close(S2), Y;
             _ -> B
         end,
    check("the unfinished session is resumed from what was durable (resume_from at least the last (:stored, n) seen) and ends ok",
          is_list(Rb) andalso result_of(Rb) =:= {ok, #{units => 1, gaps => 0, rejected => 0}, 1}
          andalso (StoredBefore =:= [] orelse element(3, B) >= lists:last(StoredBefore)), {B, StoredBefore, Rb}),
    check("both are released", freed(Port, IdDone) andalso freed(Port, IdOpen), {IdDone, IdOpen}),
    halt(case get(failed) of undefined -> 0; _ -> 1 end).

begin_session_and_abort(Port) ->
    case begin_session(Port, hello()) of
        {S, _Id, 0, _} -> ok = send(S, {abort, #{reason => <<"probe">>}}), R = recv(S, 5000), gen_tcp:close(S), timer:sleep(300), {ok, R};
        Other -> {failed, Other}
    end.

%% Sends frames while it holds credit and reads replies when it has none; then reads to the result.
send_under_credit(S, [], _Credit, Acc) -> lists:reverse(Acc) ++ until(S, fun is_result/1);
send_under_credit(S, Frames, 0, Acc) ->
    case recv(S) of
        {credit, N} -> send_under_credit(S, Frames, N, Acc);
        closed -> lists:reverse([closed | Acc]);
        timeout -> lists:reverse([timeout_waiting_for_credit | Acc]);
        Other -> send_under_credit(S, Frames, 0, [Other | Acc])
    end;
send_under_credit(S, [F | Rest], Credit, Acc) ->
    ok = send(S, F),
    send_under_credit(S, Rest, Credit - 1, Acc).

%% Sends all the frames (they fit the first window) and answers what arrives in the next second.
send_some(S, Frames, _Credit, _Acc) ->
    [ok = send(S, F) || F <- Frames],
    drain(S, []).

drain(S, Acc) ->
    case recv(S, 1000) of
        timeout -> lists:reverse(Acc);
        closed -> lists:reverse([closed | Acc]);
        R -> drain(S, [R | Acc])
    end.

check(Name, true, _) -> io:format("ok    ~s~n", [Name]);
check(Name, _, Got) -> put(failed, true), io:format("FAIL  ~s~n      got ~p~n", [Name, Got]).
