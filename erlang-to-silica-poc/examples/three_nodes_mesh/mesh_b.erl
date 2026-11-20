%% mesh_b: one node of the three-node mesh example (every node holds a link to both others).
%%
%%   ma@localhost ◄──dial── mb@localhost
%%        ▲                      ▲
%%        └──dial── mc@localhost ┘
%%
%% mb dials ma, mc dials ma and mb: three links, one for each pair. A link carries messages both ways, so which end
%% dialed does not matter to the programs. This node: dials ma, listens for mc.
%%
%% Every node does the same two things. It serves requests on its registered name b_in: {request, ReplyTo, N} is
%% answered with {reply, b_in, 2 * N}, sent to the registered name ReplyTo on the node that asked. And it asks both
%% other nodes to double a number, and prints each answer when it arrives at its registered name b_inbox.
%% So six requests and six answers cross the three links, each link in both directions.
%%
%% Distribution is BEES's BEAM mode: EPMD and a cookie (contract T9.17), as in examples/three_nodes.
-module(mesh_b).
-behaviour(supervisor).
-silica_node([{name, 'mb@localhost'},
              {cookie_file, "cookie"},
              {peer, 'ma@localhost', "localhost", dial},
              {peer, 'mc@localhost', "localhost", listen},
              {redial, 250, 4000},
              {local, b_in, request, [atom, integer]},
              {local, b_inbox, reply, [atom, integer]},
              {remote, a_in, 'ma@localhost', request, [atom, integer]},
              {remote, c_in, 'mc@localhost', request, [atom, integer]},
              {remote, a_inbox, 'ma@localhost', reply, [atom, integer]},
              {remote, c_inbox, 'mc@localhost', reply, [atom, integer]}]).
-export([run/0, start_sup/0, init/1, start_b_in/0, start_b_inbox/0, service/1, inbox/1, answer/2]).

%% --- the supervisor: two static children, registered as b_in and b_inbox

-spec start_sup() -> ok.
start_sup() ->
    {ok, _Sup} = supervisor:start_link({local, mesh_b_sup}, ?MODULE, []),
    ok.

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 3, period => 10},
    Service = #{id => b_in, start => {mesh_b, start_b_in, []}, restart => transient},
    Inbox = #{id => b_inbox, start => {mesh_b, start_b_inbox, []}, restart => transient},
    {ok, {SupFlags, [Service, Inbox]}}.

start_b_in() ->
    Pid = spawn_link(mesh_b, service, [0]),
    true = register(b_in, Pid),
    {ok, Pid}.

start_b_inbox() ->
    Pid = spawn_link(mesh_b, inbox, [0]),
    true = register(b_inbox, Pid),
    {ok, Pid}.

%% --- the service: the argument is how many requests it has answered

-spec service(integer()) -> ok.
service(Served) ->
    receive
        {request, ReplyTo, N} when is_atom(ReplyTo), is_integer(N) ->
            io:format("b: request ~p from ~p~n", [N, ReplyTo]),
            answer(ReplyTo, N * 2),
            service(Served + 1)
    end.

%% The answer goes to the name on the node that asked, and says who answered.
-spec answer(atom(), integer()) -> ok.
answer(a_inbox, V) -> {a_inbox, 'ma@localhost'} ! {reply, b_in, V}, ok;
answer(c_inbox, V) -> {c_inbox, 'mc@localhost'} ! {reply, b_in, V}, ok;
answer(_Other, _V) -> ok.

%% --- the inbox: the argument is the sum of the answers so far

-spec inbox(integer()) -> ok.
inbox(Sum) ->
    receive
        {reply, From, V} when is_atom(From), is_integer(V) ->
            io:format("b: ~p answered ~p~n", [From, V]),
            inbox(Sum + V)
    end.

%% --- run/0, not main/0 (BEES owns main). Start the two processes, ask both other nodes, and stay up while the
%% answers arrive and the other nodes ask this one.

-spec run() -> ok.
run() ->
    start_sup(),
    {a_in, 'ma@localhost'} ! {request, b_inbox, 21},
    {c_in, 'mc@localhost'} ! {request, b_inbox, 22},
    receive never -> ok after 15000 -> ok end.
