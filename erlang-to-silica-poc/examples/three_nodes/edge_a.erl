%% edge_a: an edge node of the three-node example (hub topology). It dials hub@localhost, asks the hub's registered
%% name hub_in to double 21, and prints the answer, which the hub casts back to this node's registered name a_inbox.
-module(edge_a).
-behaviour(supervisor).
-silica_node([{name, 'a@localhost'},
              {cookie_file, "cookie"},
              {peer, 'hub@localhost', "localhost", dial},
              {redial, 250, 4000},
              {remote, hub_in, 'hub@localhost', request, [atom, integer]},
              {local, a_inbox, reply, [integer]}]).
-export([run/0, start_sup/0, init/1, start_a_inbox/0, inbox/1]).

-spec start_sup() -> ok.
start_sup() ->
    {ok, _Sup} = supervisor:start_link({local, edge_a_sup}, ?MODULE, []),
    ok.

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 3, period => 10},
    Inbox = #{id => a_inbox, start => {edge_a, start_a_inbox, []}, restart => transient},
    {ok, {SupFlags, [Inbox]}}.

start_a_inbox() ->
    Pid = spawn_link(edge_a, inbox, [0]),
    true = register(a_inbox, Pid),
    {ok, Pid}.

%% The argument is the sum of the answers so far.
-spec inbox(integer()) -> ok.
inbox(Sum) ->
    receive
        {reply, V} when is_integer(V) ->
            io:format("a: the hub answered ~p~n", [V]),
            inbox(Sum + V)
    end.

%% Start the inbox, ask the hub, and wait for the answer to arrive.
-spec run() -> ok.
run() ->
    start_sup(),
    {hub_in, 'hub@localhost'} ! {request, a_inbox, 21},
    receive never -> ok after 8000 -> ok end.
