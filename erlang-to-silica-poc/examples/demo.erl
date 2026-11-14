%% demo: the example program of erlang-to-silica-poc. One small function per construct of the subset.
%%
%% Every type the sender states comes from what is written here: a -spec for each function, the field types of
%% -record, a -type, and type-test guards on the messages a receive takes (Erlang's messages have no declared
%% type).
-module(demo).
-behaviour(supervisor).
-export([add/2, scale/2, ratio/2, half/1, whole/1, same/2, describe/1, swap/1, origin/0, move/3, x_of/1,
         classify/1, area/1, max_of/2, ping_pong/1, pong_loop/0, counter/1, start_counter/0,
         sum_list/1, total/1, total/2, greeting/0, first_x/1, apply_twice/2,
         start_sup/0, init/1, start_tally/1, tally_add/1, tally_total/0, tally_stop/0]).

-record(point, {x = 0 :: integer(), y = 0 :: integer()}).

-type shape() :: {square, float()} | {rectangle, float(), float()} | {circle, float()}.

%% --- basic types, operators, calls
-spec add(integer(), integer()) -> integer().
add(A, B) -> A + B.

%% --- numbers: Erlang converts an integer next to a float; the sender writes that conversion (to_float)
-spec scale(float(), integer()) -> float().
scale(F, N) -> F * N * 1.5.

%% `/` is float division whatever its operands are, and it fails when the divisor is zero
-spec ratio(integer(), integer()) -> float().
ratio(A, B) -> A / B.

-spec half(float()) -> float().
half(X) -> X / 2.

%% float/1, trunc/1 and round/1 are the conversion operators
-spec whole(float()) -> integer().
whole(X) -> trunc(X) + round(X * float(2)).

%% == compares the numbers, =:= also the types
-spec same(integer(), float()) -> boolean().
same(N, F) -> N == F orelse N =:= F.

%% --- tuples and records
-spec swap({integer(), boolean()}) -> {boolean(), integer()}.
swap({A, B}) -> {B, A}.

-spec origin() -> #point{}.
origin() -> #point{x = 0, y = 0}.

-spec move(#point{}, integer(), integer()) -> #point{}.
move(P, Dx, Dy) ->
    X = P#point.x + Dx,
    P#point{x = X, y = P#point.y + Dy}.

-spec x_of(#point{}) -> integer().
x_of(#point{x = X}) -> X.

%% --- clauses, patterns, guards, case, if
-spec classify(integer()) -> negative | zero | positive.
classify(N) when N < 0 -> negative;
classify(0) -> zero;
classify(_) -> positive.

-spec area(shape()) -> float().
area({square, Side}) -> Side * Side;
area({rectangle, W, H}) when W > 0, H > 0 -> W * H;
area({circle, R}) -> 3.14159 * R * R;
area(_) -> error(badarg).

-spec describe(integer()) -> binary().
describe(N) ->
    case classify(N) of
        zero -> <<"zero">>;
        _ -> <<"not zero">>
    end.

-spec max_of(integer(), integer()) -> integer().
max_of(A, B) ->
    if A >= B -> A;
       true -> B
    end.

%% --- processes: spawn, send, receive. The guards say what the messages hold.
-spec ping_pong(integer()) -> integer() | timeout.
ping_pong(N) ->
    Pong = spawn(fun() -> pong_loop() end),
    Pong ! {ping, self(), N},
    receive
        {pong, M} when is_integer(M) -> Pong ! stop, M
    after 1000 ->
        timeout
    end.

-spec pong_loop() -> ok.
pong_loop() ->
    receive
        {ping, From, N} when is_pid(From), is_integer(N) -> From ! {pong, add(N, 1)}, pong_loop();
        stop -> ok
    end.

%% --- a hand-written actor with state
-spec start_counter() -> pid().
start_counter() -> spawn(demo, counter, [0]).

-spec counter(integer()) -> integer().
counter(Total) ->
    receive
        {add, N} when is_integer(N) -> counter(Total + N);
        {get, From} when is_pid(From) -> From ! {total, Total}, counter(Total);
        stop -> Total
    end.

%% --- lists: a literal list, a cell, the empty list, in patterns and in expressions; a string is a list
-spec sum_list([integer()]) -> integer().
sum_list([]) -> 0;
sum_list([H | T]) -> H + sum_list(T).

%% --- one name at two arities: both are sent with the arity in the name (total__1, total__2)
-spec total([integer()]) -> integer().
total(L) -> total(L, 0).

-spec total([integer()], integer()) -> integer().
total([], Acc) -> Acc;
total([H | T], Acc) -> total(T, Acc + H).

-spec greeting() -> string().
greeting() -> "hello" ++ [$,, $\s | "world"].

%% --- an alias pattern: the whole value and its parts
-spec first_x(#point{}) -> {integer(), #point{}}.
first_x(P = #point{x = X}) -> {X, P}.

%% --- funs: the -spec types the fun that is passed and the fun that is called
-spec apply_twice(fun((integer()) -> integer()), integer()) -> integer().
apply_twice(F, X) -> F(F(X)).

%% --- a supervisor with a static child list: OTP's supervisor behaviour, with this module as its callback
%%     module. The children are fixed when the supervisor starts: here one, a counter registered as `tally`.
%%     The sender reads init/1 and the child's start function and sends the child as a static child of the
%%     unit's supervisor (README, "A static supervisor").
-spec start_sup() -> ok.
start_sup() ->
    {ok, _Sup} = supervisor:start_link({local, demo_sup}, ?MODULE, []),
    ok.

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 3, period => 10},
    Tally = #{id => tally, start => {demo, start_tally, [0]}, restart => transient},
    {ok, {SupFlags, [Tally]}}.

%% The child's start function: the supervisor calls it when it starts, and again for each restart.
-spec start_tally(integer()) -> {ok, pid()}.
start_tally(Start) ->
    Pid = spawn_link(demo, counter, [Start]),
    true = register(tally, Pid),
    {ok, Pid}.

%% The supervised child is talked to by its registered name.
-spec tally_add(integer()) -> ok.
tally_add(N) ->
    tally ! {add, N},
    ok.

-spec tally_total() -> integer() | timeout.
tally_total() ->
    tally ! {get, self()},
    receive
        {total, Total} when is_integer(Total) -> Total
    after 1000 ->
        timeout
    end.

-spec tally_stop() -> ok.
tally_stop() ->
    tally ! stop,
    ok.
