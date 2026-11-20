%% mesh5_c: one node of the five-node mesh example (every node holds a link to all four others: ten links).
%%
%% The nodes are na, nb, nc, nd and ne, all @localhost. A node dials every node whose letter comes before its own and
%% listens for the rest, so each pair has one link. A link carries messages both ways, so which end dialed does not
%% matter to the programs. This node: dials na, nb; listens for nd, ne.
%%
%% Every node does the same two things. It serves requests on its registered name c_in: a request names the
%% registered name to answer to and a number, and is answered with this node's c_in and twice the number. And it
%% asks all four other nodes to double a number (node 1..5 asks node 1..5 for the number 10 * asker + asked), and
%% prints each answer when it arrives at its registered name c_inbox. So twenty requests and twenty answers cross
%% the ten links, each link in both directions.
%%
%% Distribution is BEES's BEAM mode: EPMD and a cookie (contract T9.17), as in examples/three_nodes.
-module(mesh5_c).
-behaviour(supervisor).
-silica_node([{name, 'nc@localhost'},
              {cookie_file, "cookie"},
              {peer, 'na@localhost', "localhost", dial},
              {peer, 'nb@localhost', "localhost", dial},
              {peer, 'nd@localhost', "localhost", listen},
              {peer, 'ne@localhost', "localhost", listen},
              {redial, 250, 4000},
              {local, c_in, request, [atom, integer]},
              {local, c_inbox, reply, [atom, integer]},
              {remote, a_in, 'na@localhost', request, [atom, integer]},
              {remote, b_in, 'nb@localhost', request, [atom, integer]},
              {remote, d_in, 'nd@localhost', request, [atom, integer]},
              {remote, e_in, 'ne@localhost', request, [atom, integer]},
              {remote, a_inbox, 'na@localhost', reply, [atom, integer]},
              {remote, b_inbox, 'nb@localhost', reply, [atom, integer]},
              {remote, d_inbox, 'nd@localhost', reply, [atom, integer]},
              {remote, e_inbox, 'ne@localhost', reply, [atom, integer]}]).
-export([run/0, start_sup/0, init/1, start_c_in/0, start_c_inbox/0, service/1, inbox/1, answer/2]).

%% --- the supervisor: two static children, registered as c_in and c_inbox

-spec start_sup() -> ok.
start_sup() ->
    {ok, _Sup} = supervisor:start_link({local, mesh5_c_sup}, ?MODULE, []),
    ok.

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 3, period => 10},
    Service = #{id => c_in, start => {mesh5_c, start_c_in, []}, restart => transient},
    Inbox = #{id => c_inbox, start => {mesh5_c, start_c_inbox, []}, restart => transient},
    {ok, {SupFlags, [Service, Inbox]}}.

start_c_in() ->
    Pid = spawn_link(mesh5_c, service, [0]),
    true = register(c_in, Pid),
    {ok, Pid}.

start_c_inbox() ->
    Pid = spawn_link(mesh5_c, inbox, [0]),
    true = register(c_inbox, Pid),
    {ok, Pid}.

%% --- the service: the argument is how many requests it has answered

-spec service(integer()) -> ok.
service(Served) ->
    receive
        {request, ReplyTo, N} when is_atom(ReplyTo), is_integer(N) ->
            io:format("c: request ~p from ~p~n", [N, ReplyTo]),
            answer(ReplyTo, N * 2),
            service(Served + 1)
    end.

%% The answer goes to the name on the node that asked, and says who answered.
-spec answer(atom(), integer()) -> ok.
answer(a_inbox, V) -> {a_inbox, 'na@localhost'} ! {reply, c_in, V}, ok;
answer(b_inbox, V) -> {b_inbox, 'nb@localhost'} ! {reply, c_in, V}, ok;
answer(d_inbox, V) -> {d_inbox, 'nd@localhost'} ! {reply, c_in, V}, ok;
answer(e_inbox, V) -> {e_inbox, 'ne@localhost'} ! {reply, c_in, V}, ok;
answer(_Other, _V) -> ok.

%% --- the inbox: the argument is the sum of the answers so far

-spec inbox(integer()) -> ok.
inbox(Sum) ->
    receive
        {reply, From, V} when is_atom(From), is_integer(V) ->
            io:format("c: ~p answered ~p~n", [From, V]),
            inbox(Sum + V)
    end.

%% --- run/0, not main/0 (BEES owns main). Start the two processes, ask the four other nodes, and stay up while the
%% answers arrive and the other nodes ask this one.

-spec run() -> ok.
run() ->
    start_sup(),
    {a_in, 'na@localhost'} ! {request, c_inbox, 31},
    {b_in, 'nb@localhost'} ! {request, c_inbox, 32},
    {d_in, 'nd@localhost'} ! {request, c_inbox, 34},
    {e_in, 'ne@localhost'} ! {request, c_inbox, 35},
    receive never -> ok after 15000 -> ok end.
