%% actors: a small working application of three actors, written inside the subset erlang-to-silica-poc translates.
%%
%%   coordinator (main/0)  starts the supervisor, sends the counter some numbers, prints what it learns
%%   supervisor            starts the counter linked to itself and restarts it if it ever ends abnormally
%%   counter               holds a #tally{} and answers {add, N}, {get, From} and stop
%%
%% Every function has a -spec and every message a receive takes says what it holds with type-test guards: that
%% is where the sender gets the types it must state (Erlang's messages have no declared type).
%%
%% Run it:   erlc -o /tmp examples/actors.erl && erl -noshell -pa /tmp -s actors main -s init stop
-module(actors).
-export([main/0, supervisor/2, counter/1, new_tally/0, bump/2, average/1, describe/1]).

-record(tally, {total = 0 :: integer(), adds = 0 :: integer()}).

%% --- pure functions on the counter's state: basic types, a record, guards, if

-spec new_tally() -> #tally{}.
new_tally() -> #tally{total = 0, adds = 0}.

-spec bump(#tally{}, integer()) -> #tally{}.
bump(T = #tally{total = Total, adds = Adds}, N) ->
    T#tally{total = Total + N, adds = Adds + 1}.

-spec average(#tally{}) -> float().
average(#tally{adds = 0}) -> 0.0;
average(#tally{total = Total, adds = Adds}) -> Total / Adds.

-spec describe(integer()) -> small | large.
describe(Total) ->
    if Total < 10 -> small;
       true -> large
    end.

%% --- the counter actor: its state is the argument of its loop

-spec counter(#tally{}) -> ok.
counter(T) ->
    receive
        {add, N} when is_integer(N) ->
            counter(bump(T, N));
        {get, From} when is_pid(From) ->
            From ! {tally, T#tally.total, T#tally.adds, average(T)},
            counter(T);
        stop ->
            ok
    end.

%% --- the supervisor actor: one linked child. It is restarted when it ends abnormally; when it ends normally
%%     the supervisor tells its owner how many restarts there were, and ends too.

-spec supervisor(pid(), integer()) -> {supervisor_done, integer()}.
supervisor(Owner, Restarts) ->
    process_flag(trap_exit, true),
    Child = spawn_link(fun() -> counter(new_tally()) end),
    Owner ! {child, Child},
    receive
        {'EXIT', Child, normal} -> Owner ! {supervisor_done, Restarts};
        {'EXIT', Child, _Reason} -> supervisor(Owner, Restarts + 1)
    end.

%% --- the coordinator: the program's entry point

-spec main() -> {restarts, integer()}.
main() ->
    spawn(actors, supervisor, [self(), 0]),
    Counter = receive {child, Pid} when is_pid(Pid) -> Pid end,
    Counter ! {add, 2},
    Counter ! {add, 5},
    {Total, Adds, Mean} = ask(Counter),
    io:format("total ~p after ~p adds, mean ~p: ~p~n", [Total, Adds, Mean, describe(Total)]),
    Counter ! {add, 29},
    {Total2, Adds2, Mean2} = ask(Counter),
    io:format("total ~p after ~p adds, mean ~p: ~p~n", [Total2, Adds2, Mean2, describe(Total2)]),
    Counter ! stop,
    receive
        {supervisor_done, Restarts} when is_integer(Restarts) ->
            io:format("the counter stopped; restarts: ~p~n", [Restarts]),
            {restarts, Restarts}
    end.

%% A request and its answer. The timeout is the usual one of a call: a counter that does not answer is a failure.
-spec ask(pid()) -> {integer(), integer(), float()}.
ask(Counter) ->
    Counter ! {get, self()},
    receive
        {tally, Total, Adds, Mean} when is_integer(Total), is_integer(Adds), is_float(Mean) -> {Total, Adds, Mean}
    after 5000 -> exit(no_answer)
    end.
