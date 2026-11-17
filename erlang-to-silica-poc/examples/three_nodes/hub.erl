%% hub: the middle node of the three-node example (hub topology). It listens for the two edge nodes, a@localhost and
%% c@localhost, serves requests on the registered name hub_in and answers each one by name on the edge that asked.
%%
%%   a@localhost ──dial──►  hub@localhost  ◄──dial── c@localhost
%%
%% A request is {request, ReplyTo, N}: ReplyTo is the registered name the answer goes to (a pid does not cross a node;
%% BEES sends to registered names, so the request says which name). The answer is {reply, 2 * N}.
%%
%% Distribution is BEES's BEAM mode: EPMD (started with `epmd -daemon` if it is not running) and a cookie. The
%% attribute below is what to-silica turns into BEES's manifest and bees.config (contract T9.17).
-module(hub).
-behaviour(supervisor).
-silica_node([{name, 'hub@localhost'},
              {cookie_file, "cookie"},
              {peer, 'a@localhost', "127.0.0.1", listen},
              {peer, 'c@localhost', "127.0.0.1", listen},
              {local, hub_in, request, [atom, integer]},
              {remote, a_inbox, 'a@localhost', reply, [integer]},
              {remote, c_inbox, 'c@localhost', reply, [integer]}]).
-export([run/0, start_sup/0, init/1, start_hub_in/0, service/1, answer/2]).

%% --- the supervisor: one static child, registered as hub_in

-spec start_sup() -> ok.
start_sup() ->
    {ok, _Sup} = supervisor:start_link({local, hub_sup}, ?MODULE, []),
    ok.

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 3, period => 10},
    Hub = #{id => hub_in, start => {hub, start_hub_in, []}, restart => transient},
    {ok, {SupFlags, [Hub]}}.

start_hub_in() ->
    Pid = spawn_link(hub, service, [0]),
    true = register(hub_in, Pid),
    {ok, Pid}.

%% --- the service: the argument is how many requests it has answered

-spec service(integer()) -> ok.
service(Served) ->
    receive
        {request, ReplyTo, N} when is_atom(ReplyTo), is_integer(N) ->
            io:format("hub: request ~p from ~p~n", [N, ReplyTo]),
            answer(ReplyTo, N * 2),
            service(Served + 1)
    end.

%% The answer goes to the name on the node that asked.
-spec answer(atom(), integer()) -> ok.
answer(a_inbox, V) -> {a_inbox, 'a@localhost'} ! {reply, V}, ok;
answer(c_inbox, V) -> {c_inbox, 'c@localhost'} ! {reply, V}, ok;
answer(_Other, _V) -> ok.

%% --- run/0, not main/0: BEES owns the node program's main, which starts the node and then calls run/0. Start the service and stay up while the edges talk to it

-spec run() -> ok.
run() ->
    start_sup(),
    receive never -> ok after 20000 -> ok end.
