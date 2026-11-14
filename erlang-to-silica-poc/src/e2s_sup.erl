%% e2s_sup: OTP's supervisor behaviour, read by the sender BEFORE anything is sent (abstract forms in, abstract
%% forms out). A supervisor is Erlang's (OTP's) own construct: what `-behaviour(supervisor)`, init/1, a child
%% specification and a start function mean is this sender's business (contract 1, "What you own"), and the
%% transpiler knows none of it. What the sender sends instead is the contract's STATIC CHILD (T9.14b): a
%% (:register) of a (:spawn) with literal arguments, which the transpiler writes into the child list its unit's
%% supervisor has from its start.
%%
%%   -behaviour(supervisor).
%%   start_sup() ->                                              start_sup() ->
%%       {ok, _Sup} = supervisor:start_link({local, demo_sup},       e2s_sup:static_child(tally, transient, one_for_one,
%%                                          ?MODULE, []),                                 counter, [0]),
%%       ok.                                                         ok.
%%   init([]) ->
%%       SupFlags = #{strategy => one_for_one, ...},              (init/1 and start_tally/1 are not sent: what
%%       Tally = #{id => tally, restart => transient,              they say is in the static child)
%%                 start => {demo, start_tally, [0]}},
%%       {ok, {SupFlags, [Tally]}}.
%%   start_tally(Start) ->
%%       Pid = spawn_link(demo, counter, [Start]),
%%       true = register(tally, Pid),
%%       {ok, Pid}.
%%
%% e2s_sup:static_child/5 is no function: it is a mark the codex turns into nodes (e2s_codex, static_child/7).
%%
%% WHAT IS READ, and what makes this pass leave the module as it is (the codex then sends its gaps):
%%   the module         has -behaviour(supervisor) (or -behavior) and init/1
%%   the start          `{ok, _} = supervisor:start_link(Name, ThisModule, Args)` or `... start_link(ThisModule,
%%                      Args)` as a statement of a function body, the variable `_` or one that starts with `_`;
%%                      or the call alone as a statement that is not the last. Args is a literal term. A start
%%                      whose value is used stays a call (the supervisor's own pid has no node).
%%   init/1             is EVALUATED by this sender with Args (erl_eval; it may build and match data, and call
%%                      nothing), and must answer {ok, {SupFlags, ChildSpecs}}: SupFlags a map or the tuple
%%                      {Strategy, Intensity, Period}; each child specification a map or the six-element tuple,
%%                      of type worker. What is not written has OTP's default: strategy one_for_one, restart
%%                      permanent.
%%   the start function {ThisModule, F, Args} with literal Args; F has one clause, variables as parameters, and
%%                      the body `{ok, spawn_link(...)}` or `Pid = spawn_link(...), [true =] register(Name, Pid),
%%                      {ok, Pid}` (the register is optional), where the spawn_link is spawn_link(ThisModule, G,
%%                      [A, ...]) or spawn_link(fun() -> G(A, ...) end) and each A is a literal or a parameter.
%%   the child's name   the name its start function registers it under; with none, the id of its specification.
%%
%% WHAT IS NOT ERLANG'S BEHAVIOUR (README, "A static supervisor").
-module(e2s_sup).
-export([forms/1, read/2]).

%% forms(Forms) -> Forms with every supervisor start that can be read replaced by its static children, and
%% init/1 and the start functions (which nothing else calls) taken out.
forms(Forms) ->
    Mod = hd([M || {attribute, _, module, M} <- Forms]),
    IsSup = [] =/= [x || {attribute, _, B, supervisor} <- Forms, B =:= behaviour orelse B =:= behavior],
    Init = [F || F = {function, _, init, 1, _} <- Forms],
    case {IsSup, Init} of
        {true, [_]} ->
            {Forms1, Used} = lists:mapfoldl(fun(F, Acc) -> form(F, Mod, Forms, Acc) end, [], Forms),
            case Used of
                [] -> Forms;
                _ -> remove(Forms1, lists:usort(Used))
            end;
        _ -> Forms
    end.

form({function, A, N, Ar, Cs}, Mod, Forms, Acc0) ->
    {Cs1, Acc} = lists:mapfoldl(
                   fun({clause, CA, Ps, Gs, Body}, Acc1) ->
                           {Body1, Acc2} = body(Body, Mod, Forms, Acc1),
                           {{clause, CA, Ps, Gs, Body1}, Acc2}
                   end, Acc0, Cs),
    {{function, A, N, Ar, Cs1}, Acc};
form(Other, _Mod, _Forms, Acc) -> {Other, Acc}.

%% The statements of a function body; only the top level of a body is looked at.
body([], _Mod, _Forms, Acc) -> {[], Acc};
body([E | Rest], Mod, Forms, Acc0) ->
    {Es, Acc1} = case start(E, Rest =/= []) of
                     {ok, Anno, Args} ->
                         case read(Forms, Args) of
                             {ok, Children} ->
                                 {[mark(Anno, C) || C <- Children], [F || #{start_function := F} <- Children] ++ Acc0};
                             {no, _Why} -> {[E], Acc0}
                         end;
                     no -> {[E], Acc0}
                 end,
    {RestEs, Acc} = body(Rest, Mod, Forms, Acc1),
    {Es ++ RestEs, Acc}.

%% Is this statement a supervisor start whose value is not used? NotLast: other statements follow it.
start({match, _, {tuple, _, [{atom, _, ok}, {var, _, V}]}, Call}, _NotLast) ->
    case atom_to_list(V) of
        "_" ++ _ -> start_call(Call);
        _ -> no
    end;
start(Call, true) -> start_call(Call);
start(_, _) -> no.

start_call({call, Anno, {remote, _, {atom, _, supervisor}, {atom, _, start_link}}, [_Name, {atom, _, _} = M, Args]}) ->
    {ok, Anno, {M, Args}};
start_call({call, Anno, {remote, _, {atom, _, supervisor}, {atom, _, start_link}}, [{atom, _, _} = M, Args]}) ->
    {ok, Anno, {M, Args}};
start_call(_) -> no.

mark(Anno, #{name := Name, restart := Restart, strategy := Strategy, function := F, args := Args}) ->
    {call, Anno, {remote, Anno, {atom, Anno, e2s_sup}, {atom, Anno, static_child}},
     [{atom, Anno, Name}, {atom, Anno, Restart}, {atom, Anno, Strategy}, {atom, Anno, F},
      lists:foldr(fun(E, T) -> {cons, Anno, E, T} end, {nil, Anno}, Args)]}.

%% The functions that only the supervisor calls go: init/1, and each start function no other code of the module
%% calls. So does the -behaviour attribute: the behaviour has been read.
remove(Forms, StartFunctions) ->
    Gone = [{init, 1} | [FA || FA <- StartFunctions, not called(FA, Forms)]],
    [F || F <- Forms, not gone(F, Gone)].

gone({function, _, N, A, _}, Gone) -> lists:member({N, A}, Gone);
gone({attribute, _, spec, {FA, _}}, Gone) -> lists:member(FA, Gone);
gone({attribute, _, B, supervisor}, _Gone) when B =:= behaviour; B =:= behavior -> true;
gone(_, _) -> false.

called({N, A}, Forms) ->
    lists:any(fun({function, _, _, _, Cs}) -> calls(Cs, N, A); (_) -> false end, Forms).

calls({call, _, {atom, _, N}, Args}, N, A) when length(Args) =:= A -> true;
calls({call, _, {remote, _, _, {atom, _, N}}, Args}, N, A) when length(Args) =:= A -> true;
calls({'fun', _, {function, N, A}}, N, A) -> true;
calls({'fun', _, {function, _, {atom, _, N}, {integer, _, A}}}, N, A) -> true;
calls(T, N, A) when is_tuple(T) -> calls(tuple_to_list(T), N, A);
calls([H | T], N, A) -> calls(H, N, A) orelse calls(T, N, A);
calls(_, _, _) -> false.

%% ------------------------------------------------------------------ reading a supervisor

%% read(Forms, {ModuleAtom, ArgsExpression}) -> {ok, [Child]} | {no, Why}. A child is
%%   #{name, restart, strategy, function, args (abstract literals), start_function => {F, Arity}}.
read(Forms, {{atom, _, M}, ArgsExpr}) ->
    Mod = hd([X || {attribute, _, module, X} <- Forms]),
    try
        M =:= Mod orelse throw(<<"the callback module is another module">>),
        Args = try erl_parse:normalise(ArgsExpr) catch _:_ -> throw(<<"the argument of init/1 is not a literal">>) end,
        [{function, A, init, 1, Clauses}] = [F || F = {function, _, init, 1, _} <- Forms],
        {Flags, Specs} = init(A, Clauses, Args),
        Strategy = strategy(Flags),
        is_list(Specs) orelse throw(<<"init/1 does not answer a list of child specifications">>),
        {ok, [child(spec(S), Strategy, Mod, Forms) || S <- Specs]}
    catch
        throw:Why when is_binary(Why) -> {no, Why}
    end.

%% init/1 evaluated with its argument. It may build and match data; any call ends the reading.
init(A, Clauses, Args) ->
    Call = {call, A, {'fun', A, {clauses, Clauses}}, [erl_parse:abstract(Args)]},
    None = fun(_, _) -> throw(<<"init/1 calls a function: its child list is not read">>) end,
    try erl_eval:expr(Call, erl_eval:new_bindings(), {value, fun(N, As) -> None(N, As) end}, {value, None}) of
        {value, {ok, {Flags, Specs}}, _} -> {Flags, Specs};
        _ -> throw(<<"init/1 does not answer {ok, {SupFlags, ChildSpecs}}">>)
    catch
        throw:Why when is_binary(Why) -> throw(Why);
        _:_ -> throw(<<"init/1 could not be evaluated with the argument of the start">>)
    end.

strategy(#{} = Flags) -> one_of(maps:get(strategy, Flags, one_for_one), [one_for_one, one_for_all, rest_for_one]);
strategy({S, _Intensity, _Period}) -> one_of(S, [one_for_one, one_for_all, rest_for_one]);
strategy(_) -> throw(<<"the supervisor flags are neither a map nor a tuple of three">>).

spec(#{id := Id, start := Start} = S) ->
    maps:get(type, S, worker) =:= worker orelse throw(<<"a child that is a supervisor is not read">>),
    {Id, Start, one_of(maps:get(restart, S, permanent), [permanent, transient, temporary])};
spec({Id, Start, Restart, _Shutdown, worker, _Modules}) ->
    {Id, Start, one_of(Restart, [permanent, transient, temporary])};
spec(_) -> throw(<<"a child specification is not a map with id and start, or the six-element tuple of a worker">>).

one_of(V, Vs) ->
    case lists:member(V, Vs) of
        true -> V;
        false -> throw(<<"a strategy or a restart the contract has no value for (A4.4)">>)
    end.

%% One child: its start function, read with the arguments of its specification.
child({Id, {M, F, As}, Restart}, Strategy, Mod, Forms) when is_atom(F), is_list(As) ->
    M =:= Mod orelse throw(<<"a child's start function is in another module">>),
    Clause = case [Cs || {function, _, N, A, Cs} <- Forms, N =:= F, A =:= length(As)] of
                 [[C]] -> C;
                 _ -> throw(<<"a child's start function is not a function of one clause of this module">>)
             end,
    {clause, _, Params, Guards, Body} = Clause,
    Guards =:= [] orelse throw(<<"a child's start function has a guard">>),
    Bound = maps:from_list(lists:zip([case P of
                                          {var, _, V} -> V;
                                          _ -> throw(<<"a parameter of a child's start function is not a variable">>)
                                      end || P <- Params], As)),
    {Spawn, Registered} = start_body(Body),
    {G, GArgs} = spawned(Spawn, Mod),
    Name = case Registered of none -> Id; _ -> Registered end,
    is_atom(Name) orelse throw(<<"a child has no name: its id is not an atom and it is not registered">>),
    #{name => Name, restart => Restart, strategy => Strategy, function => G,
      args => [literal(A, Bound) || A <- GArgs], start_function => {F, length(As)}};
child(_, _, _, _) -> throw(<<"a child's start is not {Module, Function, Arguments}">>).

%% The body of a start function -> {the spawn_link call, the registered name | none}.
start_body([{tuple, _, [{atom, _, ok}, Spawn = {call, _, _, _}]}]) -> {Spawn, none};
start_body([{match, _, {var, _, P}, Spawn}, {tuple, _, [{atom, _, ok}, {var, _, P}]}]) -> {Spawn, none};
start_body([{match, _, {var, _, P}, Spawn}, Register, {tuple, _, [{atom, _, ok}, {var, _, P}]}]) ->
    {Spawn, registered(Register, P)};
start_body(_) -> throw(<<"a child's start function is not spawn_link, an optional register, {ok, Pid}">>).

registered({match, _, {atom, _, true}, Call}, P) -> registered(Call, P);
registered({call, _, {remote, _, {atom, _, erlang}, F}, Args}, P) -> registered({call, 0, F, Args}, P);
registered({call, _, {atom, _, register}, [{atom, _, Name}, {var, _, P}]}, P) -> Name;
registered(_, _) -> throw(<<"the second statement of a child's start function is not register(Name, Pid)">>).

spawned({call, A, {remote, _, {atom, _, erlang}, F}, Args}, Mod) -> spawned({call, A, F, Args}, Mod);
spawned({call, _, {atom, _, spawn_link}, [{atom, _, Mod}, {atom, _, G}, ArgList]}, Mod) ->
    {G, elements(ArgList)};
spawned({call, _, {atom, _, spawn_link}, [{'fun', _, {clauses, [{clause, _, [], [], [{call, _, {atom, _, G}, Args}]}]}}]}, _Mod) ->
    {G, Args};
spawned(_, _) -> throw(<<"a child's start function does not spawn_link a function of this module">>).

elements({nil, _}) -> [];
elements({cons, _, H, T}) -> [H | elements(T)];
elements(_) -> throw(<<"the argument list of a child's spawn_link is not a literal list">>).

%% An argument of the child's function: a literal, or a parameter of the start function (then the literal the
%% child specification gives for it). The child list is fixed when the supervisor starts: nothing else can be in it.
literal({var, A, V}, Bound) ->
    case Bound of
        #{V := Value} -> scalar(erl_parse:abstract(Value, [{location, A}]));
        _ -> throw(<<"an argument of a child's function is a variable that is no parameter of its start function">>)
    end;
literal(E, _Bound) -> scalar(E).

scalar({op, _, '-', {T, _, _}} = E) when T =:= integer; T =:= float -> E;
scalar({T, _, _} = E) when T =:= integer; T =:= float; T =:= atom -> E;
scalar(_) -> throw(<<"an argument of a child's function is not an integer, a float or an atom">>).
