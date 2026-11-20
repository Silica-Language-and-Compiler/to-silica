%% mesh5_b: one node of the five-node mesh example (every node holds a link to all four others: ten links).
%%
%% The nodes are na, nb, nc, nd and ne, all @localhost. A node dials every node whose letter comes before its own and
%% listens for the rest, so each pair has one link. A link carries messages both ways, so which end dialed does not
%% matter to the programs. This node: dials na; listens for nc, nd, ne.
%%
%% Every node does the same two things. It serves requests on its registered name b_in: a request names the
%% registered name to answer to and a number, and is answered with this node's b_in and twice the number. And it
%% asks all four other nodes to double a number (node 1..5 asks node 1..5 for the number 10 * asker + asked), and
%% prints each answer when it arrives at its registered name b_inbox. So twenty requests and twenty answers cross
%% the ten links, each link in both directions.
%%
%% Distribution is BEES's BEAM mode: EPMD and a cookie (contract T9.17), as in examples/three_nodes.
-module(mesh5_b).
-behaviour(supervisor).
-silica_node([{name, 'nb@localhost'},
              {cookie_file, "cookie"},
              {peer, 'na@localhost', "localhost", dial},
              {peer, 'nc@localhost', "localhost", listen},
              {peer, 'nd@localhost', "localhost", listen},
              {peer, 'ne@localhost', "localhost", listen},
              {redial, 250, 4000},
              {local, b_in, request, [atom, integer]},
              {local, b_inbox, reply, [atom, integer]},
              {remote, a_in, 'na@localhost', request, [atom, integer]},
              {remote, c_in, 'nc@localhost', request, [atom, integer]},
              {remote, d_in, 'nd@localhost', request, [atom, integer]},
              {remote, e_in, 'ne@localhost', request, [atom, integer]},
              {remote, a_inbox, 'na@localhost', reply, [atom, integer]},
              {remote, c_inbox, 'nc@localhost', reply, [atom, integer]},
              {remote, d_inbox, 'nd@localhost', reply, [atom, integer]},
              {remote, e_inbox, 'ne@localhost', reply, [atom, integer]}]).
-export([run/0, start_sup/0, init/1, start_b_in/0, start_b_inbox/0, service/1, inbox/1, answer/2]).

%% --- the supervisor: two static children, registered as b_in and b_inbox

-spec start_sup() -> ok.
start_sup() ->
    {ok, _Sup} = supervisor:start_link({local, mesh5_b_sup}, ?MODULE, []),
    ok.

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 3, period => 10},
    Service = #{id => b_in, start => {mesh5_b, start_b_in, []}, restart => transient},
    Inbox = #{id => b_inbox, start => {mesh5_b, start_b_inbox, []}, restart => transient},
    {ok, {SupFlags, [Service, Inbox]}}.

start_b_in() ->
    Pid = spawn_link(mesh5_b, service, [0]),
    true = register(b_in, Pid),
    {ok, Pid}.

start_b_inbox() ->
    Pid = spawn_link(mesh5_b, inbox, [0]),
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
answer(a_inbox, V) -> {a_inbox, 'na@localhost'} ! {reply, b_in, V}, ok;
answer(c_inbox, V) -> {c_inbox, 'nc@localhost'} ! {reply, b_in, V}, ok;
answer(d_inbox, V) -> {d_inbox, 'nd@localhost'} ! {reply, b_in, V}, ok;
answer(e_inbox, V) -> {e_inbox, 'ne@localhost'} ! {reply, b_in, V}, ok;
answer(_Other, _V) -> ok.

%% --- the inbox: the argument is the sum of the answers so far

-spec inbox(integer()) -> ok.
inbox(Sum) ->
    receive
        {reply, From, V} when is_atom(From), is_integer(V) ->
            io:format("b: ~p answered ~p~n", [From, V]),
            inbox(Sum + V)
    end.

%% --- run/0, not main/0 (BEES owns main). Start the two processes, ask the four other nodes, and stay up while the
%% answers arrive and the other nodes ask this one.

-spec run() -> ok.
run() ->
    start_sup(),
    {a_in, 'na@localhost'} ! {request, b_inbox, 21},
    {c_in, 'nc@localhost'} ! {request, b_inbox, 23},
    {d_in, 'nd@localhost'} ! {request, b_inbox, 24},
    {e_in, 'ne@localhost'} ! {request, b_inbox, 25},
    receive never -> ok after 15000 -> ok end.
