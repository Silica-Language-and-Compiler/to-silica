%% edge_c: an edge node of the three-node example (hub topology). It dials hub@localhost, asks the hub's registered
%% name hub_in to double 34, and prints the answer, which the hub casts back to this node's registered name c_inbox.
-module(edge_c).
-behaviour(supervisor).
-silica_node([{name, 'c@localhost'},
              {cookie_file, "cookie"},
              {peer, 'hub@localhost', "127.0.0.1", dial},
              {redial, 250, 4000},
              {remote, hub_in, 'hub@localhost', request, [atom, integer]},
              {local, c_inbox, reply, [integer]}]).
-export([run/0, start_sup/0, init/1, start_c_inbox/0, inbox/1]).

-spec start_sup() -> ok.
start_sup() ->
    {ok, _Sup} = supervisor:start_link({local, edge_c_sup}, ?MODULE, []),
    ok.

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 3, period => 10},
    Inbox = #{id => c_inbox, start => {edge_c, start_c_inbox, []}, restart => transient},
    {ok, {SupFlags, [Inbox]}}.

start_c_inbox() ->
    Pid = spawn_link(edge_c, inbox, [0]),
    true = register(c_inbox, Pid),
    {ok, Pid}.

%% The argument is the sum of the answers so far.
-spec inbox(integer()) -> ok.
inbox(Sum) ->
    receive
        {reply, V} when is_integer(V) ->
            io:format("c: the hub answered ~p~n", [V]),
            inbox(Sum + V)
    end.

%% Start the inbox, ask the hub, and wait for the answer to arrive.
-spec run() -> ok.
run() ->
    start_sup(),
    {hub_in, 'hub@localhost'} ! {request, c_inbox, 34},
    receive never -> ok after 8000 -> ok end.
