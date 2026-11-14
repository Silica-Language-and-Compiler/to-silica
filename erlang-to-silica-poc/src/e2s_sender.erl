%% e2s_sender: the TCP sender of erlang-to-silica-poc. Speaks the to-silica TCP transport contract, version 1:
%% every frame is a 4-byte big-endian length and one ETF term (T4.1, T4.2: gen_tcp's {packet, 4} and
%% term_to_binary/1); the hello first, nothing more until the welcome (T6.1); M2..M5 only while holding credit
%% (T6.2). The replies are READ WHILE SENDING: before each frame everything the transpiler has already answered
%% is taken in ((:stored, n), (:credit, 32) every half window, rejections: T6.3, T6.11a), and when the credit is
%% used up the sender waits for more instead of sending. Then everything is read until (:result, ...) (T3.4).
%% release/3 sends M7.
-module(e2s_sender).
-export([run/3, release/3]).

-define(REPLY_TIMEOUT, 30000).

%% run(Host, Port, [Hello | Frames]) ->
%%     {ok, #{welcome := map(), result := map() | none, rejected := [map()], diagnostics := [map()],
%%            stored := integer(), sent := integer()}}
%%   | {refused, map()} | {error, term()}
%% `sent` counts the M2..M5 frames written. To resume a session (T6.5), give the same frames with the session's
%% id in the hello (e2s_codex:frames/3): the welcome's resume_from says where to go on, and the frames below it
%% are not sent again. A session whose (:end) was already stored answers resume_from = all, credit 0: nothing is
%% sent and the result is awaited (T6.5a).
run(Host, Port, [Hello | Frames]) ->
    _ = reply_atoms(),
    case gen_tcp:connect(Host, Port, [binary, {packet, 4}, {active, false}], 5000) of
        {ok, S} ->
            ok = gen_tcp:send(S, term_to_binary(Hello)),
            R = case recv(S, ?REPLY_TIMEOUT) of
                    {welcome, W = #{flow := #{credit := Credit, resume_from := From, max_frame := Max}}} ->
                        Acc = #{welcome => W, result => none, rejected => [], diagnostics => [], stored => 0, sent => 0},
                        send(S, drop_resent(Frames, From), Credit, Max, Acc);
                    {refused, Why} -> {refused, Why};
                    Other -> {error, {expected_welcome, Other}}
                end,
            gen_tcp:close(S),
            R;
        {error, Reason} -> {error, {connect, Reason}}
    end.

%% M7, T6.13: release a finished transpile session, so its storage is free for another session. A release is the
%% first and only frame of its own connection: no hello, no credit. The answer is R9, then the transpiler closes.
%% release(Host, Port, Session) -> {ok, #{session := binary(), freed := boolean()}} | {error, term()}
%% `freed` is false when the session is unknown or not finished. {error, closed_without_reply} means the
%% transpiler closed the connection (or ended) before it answered.
release(Host, Port, Session) when is_binary(Session) ->
    _ = reply_atoms(),
    case gen_tcp:connect(Host, Port, [binary, {packet, 4}, {active, false}], 5000) of
        {ok, S} ->
            ok = gen_tcp:send(S, term_to_binary({release, #{session => Session}})),
            R = case recv(S, ?REPLY_TIMEOUT) of
                    {released, Released = #{session := _, freed := _}} -> {ok, Released};
                    {error, closed} -> {error, closed_without_reply};
                    {error, _} = E -> E;
                    Other -> {error, {expected_released, Other}}
                end,
            gen_tcp:close(S),
            R;
        {error, Reason} -> {error, {connect, Reason}}
    end.

%% T6.5: on a resume, frames below resume_from need not be sent again. (A new session starts at 0.)
drop_resent(Frames, From) -> [F || F = {_, #{seq := Seq}} <- Frames, Seq >= From].

%% Before each frame: take in whatever the transpiler has sent (without waiting while there is credit; waiting
%% for it when there is none: T6.2, a frame sent without credit is rejected :no_credit).
send(S, [], _Credit, _Max, Acc) -> finish(S, Acc);
send(S, Frames = [F | Rest], Credit, Max, Acc = #{sent := Sent}) ->
    Wait = case Credit of 0 -> ?REPLY_TIMEOUT; _ -> 0 end,
    case recv(S, Wait) of
        {error, timeout} when Credit > 0 ->
            Bytes = term_to_binary(F),
            case byte_size(Bytes) =< Max of
                true ->
                    case gen_tcp:send(S, Bytes) of
                        ok -> send(S, Rest, Credit - 1, Max, Acc#{sent := Sent + 1});
                        {error, Reason} -> {error, {send, Reason}}
                    end;
                false ->                         %% T6.1: the welcome's max_frame is the limit. Give the session up.
                    _ = gen_tcp:send(S, term_to_binary({abort, #{reason => <<"a frame is larger than max_frame">>}})),
                    {error, {frame_too_large, element(1, F), byte_size(Bytes), Max}}
            end;
        {error, timeout} -> {error, {no_credit_within_ms, ?REPLY_TIMEOUT}};
        {error, _} = E -> E;
        {credit, N} -> send(S, Frames, Credit + N, Max, Acc);
        {result, R} -> {ok, done(Acc#{result := R})};      %% the session ended before everything was sent
        Reply -> send(S, Frames, Credit, Max, note(Reply, Acc))
    end.

finish(S, Acc) ->
    case recv(S, ?REPLY_TIMEOUT) of
        {result, R} -> {ok, done(Acc#{result := R})};
        {error, closed} -> {ok, done(Acc)};
        {error, _} = E -> E;
        Reply -> finish(S, note(Reply, Acc))
    end.

note({rejected, R}, Acc = #{rejected := Rs}) -> Acc#{rejected := [R | Rs]};
note({diagnostic, D}, Acc = #{diagnostics := Ds}) -> Acc#{diagnostics := [D | Ds]};
note({stored, Next}, Acc) -> Acc#{stored := Next};
note(_CreditOrProgress, Acc) -> Acc.

done(Acc = #{rejected := Rs, diagnostics := Ds}) -> Acc#{rejected := lists:reverse(Rs), diagnostics := lists:reverse(Ds)}.

recv(S, Timeout) ->
    case gen_tcp:recv(S, 0, Timeout) of
        {ok, Bin} -> binary_to_term(Bin, [safe]);
        {error, Reason} -> {error, Reason}
    end.

%% Replies are decoded with [safe], which refuses atoms this node has not seen. These are the atoms the contract
%% lets the transpiler send (5.3, 5.4, 6.4): naming them here makes them known once this module is loaded.
reply_atoms() ->
    [welcome, refused, credit, stored, rejected, progress, diagnostic, result, released,
     session, contract, transpiler, flow, resume_from, max_frame, reason, detail, seq, where, stage, unit_name,
     finding, severity, code, message, place, file, line, column, status, counts, units, gaps, files, freed,
     truncated, trailing_bytes, bad_tag, too_large, too_deep, too_long, out_of_range, bad_utf8, unknown_atom,
     bad_variant, missing_field, duplicate_field, unknown_field, unsupported, bad_version,
     seq_gap, no_credit, unit_order, bad_unit_name, bad_index, bad_choice, profile, low_level, bad_hint,
     session_mismatch, unknown_session, busy, choices, bad_hello,
     resolve, hints, lower, mechanics, print, write, error, warning, note, ok, partial, failed].
