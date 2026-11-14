%% e2s_split: Erlang's process semantics, lowered by the sender BEFORE anything is sent (abstract forms in, abstract
%% forms out). The transpiler prints what it is told: it writes a receive only in tail position of its function
%% (contract T9.13, T9.13a) and knows nothing of what Erlang does around one. What Erlang does is this sender's
%% business, exactly as every type is (contract 8.6):
%%
%%   code before a receive      runs once, in the new process, when it starts          -> stays where it is
%%   code after a receive       runs in the same process, with the variables it had    -> a CONTINUATION function
%%   several receives           one after the other in the same process                -> one continuation for each
%%   a call of a function that  the caller goes on with its value when it returns      -> a COPY of the callee whose
%%   receives, not in tail pos.                                                           every end calls the continuation
%%   trap_exit + spawn_link     the parent receives {'EXIT', Child, Reason}            -> a LINKED COPY of the child's
%%                                                                                        function that sends it
%%
%% So after this pass every receive, and every call of a function that receives, stands in tail position, and the
%% codex (e2s_codex) sends the pieces as ordinary functions with the contract's high-level nodes: a tail-position
%% (:receive) whose clauses end in a tail (:call) of the next piece. The variables that are live across the cut
%% are the parameters of the continuation; the transpiler keeps them in the waiting process's state.
%%
%%   main() ->                                     main() ->
%%       spawn(actors, supervisor, [self(), 0]),       spawn(actors, supervisor, [self(), 0]),
%%       Counter = receive {child, Pid} -> Pid end,    receive {child, Pid} -> 'main/0-k1'(Pid) end.
%%       Counter ! {add, 2},                       'main/0-k1'(Counter) ->
%%       {Total, Adds, Mean} = ask(Counter),           Counter ! {add, 2},
%%       io:format(...),                               'ask/1-c1'(Counter, Counter).            %% ask, continued in k2
%%       ...                                       'ask/1-c1'(Counter, E2s_k2) ->
%%                                                     Counter ! {get, self()},
%%                                                     'ask/1-c1/2-k1'(E2s_k2).                 %% keeps only E2s_k2
%%                                                 'ask/1-c1/2-k1'(E2s_k2) ->
%%                                                     receive {tally, T, A, M} -> 'main/0-k2'(E2s_k2, {T, A, M})
%%                                                     after 5000 -> exit(no_answer) end.
%%                                                 'main/0-k2'(Counter, E2s_v1) ->
%%                                                     {Total, Adds, Mean} = E2s_v1, io:format(...), ...
%%
%% What this pass makes is Erlang: compiled in place of the module it behaves as the module does (the test
%% split_runs/0 holds it to that). The names 'main/0-k1' are sent as main__k1 (README, N7).
%%
%% forms/1 answers {Forms, Gen}. Gen says, for each function this pass made, what it is made from:
%%   {Name, Arity} => #{base => {Name, Arity}    the function (or made function) it continues or copies
%%                      suffix => binary()       what the codex appends to the base's sent name: __k1, __c1, __l
%%                      result => {Name, Arity}  the source function whose -spec result is this function's result
%%                      what => binary()         for diagnostics}
%% A made function has no -spec: the codex takes its parameter types from the calls of it (e2s_codex, gen_sigs/2).
%%
%% WHAT IS NOT ERLANG'S BEHAVIOUR (README, "Processes: what this sender splits"):
%%   - a receive or a call of a receiving function INSIDE an expression (an argument, a tuple, an operand) is not
%%     split: it becomes this sender's own gap, which says to bind its value with = first;
%%   - the linked copy tells the parent only of an end the source writes: a value (reason normal) or exit(Atom) /
%%     error(Atom) in tail position. A failure the runtime raises (badarith, no clause) sends nothing, the link's
%%     other direction (the parent ends, so the child ends) is not kept, and neither is an exit request's reason.
-module(e2s_split).
-export([forms/1]).

-record(st, {mod, funs = #{}, blocking = #{}, counts = #{}, gen = #{}, out = [], copies = #{}, used = #{},
             cur, idx = 0, tight = false}).

forms(Forms) ->
    Mod = hd([M || {attribute, _, module, M} <- Forms]),
    Fs0 = [F || F = {function, _, _, _, _} <- Forms],
    St0 = #st{mod = Mod, used = maps:from_list([{V, true} || V <- vars_all(Fs0)])},
    {Fs1, St1} = lists:mapfoldl(fun literals/2, St0, Fs0),
    Funs1 = maps:from_list([{{N, A}, Cs} || {function, _, N, A, Cs} <- Fs1]),
    {Fs2, {Linked, St2}} = lists:mapfoldl(fun trap/2, {[], St1#st{funs = Funs1}}, Fs1),
    Funs = maps:from_list([{{N, A}, Cs} || {function, _, N, A, Cs} <- Fs2]),
    St3 = St2#st{funs = Funs, blocking = blocking(Fs2, St2#st{funs = Funs})},
    {Groups, St4} = lists:mapfoldl(fun(F, S) -> group(F, Linked, S) end, St3, Fs2),
    ByName = maps:from_list([{{N, A}, G} || G = [{function, _, N, A, _} | _] <- Groups]),
    Out = lists:flatmap(fun({function, _, N, A, _}) -> maps:get({N, A}, ByName);
                           (Other) -> [Other]
                        end, Forms),
    {Out, St4#st.gen}.

%% One source function and, after it, the functions made while it was split.
group({function, Anno, N, A, Cs}, Linked, St0) ->
    St1 = St0#st{out = [], cur = {N, A}, tight = false},
    {Cs1, St2} = case maps:is_key({N, A}, St1#st.blocking) of
                     true -> split_clauses(Cs, St1);
                     false -> {Cs, St1}
                 end,
    St3 = case lists:member({N, A}, Linked) of
              true -> {_, S} = copy({N, A}, {notify, none}, Anno, St2), S;
              false -> St2
          end,
    {[{function, Anno, N, A, Cs1} | [F || {_, F} <- lists:sort(St3#st.out)]], St3}.

%% ------------------------------------------------------------------ which functions receive

%% A function BLOCKS when it holds a receive, or calls (outside a fun) a function of the module that blocks.
blocking(Fs, St) ->
    B0 = maps:from_list([{{N, A}, true} || {function, _, N, A, Cs} <- Fs, has_receive(Cs)]),
    blocking(Fs, St, B0).

blocking(Fs, St, B) ->
    S = St#st{blocking = B},
    B1 = maps:from_list([{{N, A}, true} || {function, _, N, A, Cs} <- Fs, blocks(Cs, S)]),
    case maps:size(B1) =:= maps:size(B) of
        true -> B;
        false -> blocking(Fs, St, B1)
    end.

has_receive({'receive', _, _}) -> true;
has_receive({'receive', _, _, _, _}) -> true;
has_receive({'fun', _, _}) -> false;
has_receive({named_fun, _, _, _}) -> false;
has_receive(T) when is_tuple(T) -> has_receive(tuple_to_list(T));
has_receive([H | T]) -> has_receive(H) orelse has_receive(T);
has_receive(_) -> false.

%% Does this expression (or list of them) wait for a message somewhere inside it? A fun's body runs when the
%% fun is called, which is not here.
blocks({'receive', _, _}, _St) -> true;
blocks({'receive', _, _, _, _}, _St) -> true;
blocks({'fun', _, _}, _St) -> false;
blocks({named_fun, _, _, _}, _St) -> false;
blocks({call, _, F, Args} = Call, St) -> blocking_call(Call, St) orelse blocks(F, St) orelse blocks(Args, St);
blocks(T, St) when is_tuple(T) -> blocks(tuple_to_list(T), St);
blocks([H | T], St) -> blocks(H, St) orelse blocks(T, St);
blocks(_, _St) -> false.

blocking_call(Call, St) ->
    case callee(Call, St) of
        {ok, FA} -> maps:is_key(FA, St#st.blocking);
        no -> false
    end.

%% The function of this module a call names: {ok, {Name, Arity}} | no.
callee({call, _, {atom, _, F}, Args}, #st{funs = Funs}) ->
    case maps:is_key({F, length(Args)}, Funs) of true -> {ok, {F, length(Args)}}; false -> no end;
callee({call, _, {remote, _, {atom, _, M}, {atom, _, F}}, Args}, #st{mod = M, funs = Funs}) ->
    case maps:is_key({F, length(Args)}, Funs) of true -> {ok, {F, length(Args)}}; false -> no end;
callee(_, _) -> no.

%% ------------------------------------------------------------------ the cut

split_clauses(Cs, St) ->
    lists:mapfoldl(fun({clause, A, Ps, Gs, Body}, S) ->
                           {Body1, S1} = split_body(Body, vars_all(Ps), S),
                           {{clause, A, Ps, Gs, Body1}, S1}
                   end, St, Cs).

%% A body whose last expression is in tail position of its function. Bound: the variables that have a value
%% when the body starts. The first statement that waits is where the function is cut: the statements after it
%% become a continuation function, and the statement becomes the body's last expression.
split_body([E], Bound, St) -> split_tail(E, Bound, St);
split_body([E | Rest], Bound, St) ->
    case blocks(E, St) of
        false -> keep(E, Rest, Bound, St);
        true ->
            case shape(E, St) of
                {P, B} -> cut(P, B, Rest, Bound, St);
                no -> keep(unsplit(E, St), Rest, Bound, St)
            end
    end.

keep(E, Rest, Bound, St) ->
    {Rest1, St1} = split_body(Rest, Bound ++ vars_all(E), St),
    {[E | Rest1], St1}.

%% What can be cut: `P = B` or `B` alone, where B waits and its value is the value of its own tail positions.
shape({match, _, P, B}, St) ->
    case not blocks(P, St) andalso cuttable(B, St) of true -> {P, B}; false -> no end;
shape(B, St) ->
    case cuttable(B, St) of true -> {none, B}; false -> no end.

cuttable({'receive', _, _}, _St) -> true;
cuttable({'receive', _, _, T, _}, St) -> not blocks(T, St);
cuttable({'case', _, S, _}, St) -> not blocks(S, St);
cuttable({'if', _, _}, _St) -> true;
cuttable({block, _, _}, _St) -> true;
cuttable({call, _, _, Args} = C, St) -> blocking_call(C, St) andalso not blocks(Args, St);
cuttable(_, _St) -> false.

%% The last expression of a body: nothing of the function runs after it, so a receive may stand here. Its own
%% bodies are bodies in tail position too.
split_tail(E, Bound, St) when element(1, E) =:= 'receive' ->
    %% The state a waiting process keeps is the sender's business too: the transpiler keeps every variable that
    %% has a value at the receive. In a piece this pass made, a receive that does not use all of them is put in
    %% a function of its own, whose parameters are the variables it does use.
    Used = vars_all(E),
    All = dedupe(Bound),
    Live = [V || V <- All, lists:member(V, Used)],
    case St#st.tight andalso length(Live) < length(All) of
        true ->
            A = element(2, E),
            {Name, St1} = new_name(St#st.cur, "k", length(Live), A,
                                   ["the receive of ", fa(St#st.cur), " at line ", integer_to_list(line(A))], St),
            {Body, St2} = receive_tail(E, Live, St1),
            Fun = {function, A, Name, length(Live), [{clause, A, [{var, A, V} || V <- Live], [], Body}]},
            {[{call, A, {atom, A, Name}, [{var, A, V} || V <- Live]}], push(Name, length(Live), Fun, St2)};
        false -> receive_tail(E, Bound, St)
    end;
split_tail({'case', A, S, Cs} = E, Bound, St) ->
    case blocks(S, St) of
        true -> {[unsplit(E, St)], St};
        false ->
            {Cs1, St1} = tail_clauses(Cs, Bound ++ vars_all(S), St),
            {[{'case', A, S, Cs1}], St1}
    end;
split_tail({'if', A, Cs}, Bound, St) ->
    {Cs1, St1} = tail_clauses(Cs, Bound, St),
    {[{'if', A, Cs1}], St1};
split_tail({block, A, Es}, Bound, St) ->
    {Es1, St1} = split_body(Es, Bound, St),
    {[{block, A, Es1}], St1};
split_tail({match, _, _, _} = E, Bound, St) ->
    case {blocks(E, St), shape(E, St)} of
        {false, _} -> {[E], St};
        {true, {P, B}} -> cut(P, B, [], Bound, St);
        {true, no} -> {[unsplit(E, St)], St}
    end;
split_tail({call, _, F, Args} = E, _Bound, St) ->
    %% a tail call of a function that receives is what the contract asks for (T9.13); its arguments must not wait
    case blocks(F, St) orelse blocks(Args, St) of
        true -> {[unsplit(E, St)], St};
        false -> {[E], St}
    end;
split_tail(E, _Bound, St) ->
    case blocks(E, St) of
        true -> {[unsplit(E, St)], St};
        false -> {[E], St}
    end.

receive_tail({'receive', A, Cs}, Bound, St) ->
    {Cs1, St1} = tail_clauses(Cs, Bound, St),
    {[{'receive', A, Cs1}], St1};
receive_tail({'receive', A, Cs, T, After} = E, Bound, St) ->
    case blocks(T, St) of
        true -> {[unsplit(E, St)], St};
        false ->
            {Cs1, St1} = tail_clauses(Cs, Bound, St),
            {After1, St2} = split_body(After, Bound, St1),
            {[{'receive', A, Cs1, T, After1}], St2}
    end.

tail_clauses(Cs, Bound, St) ->
    lists:mapfoldl(fun({clause, A, Ps, Gs, Body}, S) ->
                           {Body1, S1} = split_body(Body, Bound ++ vars_all(Ps), S),
                           {{clause, A, Ps, Gs, Body1}, S1}
                   end, St, Cs).

%% `P = B, Rest` (P none: `B, Rest`): B becomes the last expression, every value B can have is passed to the
%% continuation K, and K is `K(Live..., Value) -> P = Value, Rest`. Live: the variables Rest uses that have a
%% value where B ends (bound before B, or bound by B in every one of its branches, which Erlang requires).
cut(P, B, Rest, Bound, St0) ->
    A = element(2, B),
    {Value, KBody, St1} =
        case P of
            none -> {none, Rest, St0};
            {var, _, '_'} when Rest =/= [] -> {none, Rest, St0};
            {var, _, V} when V =/= '_' ->
                case lists:member(V, Bound) of
                    false -> {V, case Rest of [] -> [P]; _ -> Rest end, St0};
                    true -> value_var(A, P, Rest, St0)
                end;
            _ -> value_var(A, P, Rest, St0)
        end,
    InK = vars_all(KBody),
    Live = [V || V <- dedupe(Bound ++ vars_all(B)), lists:member(V, InK), V =/= Value],
    Params = Live ++ [Value || Value =/= none],
    {Name, St2} = new_name(St1#st.cur, "k", length(Params), A,
                           ["the code of ", fa(St1#st.cur), " after line ", integer_to_list(line(A))], St1),
    K = {cont, Name, [{var, A, V} || V <- Live], Value =/= none},
    {B1, St3} = wrap_last(B, K, St2),
    {B2, St4} = split_body(B1, Bound, St3),
    {KBody1, St5} = split_body(KBody, Params, St4#st{tight = true}),
    Fun = {function, A, Name, length(Params), [{clause, A, [{var, A, V} || V <- Params], [], KBody1}]},
    {B2, push(Name, length(Params), Fun, St5#st{tight = St4#st.tight})}.

value_var(A, P, Rest, St0) ->
    {V, St1} = fresh("v", St0),
    {V, [{match, A, P, {var, A, V}} | Rest], St1}.

%% A receive this pass does not cut: it stands inside an expression. It is sent as this sender's own gap.
unsplit(E, _St) ->
    A = element(2, E),
    What = case has_receive(E) of
               true -> "receive inside an expression";
               false -> "call of a function that receives, inside an expression"
           end,
    {call, A, {atom, A, '$e2s_gap'},
     [{string, A, What},
      {string, A, "this sender cuts a function at a receive, or at a call of a function that receives, that is a "
                  "statement or the right side of =, also inside the clauses of case, if and receive (contract "
                  "T9.13a): bind its value to a variable with = first"}]}.

%% ------------------------------------------------------------------ passing a value on

%% The expression E is the last of a body; K says what happens with its value:
%%   {cont, Name, Args, true}    Name(Args..., Value)          a continuation that uses the value
%%   {cont, Name, Args, false}   Value, Name(Args...)          a continuation that does not
%%   {notify, Parent}            Parent ! {'EXIT', self(), normal}, Value     the end of a linked child
%% Answers the expressions that take E's place.
wrap_last({'receive', A, Cs}, K, St) ->
    {Cs1, St1} = wrap_clauses(Cs, K, St),
    {[{'receive', A, Cs1}], St1};
wrap_last({'receive', A, Cs, T, After}, K, St) ->
    {Cs1, St1} = wrap_clauses(Cs, K, St),
    {After1, St2} = wrap_body(After, K, St1),
    {[{'receive', A, Cs1, T, After1}], St2};
wrap_last({'case', A, S, Cs}, K, St) ->
    {Cs1, St1} = wrap_clauses(Cs, K, St),
    {[{'case', A, S, Cs1}], St1};
wrap_last({'if', A, Cs}, K, St) ->
    {Cs1, St1} = wrap_clauses(Cs, K, St),
    {[{'if', A, Cs1}], St1};
wrap_last({block, A, Es}, K, St) ->
    {Es1, St1} = wrap_body(Es, K, St),
    {[{block, A, Es1}], St1};
wrap_last({call, A, _, Args} = E, K, St) ->
    case {blocking_call(E, St) andalso not blocks(Args, St), fail_call(E)} of
        {true, _} ->
            %% the callee receives: a copy of it goes on in K when it ends
            {ok, FA} = callee(E, St),
            {Name, St1} = copy(FA, K, A, St),
            {[{call, A, {atom, A, Name}, Args ++ kargs(K)}], St1};
        {false, true} -> {failing(E, K), St};
        {false, false} -> value(E, K, St)
    end;
wrap_last(E, K, St) -> value(E, K, St).

wrap_body(Es, K, St) ->
    {Last, St1} = wrap_last(lists:last(Es), K, St),
    {lists:droplast(Es) ++ Last, St1}.

wrap_clauses(Cs, K, St) ->
    lists:mapfoldl(fun({clause, A, Ps, Gs, Body}, S) ->
                           {Body1, S1} = wrap_body(Body, K, S),
                           {{clause, A, Ps, Gs, Body1}, S1}
                   end, St, Cs).

kargs({cont, _, Args, _}) -> Args;
kargs({notify, Parent}) -> [Parent].

value(E, {cont, Name, Args, true}, St) ->
    A = element(2, E),
    {[{call, A, {atom, A, Name}, Args ++ [E]}], St};
value(E, {cont, Name, Args, false}, St) ->
    A = element(2, E),
    Call = {call, A, {atom, A, Name}, Args},
    {case simple(E) of true -> [Call]; false -> [E, Call] end, St};
value(E, {notify, Parent}, St) ->
    A = element(2, E),
    Send = exit_message(A, Parent, {atom, A, normal}),
    case simple(E) of
        true -> {[Send, E], St};
        false ->
            {V, St1} = fresh("r", St),
            {[{match, A, {var, A, V}, E}, Send, {var, A, V}], St1}
    end.

%% exit(Reason), error(Reason), throw(Reason): the process ends here, no continuation runs. A linked child tells
%% its parent the reason when it is written as an atom.
failing({call, A, _, [{atom, _, _} = Reason]} = E, {notify, Parent}) -> [exit_message(A, Parent, Reason), E];
failing(E, _K) -> [E].

fail_call({call, _, {atom, _, F}, [_]}) -> lists:member(F, [exit, error, throw]);
fail_call({call, _, {remote, _, {atom, _, erlang}, {atom, _, F}}, [_]}) -> lists:member(F, [exit, error, throw]);
fail_call(_) -> false.

exit_message(A, Parent, Reason) ->
    {op, A, '!', Parent, {tuple, A, [{atom, A, 'EXIT'}, {call, A, {atom, A, self}, []}, Reason]}}.

simple(E) -> lists:member(element(1, E), [var, atom, integer, float, char, string, nil]).

%% ------------------------------------------------------------------ copies

%% The copy of the function FA whose every end goes on as K says. Its extra parameters carry what K needs (the
%% continuation's live variables, or the parent of a linked child). One copy for each (function, K): a function
%% that loops calls its own copy.
copy(FA = {_G, N}, K, A, St0) ->
    Key = {FA, case K of {cont, KName, _, _} -> KName; {notify, _} -> notify end},
    case St0#st.copies of
        #{Key := Name} -> {Name, St0};
        _ ->
            NExtra = length(kargs(K)),
            {Extra, St1} = lists:mapfoldl(fun(_, S) -> fresh("k", S) end, St0, lists:seq(1, NExtra)),
            Arity = N + NExtra,
            {Name, St2} = case K of
                              {cont, KName1, _, _} ->
                                  new_name(FA, "c", Arity, A, [fa(FA), " going on in ", what(KName1, St1)], St1);
                              {notify, _} ->
                                  {linked_name(FA), linked_gen(FA, St1)}
                          end,
            St3 = St2#st{copies = (St2#st.copies)#{Key => Name}},
            Cur = St3#st.cur,
            {Cs, St4} =
                lists:mapfoldl(
                  fun({clause, CA, Ps, Gs, Body}, S) ->
                          Vars = [{var, CA, V} || V <- Extra],
                          K1 = case K of
                                   {cont, KN, _, Use} -> {cont, KN, Vars, Use};
                                   {notify, _} -> {notify, hd(Vars)}
                               end,
                          {B1, S1} = wrap_body(Body, K1, S),
                          {B2, S2} = split_body(B1, vars_all(Ps) ++ Extra, S1),
                          {{clause, CA, Ps ++ Vars, Gs, B2}, S2}
                  end, St3#st{cur = {Name, Arity}, tight = true}, maps:get(FA, St3#st.funs)),
            {Name, push(Name, Arity, {function, A, Name, Arity, Cs}, St4#st{cur = Cur, tight = St3#st.tight})}
    end.

linked_name({G, N}) -> list_to_atom(lists:flatten(io_lib:format("~s/~b-l", [G, N]))).

linked_gen(FA = {_, N}, St = #st{gen = Gen, idx = I}) ->
    St#st{idx = I + 1,
          gen = Gen#{{linked_name(FA), N + 1} =>
                         #{base => FA, suffix => <<"__l">>, result => FA, idx => I,
                           what => iolist_to_binary([fa(FA), " as a linked child (it sends its parent {'EXIT', "
                                                     "self(), Reason} when it ends)"])}}}.

%% ------------------------------------------------------------------ names

new_name(Base = {N, Ar}, Letter, Arity, _A, What, St = #st{counts = Counts, gen = Gen, idx = I}) ->
    Count = maps:get({Base, Letter}, Counts, 0) + 1,
    Name = list_to_atom(lists:flatten(io_lib:format("~s/~b-~s~b", [N, Ar, Letter, Count]))),
    %% the result is the -spec result of the source function all this is cut from: for a copy, the one its
    %% continuation belongs to
    From = case Letter of "c" -> St#st.cur; _ -> Base end,
    Result = case Gen of
                 #{From := #{result := R}} -> R;
                 _ -> From
             end,
    Info = #{base => Base, suffix => iolist_to_binary(["__", Letter, integer_to_list(Count)]), result => Result,
             idx => I, what => iolist_to_binary(What)},
    {Name, St#st{counts = Counts#{{Base, Letter} => Count}, gen = Gen#{{Name, Arity} => Info}, idx = I + 1}}.

push(Name, Arity, Fun, St = #st{out = Out, gen = Gen}) ->
    #{idx := I} = maps:get({Name, Arity}, Gen),
    St#st{out = [{I, Fun} | Out]}.

what(Name, #st{gen = Gen}) ->
    case [W || {{N, _}, #{what := W}} <- maps:to_list(Gen), N =:= Name] of
        [W | _] -> W;
        [] -> atom_to_list(Name)
    end.

fa({N, A}) -> [atom_to_list(N), "/", integer_to_list(A)].

line(A) -> erl_anno:line(A).

%% A variable of this pass: E2s_<letter><n>, a name no variable of the module has.
fresh(Letter, St = #st{used = Used}) -> fresh(Letter, 1, Used, St).

fresh(Letter, N, Used, St) ->
    V = list_to_atom("E2s_" ++ Letter ++ integer_to_list(N)),
    case maps:is_key(V, Used) of
        true -> fresh(Letter, N + 1, Used, St);
        false -> {V, St#st{used = Used#{V => true}}}
    end.

%% Every variable that occurs in a term, in order of first occurrence.
vars_all(T) -> dedupe(lists:reverse(vars(T, []))).

vars({var, _, V}, Acc) when is_atom(V), V =/= '_' -> [V | Acc];
vars(T, Acc) when is_tuple(T) -> vars(tuple_to_list(T), Acc);
vars([H | T], Acc) -> vars(T, vars(H, Acc));
vars(_, Acc) -> Acc.

dedupe(L) -> dedupe(L, #{}).
dedupe([], _) -> [];
dedupe([H | T], Seen) ->
    case maps:is_key(H, Seen) of
        true -> dedupe(T, Seen);
        false -> [H | dedupe(T, Seen#{H => true})]
    end.

%% ------------------------------------------------------------------ trapping exits

%% process_flag(trap_exit, true) as a statement of a function body, and after it in that body:
%%   spawn_link(fun() -> g(Args) end)     -> begin E2s_s1 = self(), spawn(fun() -> 'g/n-l'(Args, E2s_s1) end) end
%%   spawn_link(Mod, g, [Args])              (the parent is bound first; Args are evaluated by the spawner: T9.14)
%%   receive {'EXIT', P, R} -> ...        -> the pattern's variables get the types of the message the linked copy
%%                                           sends (a pid and an atom) as type-test guards; a variable that has a
%%                                           value already is compared with a guard (the transpiler binds every
%%                                           pattern variable anew)
%% The statement itself is dropped. A process_flag anywhere else stays, and is a gap.
trap({function, A, N, Ar, Cs}, {Linked0, St0}) ->
    {Cs1, {Linked, St}} =
        lists:mapfoldl(
          fun({clause, CA, Ps, Gs, Body} = C, {L, S}) ->
                  case lists:splitwith(fun(E) -> not trap_flag(E) end, Body) of
                      {_, []} -> {C, {L, S}};
                      {_, [_Flag]} -> {C, {L, S}};          %% its value is the function's: left as it is
                      {Before, [_Flag | After]} ->
                          Where = positions(C),
                          {After1, Acc} = rewrite(After, Where, {L, S}),
                          {{clause, CA, Ps, Gs, Before ++ After1}, Acc}
                  end
          end, {Linked0, St0}, Cs),
    {{function, A, N, Ar, Cs1}, {lists:usort(Linked), St}}.

trap_flag({call, _, {atom, _, process_flag}, [{atom, _, trap_exit}, {atom, _, true}]}) -> true;
trap_flag({call, _, {remote, _, {atom, _, erlang}, {atom, _, process_flag}}, [{atom, _, trap_exit}, {atom, _, true}]}) -> true;
trap_flag(_) -> false.

%% Every occurrence of a variable in a clause with its place: a variable has a value at a place when it occurs
%% before it.
positions(T) -> positions(T, []).
positions({var, A, V}, Acc) when is_atom(V), V =/= '_' -> [{V, erl_anno:location(A)} | Acc];
positions(T, Acc) when is_tuple(T) -> positions(tuple_to_list(T), Acc);
positions([H | T], Acc) -> positions(T, positions(H, Acc));
positions(_, Acc) -> Acc.

rewrite({call, A, F, [{'fun', FA, {clauses, [{clause, CA, [], [], [Call]}]}}]} = E, Where, {L, S}) ->
    case {spawn_link_name(F), callee(Call, S)} of
        {true, {ok, G}} ->
            {Spawn, S1} = linked_spawn(A, FA, CA, G, element(4, Call), S),
            {Spawn, {[G | L], S1}};
        _ -> rewrite_inside(E, Where, {L, S})
    end;
rewrite({call, A, F, [{atom, _, M}, {atom, _, G}, ArgList]} = E, Where, {L, S = #st{mod = Mod}}) ->
    case {spawn_link_name(F), M =:= Mod, elements(ArgList)} of
        {true, true, {ok, Args}} ->
            case maps:is_key({G, length(Args)}, S#st.funs) of
                true ->
                    {Spawn, S1} = linked_spawn(A, A, A, {G, length(Args)}, Args, S),
                    {Spawn, {[{G, length(Args)} | L], S1}};
                false -> rewrite_inside(E, Where, {L, S})
            end;
        _ -> rewrite_inside(E, Where, {L, S})
    end;
rewrite({'receive', A, Cs}, Where, Acc0) ->
    {Cs1, Acc1} = exit_clauses(Cs, erl_anno:location(A), Where, Acc0),
    {Cs2, Acc2} = rewrite(Cs1, Where, Acc1),
    {{'receive', A, Cs2}, Acc2};
rewrite({'receive', A, Cs, T, After}, Where, Acc0) ->
    {Cs1, Acc1} = exit_clauses(Cs, erl_anno:location(A), Where, Acc0),
    {Cs2, Acc2} = rewrite(Cs1, Where, Acc1),
    {After1, Acc3} = rewrite(After, Where, Acc2),
    {{'receive', A, Cs2, T, After1}, Acc3};
rewrite(E, Where, Acc) -> rewrite_inside(E, Where, Acc).

rewrite_inside(T, Where, Acc0) when is_tuple(T) ->
    {L, Acc1} = rewrite_inside(tuple_to_list(T), Where, Acc0),
    {list_to_tuple(L), Acc1};
rewrite_inside([H | T], Where, Acc0) ->
    {H1, Acc1} = rewrite(H, Where, Acc0),
    {T1, Acc2} = rewrite_inside(T, Where, Acc1),
    {[H1 | T1], Acc2};
rewrite_inside(Other, _Where, Acc) -> {Other, Acc}.

spawn_link_name({atom, _, spawn_link}) -> true;
spawn_link_name({remote, _, {atom, _, erlang}, {atom, _, spawn_link}}) -> true;
spawn_link_name(_) -> false.

%% The parent is bound before the spawn: inside the fun, self() would be the child in Erlang (the contract's
%% spawn evaluates the call's arguments in the spawner, T9.14; written this way both mean the same).
linked_spawn(A, FA, CA, G, Args, S0) ->
    {V, S1} = fresh("s", S0),
    Call = {call, CA, {atom, CA, linked_name(G)}, Args ++ [{var, CA, V}]},
    {{block, A, [{match, A, {var, A, V}, {call, A, {atom, A, self}, []}},
                 {call, A, {atom, A, spawn}, [{'fun', FA, {clauses, [{clause, CA, [], [], [Call]}]}}]}]},
     S1}.

elements({nil, _}) -> {ok, []};
elements({cons, _, H, T}) ->
    case elements(T) of {ok, Es} -> {ok, [H | Es]}; error -> error end;
elements(_) -> error.

exit_clauses(Cs, At, Where, Acc) ->
    lists:mapfoldl(fun(C, Acc1) -> exit_clause(C, At, Where, Acc1) end, Acc, Cs).

exit_clause({clause, A, [{tuple, TA, [{atom, _, 'EXIT'} = Tag, P1, P2]}], Gs, Body}, At, Where, {L, S0}) ->
    {Q1, T1, S1} = exit_part(P1, is_pid, At, Where, S0),
    {Q2, T2, S2} = exit_part(P2, is_atom, At, Where, S1),
    Tests = T1 ++ T2,
    Gs1 = case {Tests, Gs} of
              {[], _} -> Gs;
              {_, []} -> [Tests];
              _ -> [Tests ++ G || G <- Gs]
          end,
    {{clause, A, [{tuple, TA, [Tag, Q1, Q2]}], Gs1, Body}, {L, S2}};
exit_clause(C, _At, _Where, Acc) -> {C, Acc}.

%% One element of an {'EXIT', Pid, Reason} pattern: {Pattern, GuardTests, St}.
exit_part({var, A, '_'}, Test, _At, _Where, S0) ->
    {V, S1} = fresh("x", S0),
    {{var, A, V}, [type_test(A, Test, V)], S1};
exit_part({var, A, V} = P, Test, At, Where, S0) ->
    case [x || {W, Loc} <- Where, W =:= V, Loc < At] of
        [] -> {P, [type_test(A, Test, V)], S0};
        _ ->
            {X, S1} = fresh("x", S0),
            {{var, A, X}, [type_test(A, Test, X), {op, A, '=:=', {var, A, X}, P}], S1}
    end;
exit_part(P, _Test, _At, _Where, S) -> {P, [], S}.

type_test(A, Test, V) -> {call, A, {atom, A, Test}, [{var, A, V}]}.

%% ------------------------------------------------------------------ literals in record patterns

%% f(#r{a = 0}) -> ...   becomes   f(#r{a = E2s_p1}) when E2s_p1 =:= 0 -> ...   in function and case clauses: the
%% transpiler prints a record pattern whose fields are variables (it reads them from the matched value), and a
%% pattern literal is Erlang's exact comparison.
literals({function, A, N, Ar, Cs}, St0) ->
    {Cs1, St1} = lit_clauses(Cs, St0),
    {{function, A, N, Ar, Cs1}, St1}.

lit_clauses(Cs, St) -> lists:mapfoldl(fun lit_clause/2, St, Cs).

lit_clause({clause, A, Ps, Gs, Body}, St0) ->
    {Ps1, {Tests, St1}} = lit_patterns(Ps, {[], St0}),
    {Body1, St2} = lit_body(Body, St1),
    Gs1 = case {Tests, Gs} of
              {[], _} -> Gs;
              {_, []} -> [lists:reverse(Tests)];
              _ -> [lists:reverse(Tests) ++ G || G <- Gs]
          end,
    {{clause, A, Ps1, Gs1, Body1}, St2}.

lit_patterns({record, A, Name, Fields}, Acc0) ->
    {Fields1, Acc1} =
        lists:mapfoldl(
          fun({record_field, FA, {atom, _, _} = F, Lit} = Field, {Tests, S}) ->
                  case literal(Lit) of
                      true ->
                          {V, S1} = fresh("p", S),
                          {{record_field, FA, F, {var, FA, V}}, {[{op, FA, '=:=', {var, FA, V}, Lit} | Tests], S1}};
                      false ->
                          {P1, Acc} = lit_patterns(element(4, Field), {Tests, S}),
                          {{record_field, FA, F, P1}, Acc}
                  end;
             (Field, Acc) -> {Field, Acc}
          end, Acc0, Fields),
    {{record, A, Name, Fields1}, Acc1};
lit_patterns(T, Acc0) when is_tuple(T) ->
    {L, Acc1} = lit_patterns(tuple_to_list(T), Acc0),
    {list_to_tuple(L), Acc1};
lit_patterns([H | T], Acc0) ->
    {H1, Acc1} = lit_patterns(H, Acc0),
    {T1, Acc2} = lit_patterns(T, Acc1),
    {[H1 | T1], Acc2};
lit_patterns(Other, Acc) -> {Other, Acc}.

literal({Kind, _, _}) when Kind =:= integer; Kind =:= float; Kind =:= char; Kind =:= atom -> true;
literal({op, _, '-', {Kind, _, _}}) when Kind =:= integer; Kind =:= float -> true;
literal(_) -> false.

%% The case expressions inside a body (not inside a fun: its clauses are typed by the place it is passed to).
lit_body({'case', A, S, Cs}, St0) ->
    {S1, St1} = lit_body(S, St0),
    {Cs1, St2} = lit_clauses(Cs, St1),
    {{'case', A, S1, Cs1}, St2};
lit_body({'fun', _, _} = F, St) -> {F, St};
lit_body({clause, A, Ps, Gs, Body}, St0) ->
    {Body1, St1} = lit_body(Body, St0),
    {{clause, A, Ps, Gs, Body1}, St1};
lit_body(T, St0) when is_tuple(T) ->
    {L, St1} = lit_body(tuple_to_list(T), St0),
    {list_to_tuple(L), St1};
lit_body([H | T], St0) ->
    {H1, St1} = lit_body(H, St0),
    {T1, St2} = lit_body(T, St1),
    {[H1 | T1], St2};
lit_body(Other, St) -> {Other, St}.
