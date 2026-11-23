%% mesh6_a: one node of the six-node mixed mesh (every node holds a link to all five others: fifteen links).
%%
%% The six nodes are written in four languages: xa and xd in Erlang, xb and xe in Elixir, xc in Gleam, and xf in
%% Silica by hand. All are @localhost. A node dials every node whose letter comes before its own and listens for the
%% rest, so each pair has one link. This node: listens for xb, xc, xd, xe, xf.
%%
%% Every node does the same two things, whatever its language. It serves requests on its registered name a_in: a
%% request names the registered name to answer to (an atom) and a number, and is answered with this node's a_in
%% and twice the number. And it asks all five other nodes to double a number (node 1..6 asks node 1..6 for the number
%% 10 * asker + asked), and prints each answer when it arrives at its registered name a_inbox. So thirty requests
%% and thirty answers cross the fifteen links, each link in both directions.
%%
%% Distribution is BEES's BEAM mode: EPMD and a cookie (contract T9.17).
-module(mesh6_a).
-behaviour(supervisor).
-silica_node([{name, 'xa@localhost'},
              {cookie_file, "cookie"},
              {peer, 'xb@localhost', "localhost", listen},
              {peer, 'xc@localhost', "localhost", listen},
              {peer, 'xd@localhost', "localhost", listen},
              {peer, 'xe@localhost', "localhost", listen},
              {peer, 'xf@localhost', "localhost", listen},
              {local, a_in, request, [atom, integer]},
              {local, a_inbox, reply, [atom, integer]},
              {remote, b_in, 'xb@localhost', request, [atom, integer]},
              {remote, c_in, 'xc@localhost', request, [atom, integer]},
              {remote, d_in, 'xd@localhost', request, [atom, integer]},
              {remote, e_in, 'xe@localhost', request, [atom, integer]},
              {remote, f_in, 'xf@localhost', request, [atom, integer]},
              {remote, b_inbox, 'xb@localhost', reply, [atom, integer]},
              {remote, c_inbox, 'xc@localhost', reply, [atom, integer]},
              {remote, d_inbox, 'xd@localhost', reply, [atom, integer]},
              {remote, e_inbox, 'xe@localhost', reply, [atom, integer]},
              {remote, f_inbox, 'xf@localhost', reply, [atom, integer]}]).
-export([run/0, start_sup/0, init/1, start_a_in/0, start_a_inbox/0, service/1, inbox/1, answer/2]).

%% --- the supervisor: two static children, registered as a_in and a_inbox

-spec start_sup() -> ok.
start_sup() ->
    {ok, _Sup} = supervisor:start_link({local, mesh6_a_sup}, ?MODULE, []),
    ok.

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 3, period => 10},
    Service = #{id => a_in, start => {mesh6_a, start_a_in, []}, restart => transient},
    Inbox = #{id => a_inbox, start => {mesh6_a, start_a_inbox, []}, restart => transient},
    {ok, {SupFlags, [Service, Inbox]}}.

start_a_in() ->
    Pid = spawn_link(mesh6_a, service, [0]),
    true = register(a_in, Pid),
    {ok, Pid}.

start_a_inbox() ->
    Pid = spawn_link(mesh6_a, inbox, [0]),
    true = register(a_inbox, Pid),
    {ok, Pid}.

%% --- the service: the argument is how many requests it has answered

-spec service(integer()) -> ok.
service(Served) ->
    receive
        {request, ReplyTo, N} when is_atom(ReplyTo), is_integer(N) ->
            io:format("a: request ~p from ~p~n", [N, ReplyTo]),
            answer(ReplyTo, N * 2),
            service(Served + 1)
    end.

%% The answer goes to the name on the node that asked, and says who answered.
-spec answer(atom(), integer()) -> ok.
answer(b_inbox, V) -> {b_inbox, 'xb@localhost'} ! {reply, a_in, V}, ok;
answer(c_inbox, V) -> {c_inbox, 'xc@localhost'} ! {reply, a_in, V}, ok;
answer(d_inbox, V) -> {d_inbox, 'xd@localhost'} ! {reply, a_in, V}, ok;
answer(e_inbox, V) -> {e_inbox, 'xe@localhost'} ! {reply, a_in, V}, ok;
answer(f_inbox, V) -> {f_inbox, 'xf@localhost'} ! {reply, a_in, V}, ok;
answer(_Other, _V) -> ok.

%% --- the inbox: the argument is the sum of the answers so far

-spec inbox(integer()) -> ok.
inbox(Sum) ->
    receive
        {reply, From, V} when is_atom(From), is_integer(V) ->
            io:format("a: ~p answered ~p~n", [From, V]),
            inbox(Sum + V)
    end.

%% --- run/0, not main/0 (BEES owns main). Start the two processes, ask the five other nodes, and stay up while the
%% answers arrive and the other nodes ask this one.

-spec run() -> ok.
run() ->
    start_sup(),
    {b_in, 'xb@localhost'} ! {request, a_inbox, 12},
    {c_in, 'xc@localhost'} ! {request, a_inbox, 13},
    {d_in, 'xd@localhost'} ! {request, a_inbox, 14},
    {e_in, 'xe@localhost'} ! {request, a_inbox, 15},
    {f_in, 'xf@localhost'} ! {request, a_inbox, 16},
    receive never -> ok after 15000 -> ok end.
