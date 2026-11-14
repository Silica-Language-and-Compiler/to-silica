%% e2s: the command line of erlang-to-silica-poc.
%%
%%   erl -noshell -pa ebin -run e2s main -extra [--port N] [--mode check|transpile] [--dump] File.erl ...
%%   erl -noshell -pa ebin -run e2s main -extra [--port N] --mode transpile --resume Session File.erl ...
%%   erl -noshell -pa ebin -run e2s main -extra [--port N] --release Session
%%
%% --dump prints the frames and sends nothing. --release sends (:release, ...) for a finished transpile session
%% (contract M7, T6.13) and prints the (:released, ...) answer. --resume takes up a transpile session after a
%% dropped connection (T6.5): the same files in the same order, and the session id the first run printed.
%% A session id is the text the transpiler gave, such as intake_1:42 (T6.5b); it is passed on unchanged.
%% Exit status: 0 when the session's result is `ok`, or the release freed the session; 1 otherwise; 2 for usage.
-module(e2s).
-export([main/1, main/0]).

main() -> main(init:get_plain_arguments()).

main(Args) ->
    Opts = parse(Args, #{port => 7411, mode => check, dump => false, release => none, resume => <<>>, files => []}),
    case Opts of
        #{release := Session, port := Port} when Session =/= none ->
            halt(report_release(e2s_sender:release("127.0.0.1", Port, Session)));
        #{files := []} ->
            io:format("usage: e2s [--port N] [--mode check|transpile] [--dump] File.erl ...~n"
                      "       e2s [--port N] --mode transpile --resume Session File.erl ...~n"
                      "       e2s [--port N] --release Session~n"
                      "Session is the id a transpile session printed, for example intake_1:42~n"),
            halt(2);
        #{dump := true, files := Files, mode := Mode} ->
            [io:format("~tp.~n", [F]) || F <- e2s_codex:frames(Files, Mode)],
            halt(0);
        #{port := Port, files := Files, mode := Mode, resume := Session} ->
            Frames = e2s_codex:frames(Files, Mode, Session),
            halt(report(e2s_sender:run("127.0.0.1", Port, Frames)))
    end.

parse(["--port", P | Rest], O) -> parse(Rest, O#{port := list_to_integer(P)});
parse(["--mode", M | Rest], O) when M =:= "check"; M =:= "transpile" -> parse(Rest, O#{mode := list_to_atom(M)});
parse(["--dump" | Rest], O) -> parse(Rest, O#{dump := true});
parse(["--resume", Session | Rest], O) -> parse(Rest, O#{resume := unicode:characters_to_binary(Session)});
parse(["--release", Session | Rest], O) -> parse(Rest, O#{release := unicode:characters_to_binary(Session)});
parse([File | Rest], O = #{files := Fs}) -> parse(Rest, O#{files := Fs ++ [File]});
parse([], O) -> O.

report({ok, #{welcome := W, result := Result, rejected := Rejected, diagnostics := Diagnostics, sent := Sent}}) ->
    %% The hello is a frame too; `sent` counts the frames that use a seq (M2..M5).
    io:format("session ~s (~s): ~p frames sent~n", [maps:get(session, W), maps:get(transpiler, W), Sent + 1]),
    [io:format("rejected seq ~p: ~p ~s~n", [Seq, Reason, Where])
     || #{seq := Seq, reason := Reason, where := Where} <- Rejected],
    [io:format("~p ~s: ~s (~s:~p)~n", [Sev, Code, Msg, File, Line])
     || #{finding := #{severity := Sev, code := Code, message := Msg}, place := #{file := File, line := Line}} <- Diagnostics],
    case Result of
        #{status := Status, counts := #{units := Units, gaps := Gaps, rejected := N}, files := Files} ->
            io:format("result: ~p (units ~p, gaps ~p, rejected ~p, files ~p)~n", [Status, Units, Gaps, N, Files]),
            case Status of ok -> 0; _ -> 1 end;
        none ->
            io:format("the transpiler closed the connection without a result~n"), 1
    end;
report({refused, #{reason := Reason, detail := Detail}}) ->
    io:format("refused: ~p (~s)~n", [Reason, Detail]), 1;
report({error, Why}) ->
    io:format("error: ~p~n", [Why]), 1.

report_release({ok, #{session := Session, freed := Freed}}) ->
    io:format("released: session ~s, freed ~p~n", [Session, Freed]),
    case Freed of true -> 0; false -> 1 end;
report_release({error, closed_without_reply}) ->
    io:format("error: the transpiler closed the connection without a (:released, ...) answer~n"), 1;
report_release({error, Why}) ->
    io:format("error: ~p~n", [Why]), 1.
