%% e2s_codex: the inbound codex of erlang-to-silica-poc. Erlang source -> the frames of the to-silica TCP transport
%% contract, version 1 (../contract/tcp-transport-v1.md; rule ids such as T9.2 and node ids such as H21 are cited).
%%
%% Parsing is Erlang's own: epp:parse_file/2 gives the abstract forms (the parser is the gate: nothing is sent
%% unless it succeeded). This module maps those forms to the contract's forms and node tables, and it DECIDES
%% EVERY TYPE AND EVERY NUMERIC CONVERSION (contract 8.6): the transpiler infers nothing and converts nothing.
%%
%% Scope of the proof of concept (everything else is sent as a gap, T9.10, so a session always completes):
%%   in:  integers, floats, atoms, booleans, <<"bytes">> literals, tuples, lists and strings, records, variables, =,
%%        alias patterns, functions with clauses, patterns and guards, local and remote calls, operators, case,
%%        if, funs, begin..end, self(), spawn/1,3, spawn_link/1,3, !, receive (with after), link/1, exit/1,2,
%%        error/1, float/1, trunc/1, round/1, -spec, -record, -type without parameters; io:format with a
%%        literal format (as L1 calls of Silica's print builtins, contract T9.16).
%%   Erlang's process semantics are lowered BEFORE this module types anything, by e2s_split (contract T9.13a): a
%%        receive with code after it, several receives, a call of a function that receives, trap_exit with
%%        spawn_link. This module sends the functions e2s_split made like any other (gen_sigs/2 types them).
%%   OTP's supervisor behaviour is read before that, by e2s_sup: a supervisor start becomes the static children
%%        of contract T9.14b ((:register) of a (:spawn), with an A4.4 override); `Name ! Message` with a literal
%%        name is H39 (:send_named).
%%   out: maps, bit syntax, comprehensions, try/catch, macros beyond what epp expands, the other OTP behaviours,
%%        register/2 and whereis/1 outside a supervisor's start function, process_flag/2, monitors, and
%%        everything that reaches another node.
%%   A construct whose type the contract requires (T8.10) and Erlang does not give (no -spec, term(), number(),
%%   an untyped message) is sent as a gap whose note says which type is missing and why. Never an untyped node.
%%
%% Layout of this module, and where to extend it (README, "Extending this sender"):
%%   frames/2,3, hello/2, choices/0 the session: M1, then M2 M3... M4 per file, then M5
%%   scan/1, session/1              the pre-pass over every file: declared types, every function's -spec, which
%%                                  names have several arities. The typing pass reads only this and the form.
%%   unit/3, function/3             top-level forms (contract 9.3): type forms first (T8.14), then the rest
%%   names                          ident/1, fname/4, snake/1, unit_ident/1, type_name/2 (README, "Names")
%%   ty/2                           an Erlang type (-spec, -record, -type) -> the codex's own type term
%%   why/2, compat/3, join/1, fit/3 questions about type terms: can it be stated, does it fit, the common type
%%   intern/2, hint/3, node/5       type term -> the form's type table (contract 8.5); a hint on a node (8.4)
%%   pattern/5                      patterns: binds variables with the type of what they are matched with
%%   expr/3                         expr(Abstract, ExpectedType, Builder) -> {NodeIndex, Type, Builder}: one
%%                                  clause group per node family, in the contract's order (9.4)
%%   arith/5, fdiv/4, compare/5     the operators: where Erlang converts a number, a to_float node is written
%%                                  (T8.12); float division gets its zero guard (T8.15)
%%   call/5, bif_type/3             erlang:F built-ins with a node of their own; the results of known functions
%%   gen_sigs/2, fsig/2             the signatures of the functions e2s_split made, from the calls of them
%%   io_format/4                    io:format with a literal format -> (:sl_call) of print builtins (T9.16)
%%   gap/4                          H40: what to call for anything not translated or not typed. Never drop one.
%% Every function that builds nodes takes the builder #b{} last and returns the node's index first: build the
%% children first, then emit/4 the node, so children always have lower indices than their parent (T9.2). The
%% builder is a value: to give up on a construct after building part of it, go back to the builder you had before
%% it (every gap is emitted that way, so a frame never holds an orphan node).
-module(e2s_codex).
-export([file/1, file/2, frames/2, frames/3, hello/1, hello/2, choices/0, ident/1, snake/1, unit_ident/1]).

%% env: what the typing pass may look at. s is the session map of session/1.
-record(env, {file, mod, id, s, remotes = #{}}).
%% b: the builder of one function form. vars: variable -> {Type, Strength}. types/tmap: the type table and its
%% index. hints: node -> type index. decl: nodes whose type comes only from a -spec or -record (T8.2 :declared).
-record(b, {nodes = [], n = 0, locs = [], env, vars = #{}, types = [], tn = 0, tmap = #{}, hints = #{},
            decl = #{}, tmp = 0, guard = false, overrides = []}).

-define(PREFIX, <<"erl_">>).
-define(MESSAGE, {unknown, <<"a received message has no declared type in Erlang (give each variable the clause "
                             "binds a type-test guard such as is_integer(N))">>}).
-define(FUN_PARAM, {unknown, <<"the parameters of an Erlang fun carry no type (pass the fun where a -spec states "
                               "a fun type, or give each parameter a type-test guard)">>}).

%% ------------------------------------------------------------------ the session (contract 5, 6)

%% The frames of a whole session for these source files: hello, then per file unit_begin, forms, unit_end, then end.
%% Mode is check | transpile (contract 6.5). Session is <<>> for a new session, or the id of one to resume (T6.5).
frames(Files, Mode) -> frames(Files, Mode, <<>>).
frames(Files, Mode, Session) ->
    Mods = [scan(F) || F <- Files],
    S = session(Mods),
    {Units, Seq} = lists:mapfoldl(fun(M, Seq0) -> U = unit(M, S, Seq0), {U, Seq0 + length(U)} end, 0, Mods),
    [hello(Mode, Session)] ++ lists:append(Units) ++ [{'end', #{seq => Seq, units => length(Files)}}].

%% M1. A :bees session: one choice for each BEES requirement (T7.1), the recommended hint policy (T8.4).
hello(Mode) -> hello(Mode, <<>>).
hello(Mode, Session) ->
    {hello, #{contract => 1,
              session => Session,
              sender => #{language => <<"erlang">>, prefix => ?PREFIX,
                          codex => <<"erlang-to-silica-poc">>, codex_version => <<"0.2.0">>},
              options => #{profile => bees,
                           choices => choices(),
                           hints => #{proven => trust, declared => check, inferred => check},
                           run => #{mode => Mode, max_frame => 1048576}}}}.

choices() ->
    [choice(a3_2, default, [{<<"release">>, <<"release_on_return">>}]),
     choice(a3_3, phase_field, []),
     choice(a3_4, back_edge, []),
     choice(a4_2, single_pool, [{<<"pool_size">>, <<"1024">>}]),
     choice(a4_3, uniform_shape, []),
     choice(a4_4, chosen, [{<<"restart">>, <<"transient">>}, {<<"strategy">>, <<"one_for_one">>}]),
     choice(a5_1, result_values, []),
     choice(a5_4, accept_sender_death, []),
     choice(a5_5, supervisor_request, []),
     choice(a6_8, lookup_tables, []),
     choice(a7_1, module_table, [])].

choice(Requirement, Choice, Params) ->
    #{requirement => Requirement, choice => Choice, params => Params, note => <<>>}.

%% The frames of one unit (M2, M3..., M4), numbered from Seq0 (T5.1), as a session of that file alone.
file(File) -> file(File, 0).
file(File, Seq0) ->
    M = scan(File),
    unit(M, session([M]), Seq0).

%% One source file, parsed.
scan(File) ->
    {ok, Forms} = epp:parse_file(File, [{location, {1, 1}}]),
    case [E || {error, E} <- Forms] of
        [] -> ok;
        Errors -> erlang:error({does_not_parse, File, Errors})
    end,
    Module = hd([M || {attribute, _, module, M} <- Forms]),
    %% Erlang's process semantics are lowered here, before anything is typed or sent (e2s_split): every receive
    %% and every call of a function that receives is put in tail position of a function (contract T9.13a).
    %% OTP's supervisor behaviour is read first (e2s_sup): a supervisor start becomes its static children
    %% (contract T9.14b), and init/1 and the children's start functions are not sent.
    {Split, Gen} = e2s_split:forms(e2s_sup:forms(Forms)),
    #{file => unicode:characters_to_binary(filename:basename(File)), mod => Module,
      id => unit_ident(atom_to_binary(Module)), forms => Split, gen => Gen}.

%% What the typing pass knows about the whole session (the sender sees every module it sends):
%%   defs   type name (N3) -> {record, Record, [{Field, Type}]} | {alias, Type}
%%   bad    type name -> why no (:type) form can be sent for it; a use of such a type has no type
%%   funs   {Module, Name, Arity} -> {ok, ParameterTypes, ResultType} | {no, WhyAsAPredicate}
%%   multi  {Module, Name} -> true, for a name defined at more than one arity (README, "Names": the arity suffix)
session(Mods) ->
    {Defs, Bad0} = lists:foldl(fun defs/2, {#{}, #{}}, Mods),
    S0 = #{defs => Defs, bad => bad(Defs, Bad0)},
    Gen = maps:from_list([{{Mod, N, A}, Info} || #{mod := Mod, gen := G} <- Mods, {{N, A}, Info} <- maps:to_list(G)]),
    Funs = maps:from_list([{{Mod, N, A}, case maps:find({Mod, N, A}, Gen) of
                                             {ok, #{result := {RN, RA}}} -> {gen, {Mod, RN, RA}};
                                             error -> sig(maps:find({N, A}, specs(Forms)), Id, S0)
                                         end}
                           || #{mod := Mod, id := Id, forms := Forms} <- Mods, {function, _, N, A, _} <- Forms]),
    Names = [{Mod, N} || {Mod, N, A} <- maps:keys(Funs), not maps:is_key({Mod, N, A}, Gen)],
    Multi = maps:from_list([{K, true} || K <- Names -- lists:usort(Names)]),
    S0#{funs => Funs, multi => Multi, gen => Gen}.

%% The signature of a function of the session: {ok, ParameterTypes, Result} | {no, Why} for a source function
%% (its -spec), and for a function e2s_split made (it has no -spec):
%%   {made, ParameterTypes, Result}   its parameters have the types of the arguments of the calls of it
%%   {pending, Result}                no call of it has been typed yet (gen_sigs/2 is still collecting)
%% Its result is the -spec result of the source function it continues.
fsig(MFA, #{funs := Funs}) ->
    case maps:get(MFA, Funs, {no, <<"is not defined in its module">>}) of
        {gen, Root} ->
            case maps:get(Root, Funs) of
                {ok, _, R} ->
                    case get({e2s_made, MFA}) of
                        undefined -> {pending, R};
                        Ps -> {made, Ps, R}
                    end;
                {no, Why} -> {no, note(["continues ", atom_to_binary(element(2, Root)), "/",
                                        integer_to_binary(element(3, Root)), ", which ", Why])}
            end;
        Sig -> Sig
    end.

specs(Forms) -> maps:from_list([{FA, Sigs} || {attribute, _, spec, {FA = {_, _}, Sigs}} <- Forms]).

defs(#{id := Id, forms := Forms}, Acc0) ->
    Records = [{type_name(Id, N), {record, N, [{field_name(F), record_field_type(F, N, Id)} || F <- Fs]}}
               || {attribute, _, record, {N, Fs}} <- Forms],
    Acc1 = lists:foldl(fun({Name, Def}, {Ds, Bs}) -> {Ds#{Name => Def}, Bs} end, Acc0, Records),
    lists:foldl(
      fun({attribute, _, Kind, {N, T, Params}}, {Ds, Bs}) when Kind =:= type; Kind =:= opaque; Kind =:= nominal ->
              Name = type_name(Id, N),
              case {Params, maps:is_key(Name, Ds)} of
                  {[], false} -> {Ds#{Name => {alias, ty(T, Id)}}, Bs};
                  {[], true} -> {Ds, Bs#{{alias, Name} => <<"its name is the name of a record's type or of another type (N3)">>}};
                  {_, _} -> {Ds, Bs#{{alias, Name} => <<"a type with parameters is outside the proof of concept (T8.14: specialise it)">>}}
              end;
         (_, Acc) -> Acc
      end, Acc1, Forms).

%% A declared type is bad when something in it cannot be stated, directly or through a type it names.
bad(Defs, Bad0) ->
    S = #{defs => Defs, bad => Bad0},
    Bad = maps:fold(fun(Name, Def, Acc) ->
                            case maps:is_key(Name, Acc) of
                                true -> Acc;
                                false -> case why_def(Def, S) of ok -> Acc; R -> Acc#{Name => R} end
                            end
                    end, Bad0, Defs),
    case maps:size(Bad) =:= maps:size(Bad0) of
        true -> Bad;
        false -> bad(Defs, Bad)
    end.

why_def({alias, T}, S) -> why(T, S);
why_def({record, R, Fields}, S) ->
    case [{F, W} || {F, T} <- Fields, W <- [why(T, S)], W =/= ok] of
        [] -> ok;
        [{F, W} | _] -> note(["field ", atom_to_binary(F), " of #", atom_to_binary(R), "{}: ", W])
    end.

%% A function's -spec as types, or why it gives none. The reason is a predicate: "<function f/1> has no -spec".
sig(error, _Id, _S) -> {no, <<"has no -spec">>};
sig({ok, [{type, _, 'fun', [{type, _, product, Args}, Ret]}]}, Id, S) ->
    Ps = [ty(A, Id) || A <- Args],
    R = ty(Ret, Id),
    Whys = [{I, T, W} || {I, T} <- lists:zip(lists:seq(1, length(Ps)), Ps), W <- [why(T, S)], W =/= ok],
    case {Whys, why(R, S)} of
        {[], ok} -> {ok, Ps, R};
        {[{I, _, W} | _], _} -> {no, note(["has a -spec whose parameter ", integer_to_binary(I), " states no type (", W, ")"])};
        {[], W} -> {no, note(["has a -spec whose result states no type (", W, ")"])}
    end;
sig({ok, [{type, _, bounded_fun, _}]}, _Id, _S) -> {no, <<"has a -spec with `when` constraints, which this codex does not resolve">>};
sig({ok, _Several}, _Id, _S) -> {no, <<"has a -spec with several clauses, which states no single type">>}.

%% The frames of one unit: every (:type) form first, each after the types it names (T8.14, T5.3), then the
%% functions and the declarations that are gaps, in source order, then the entry.
unit(#{file := File, mod := Mod, id := Id, forms := Forms, gen := Gen}, S, Seq0) ->
    Env = #env{file = File, mod = Mod, id = Id, s = S, remotes = node_remotes(Forms)},
    Unit = atom_to_binary(Mod),
    Exports = lists:append([Es || {attribute, _, export, Es} <- Forms]),
    ExportAll = lists:member(export_all, lists:flatten([Os || {attribute, _, compile, Os} <- Forms])),
    Exported = fun(FA) -> (ExportAll orelse lists:member(FA, Exports)) andalso not maps:is_key(FA, Gen) end,
    ok = gen_sigs(Forms, Env),
    Bodies = node_forms(Forms, Unit)
        ++ type_forms(Forms, Env)
        ++ lists:flatmap(fun(F) -> form(F, Env, Exported) end, Forms)
        ++ [{entry, #{function => fname(Mod, main, 0, Env), arity => 0}}
            || maps:is_key({Mod, main, 0}, maps:get(funs, S)), Exported({main, 0})],
    {Frames, Next} = lists:mapfoldl(
                       fun(Body, Seq) -> {{form, #{seq => Seq, unit_name => Unit, body => Body}}, Seq + 1} end,
                       Seq0 + 1, Bodies),
    [{unit_begin, #{seq => Seq0, unit_name => Unit, silica_unit => <<?PREFIX/binary, Id/binary>>, source => File}}]
        ++ Frames
        ++ [{unit_end, #{seq => Next, unit_name => Unit, forms => length(Bodies)}}].

%% A node program (contract T9.17): `-silica_node([...]).` declares the node this module runs on, the nodes it talks to
%% and the registered names that cross. The transpiler writes the BEES manifest and bees.config from the one form sent.
%%   {name, Node}                     required: the node's name, for example 'hub@localhost'
%%   {peer, Node, Host, dial|listen}  a node this one talks to; a dial peer is found through EPMD ("epmd" port)
%%   {remote, Name, Node, Tag, [Kind]}  a registered name on Node: `{Name, Node} ! {Tag, ...}` casts to it
%%   {local, Name, Tag, [Kind]}       a registered name here that peers may cast {Tag, ...} to
%%   {redial, off} | {redial, InitialMs, MaxMs}   whether a lost link to a dial peer is dialed again (BEES has no default:
%%                                    state it on a node with a dial peer, leave it out on one without)
%%   {listen_port, N} {listen_address, S} {epmd_port, N} {cookie_file, S} {net_ticktime_s, N} {creation, N}   optional
%% Kind is integer | float | atom | boolean | binary: what the fields of the message are (a field's type is the node's
%% to state, as everywhere, contract 8.6). The message is the tagged tuple {Tag, Field...}; BEES's wire carries it as
%% the tuple (atom, Field...), which is the tagged tuple the unit's processes send and receive.
node_forms(Forms, _Unit) ->
    case [Opts || {attribute, _, silica_node, Opts} <- Forms] of
        [] -> [];
        [Opts | _] ->
            Get = fun(K, D) -> proplists:get_value(K, Opts, D) end,
            Text = fun(A) when is_atom(A) -> atom_to_binary(A); (L) -> unicode:characters_to_binary(L) end,
            Fields = fun(Ks) -> [node_kind(K) || K <- Ks] end,
            {RedialI, RedialM} = case [R || R <- Opts, element(1, R) =:= redial] of
                                     [{redial, off}] -> {0, 0};
                                     [{redial, I, M}] -> {I, M};
                                     _ -> {-1, -1}
                                 end,
            [{node, #{name => Text(proplists:get_value(name, Opts)),
                      timing => #{creation => Get(creation, 1), net_ticktime_s => Get(net_ticktime_s, 60),
                              redial_initial_ms => RedialI, redial_max_ms => RedialM},
                      net => #{listen_address => Text(Get(listen_address, "127.0.0.1")),
                               listen_port => Get(listen_port, 0),
                               epmd_port => Get(epmd_port, 4369),
                               cookie_file => Text(Get(cookie_file, "cookie"))},
                      tables => #{peers => [#{name => Text(N), host => Text(H), port => 0, role => R}
                                            || {peer, N, H, R} <- Opts, R =:= dial orelse R =:= listen],
                                  remotes => [#{name => atom_to_binary(Nm), peer => Text(N), tag => atom_to_binary(T), fields => Fields(Ks)}
                                              || {remote, Nm, N, T, Ks} <- Opts],
                                  locals => [#{name => atom_to_binary(Nm), tag => atom_to_binary(T), fields => Fields(Ks)}
                                             || {local, Nm, T, Ks} <- Opts]}}}]
    end.

node_kind(integer) -> <<"int64">>;
node_kind(float) -> <<"float64">>;
node_kind(atom) -> <<"atom">>;
node_kind(boolean) -> <<"boolean">>;
node_kind(binary) -> <<"string">>;
node_kind(Other) -> erlang:error({silica_node_kind, Other}).

%% The remote names a module declares: {Name, Node} -> Tag. {Name, Node} ! Message is a send to one of them.
node_remotes(Forms) ->
    case [Opts || {attribute, _, silica_node, Opts} <- Forms] of
        [] -> #{};
        [Opts | _] -> maps:from_list([{{Nm, N}, T} || {remote, Nm, N, T, _} <- Opts])
    end.

%% The parameter types of the functions e2s_split made (continuations, copies: they have no -spec). A made
%% function is called only by the pieces of the function it was cut from, so its parameters have the types of
%% the arguments of those calls: the forms are typed (and thrown away) until the types the calls give no longer
%% change; session_call/6 notes every call of a made function. The types are kept in the process dictionary under
%% {e2s_made, MFA}: a parameter one call gives `ok` and another `error` is ok | error.
gen_sigs(Forms, Env = #env{mod = Mod, s = #{gen := Gen}}) ->
    Made = [MFA || MFA = {M, _, _} <- maps:keys(Gen), M =:= Mod],
    [erase({e2s_made, MFA}) || MFA <- Made],
    case Made of
        [] -> ok;
        _ -> gen_sigs(Forms, Env, Made, 40)
    end.

gen_sigs(_Forms, _Env, _Made, 0) -> ok;
gen_sigs(Forms, Env, Made, Tries) ->
    [erase({e2s_calls, MFA}) || MFA <- Made],
    [function(F, Env, fun(_) -> false end) || F = {function, _, _, _, _} <- Forms],
    Changed = [MFA || MFA <- Made,
                      Ts <- [get({e2s_calls, MFA})], Ts =/= undefined, why_all(Ts, Env) =:= ok,
                      Ts =/= get({e2s_made, MFA}), put({e2s_made, MFA}, Ts) =/= Ts],
    [erase({e2s_calls, MFA}) || MFA <- Made],
    case Changed of
        [] -> ok;
        _ -> gen_sigs(Forms, Env, Made, Tries - 1)
    end.

%% ------------------------------------------------------------------ names (README, "Names": N1..N6)

%% N4: a function, variable or field name as an identifier, injectively. [A-Za-z0-9] kept; ? -> __q; ! -> __b;
%% _ kept only when it stands alone (no _ before it, and after it a kept character or the end), otherwise
%% __x5f_; any other character -> __x<hex code point>_; the empty name -> __e; a leading digit is escaped.
%% So __ appears in the result only as the start of an escape, and a left-to-right reader gets the name back.
ident(Name) when is_atom(Name) -> ident(atom_to_binary(Name));
ident(<<>>) -> <<"__e">>;
ident(Name) when is_binary(Name) ->
    [C | Rest] = unicode:characters_to_list(Name),
    First = case digit(C) of true -> escape(C); false -> ident_char(none, C, Rest) end,
    unicode:characters_to_binary([First | ident_rest(C, Rest)]).

ident_rest(_Prev, []) -> [];
ident_rest(Prev, [C | Rest]) -> [ident_char(Prev, C, Rest) | ident_rest(C, Rest)].

ident_char(_Prev, $?, _Rest) -> "__q";
ident_char(_Prev, $!, _Rest) -> "__b";
ident_char(Prev, $_, Rest) ->
    case Prev =/= $_ andalso (Rest =:= [] orelse kept(hd(Rest))) of
        true -> "_";
        false -> escape($_)
    end;
ident_char(_Prev, C, _Rest) ->
    case kept(C) of
        true -> [C];
        false -> escape(C)
    end.

kept(C) -> digit(C) orelse (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z).
digit(C) -> C >= $0 andalso C =< $9.
escape(C) -> ["__x", string:lowercase(integer_to_list(C, 16)), "_"].

%% N6: a function's name. A name the module defines at more than one arity is sent as <ident>__<arity>, at every
%% arity; a name with one arity is ident/1 alone. (__ before a digit is never an escape, so this stays injective.)
%% A module outside the session is not seen, so its names get no suffix.
%% N7: a function e2s_split made is sent as <the sent name of the function it was made from><suffix>: main__k1
%% (the first continuation of main), ask__c1 (a copy of ask), counter__l (the linked copy of counter). ident/1
%% never writes __k, __c or __l, so these names are no source function's.
fname(Mod, F, Arity, Env = #env{s = #{multi := Multi, gen := Gen}}) ->
    case Gen of
        #{{Mod, F, Arity} := #{base := {BF, BA}, suffix := Suffix}} ->
            <<(fname(Mod, BF, BA, Env))/binary, Suffix/binary>>;
        _ ->
            case maps:is_key({Mod, F}, Multi) of
                true -> <<(ident(F))/binary, "__", (integer_to_binary(Arity))/binary>>;
                false -> ident(F)
            end
    end.

%% N1: a module name as the part of a Silica unit name after the prefix: its segments (split at . and /) in
%% snake_case, joined with _, then every character outside [A-Za-z0-9_] replaced as unit_char/1 does. This rule
%% is older than ident/1 and is left as it was: it need not be injective, unit names are checked by T5.2.
unit_ident(Module) when is_binary(Module) ->
    Joined = iolist_to_binary(lists:join($_, [snake(S) || S <- binary:split(Module, [<<".">>, <<"/">>], [global])])),
    case << <<(unit_char(C))/binary>> || <<C/utf8>> <= Joined >> of
        <<>> -> <<"_">>;
        <<D, _/binary>> = R when D >= $0, D =< $9 -> <<"_", R/binary>>;
        R -> R
    end.

unit_char(C) when C >= $a, C =< $z; C >= $A, C =< $Z; C >= $0, C =< $9; C =:= $_ -> <<C>>;
unit_char($?) -> <<"_q">>;
unit_char($!) -> <<"_b">>;
unit_char(C) -> <<"_x", (string:lowercase(integer_to_binary(C, 16)))/binary, "_">>.

%% snake_case: _ between a lowercase letter or digit and an uppercase letter, and between an uppercase letter and
%% an uppercase letter that a lowercase letter follows; then lowercase. `MyApp` -> my_app, `HTTPServer` -> http_server.
snake(Name) when is_binary(Name) -> unicode:characters_to_binary(string:lowercase(snake_(unicode:characters_to_list(Name)))).

snake_([A, B | T]) when (A >= $a andalso A =< $z orelse A >= $0 andalso A =< $9), B >= $A, B =< $Z -> [A, $_ | snake_([B | T])];
snake_([A, B, C | T]) when A >= $A, A =< $Z, B >= $A, B =< $Z, C >= $a, C =< $z -> [A, $_ | snake_([B, C | T])];
snake_([A | T]) -> [A | snake_(T)];
snake_([]) -> [].

%% N3: the type name of a record or of a -type is <module as in N1>_<name>: t_named names a type of the whole
%% session (T8.14), and two modules may each declare a record `state`.
type_name(Id, Name) when is_binary(Id) -> <<Id/binary, "_", (ident(snake(atom_to_binary(Name))))/binary>>.

field_name({typed_record_field, F, _}) -> field_name(F);
field_name({record_field, _, {atom, _, N}}) -> N;
field_name({record_field, _, {atom, _, N}, _}) -> N.

record_field_type({typed_record_field, _, T}, _R, Id) -> ty(T, Id);
record_field_type(F, R, _Id) ->
    {unknown, note(["field ", atom_to_binary(field_name(F)), " of #", atom_to_binary(R),
                    "{} has no type in the -record declaration"])}.

%% ------------------------------------------------------------------ top-level forms (contract 9.3)

%% The (:type) forms of a module's records and -type declarations, each after the declared types it names.
type_forms(Forms, Env = #env{id = Id, s = #{defs := Defs}}) ->
    Decls = [{type_name(Id, N), erl_anno:line(Anno), <<"-record">>}
             || {attribute, Anno, record, {N, _}} <- Forms]
        ++ [{type_name(Id, N), erl_anno:line(Anno), <<"-", (atom_to_binary(Kind))/binary>>}
            || {attribute, Anno, Kind, {N, _, []}} <- Forms, Kind =:= type orelse Kind =:= opaque orelse Kind =:= nominal],
    Mine = [N || {N, _, _} <- Decls],
    Order = lists:reverse(lists:foldl(fun(N, Done) -> visit(N, Mine, Defs, Done) end, [], Mine)),
    [type_form(lists:keyfind(N, 1, Decls), Env) || N <- Order].

visit(N, Mine, Defs, Done) ->
    case lists:member(N, Done) orelse not lists:member(N, Mine) of
        true -> Done;
        false ->
            Names = case maps:get(N, Defs) of
                        {alias, T} -> named(T);
                        {record, _, Fields} -> lists:append([named(T) || {_, T} <- Fields])
                    end,
            %% N goes in before its children are visited only to stop a cycle; it is moved behind them after.
            Done1 = lists:foldl(fun(C, D) -> visit(C, Mine, Defs, D) end, [N | Done], Names),
            [N | lists:delete(N, Done1)]
    end.

%% The names of the declared types a type term mentions.
named({named, N}) -> [N];
named(T) when is_tuple(T) -> lists:append([named(E) || E <- tuple_to_list(T)]);
named(L) when is_list(L) -> lists:append([named(E) || E <- L]);
named(_) -> [].

type_form({Name, Line, Construct}, Env = #env{s = S = #{defs := Defs, bad := Bad}}) ->
    case {maps:find(Name, Bad), maps:get(Name, Defs)} of
        {{ok, Why}, _} ->
            form_gap(Name, Line, Env, Construct, note(["no type can be stated for it: ", Why, " (T8.14)"]));
        {error, {record, _, Fields}} ->
            {Pairs, B} = lists:mapfoldl(fun({F, T}, B0) -> {I, B1} = intern(T, B0), {{ident(F), I}, B1} end,
                                        #b{env = Env}, Fields),
            Types = lists:reverse(B#b.types) ++ [{t_record, Pairs}],
            type_decl(Name, Line, Env, Types, length(Types) - 1);
        {error, {alias, T}} ->
            ok = why(T, S),
            {Root, B} = intern(T, #b{env = Env}),
            type_decl(Name, Line, Env, lists:reverse(B#b.types), Root)
    end.

type_decl(Name, Line, Env, Types, Root) ->
    {type, #{head => #{name => Name, params => [], exported => false, file => Env#env.file},
             at_line => Line, types => Types, root => Root}}.

form({function, _, _, _, _} = F, Env, Exported) -> [function(F, Env, Exported)];
form({attribute, Anno, Kind, {N, _, Params}}, Env = #env{id = Id, s = #{bad := Bad}}, _Exported)
  when Kind =:= type; Kind =:= opaque; Kind =:= nominal ->
    %% A -type the type forms above did not send: parameters, or a name taken by a record (N3).
    Name = type_name(Id, N),
    case {Params, maps:find({alias, Name}, Bad)} of
        {_, {ok, Why}} -> [form_gap(Name, erl_anno:line(Anno), Env, <<"-", (atom_to_binary(Kind))/binary>>, Why)];
        {_, error} -> []
    end;
form({attribute, Anno, Kind, _}, Env, _Exported)
  when Kind =:= callback; Kind =:= behaviour; Kind =:= behavior; Kind =:= import ->
    [form_gap(atom_to_binary(Kind), erl_anno:line(Anno), Env, <<"-", (atom_to_binary(Kind))/binary>>,
              <<"outside the proof of concept">>)];
form(_Other, _Env, _Exported) ->
    [].      %% module, export, spec and record (used above), file, compile, eof and other attributes carry no code

form_gap(Name, Line, Env, Construct, Note) ->
    {gap, #{name => Name, place => #{file => Env#env.file, line => Line}, construct => Construct, note => Note}}.

%% A function form. Its signature is the -spec (T8.10 a): without one that states every type, nothing in the
%% function can be typed, and the whole function is a gap form that says so.
function({function, Anno, Name, Arity, Clauses}, Env = #env{mod = Mod, s = S = #{gen := Gen}}, Exported) ->
    FName = fname(Mod, Name, Arity, Env),
    Construct = case Gen of
                    #{{Mod, Name, Arity} := #{what := What}} -> What;
                    _ -> <<"function ", (atom_to_binary(Name))/binary, "/", (integer_to_binary(Arity))/binary>>
                end,
    case fsig({Mod, Name, Arity}, S) of
        {no, Why} ->
            form_gap(FName, erl_anno:line(Anno), Env, Construct,
                     note([Construct, " ", Why, ", so its signature type cannot be stated (T8.10 a)"]));
        {pending, _} ->
            form_gap(FName, erl_anno:line(Anno), Env, Construct,
                     note([Construct, ": no call of it could be typed (the code before it is a gap, or a variable "
                           "it is given has no type), so its signature type cannot be stated (T8.10 a)"]));
        {Kind, Ps, R} ->
            Strength = case Kind of ok -> declared; made -> inferred end,
            try
                {Sig, B0} = intern({'fun', Ps, R}, #b{env = Env}),
                {Cs, B} = lists:mapfoldl(fun(C, B1) ->
                                                 {I, _, _, B2} = clause(function, C, Ps, Strength, R, B1#b{vars = #{}}),
                                                 {I, B2}
                                         end, B0, Clauses),
                {function, #{head => #{name => FName, arity => Arity, exported => Exported({Name, Arity}),
                                       file => Env#env.file},
                             code => #{locations => lists:reverse(B#b.locs), nodes => lists:reverse(B#b.nodes),
                                       clauses => Cs},
                             types => lists:reverse(B#b.types),
                             notes => #{hints => [#{node => -1, type => Sig, strength => Strength, policy => default}
                                                  | hints(B)],
                                        overrides => lists:reverse(B#b.overrides)}}}
            catch
                throw:{e2s_untyped, Reason} -> form_gap(FName, erl_anno:line(Anno), Env, Construct, Reason)
            end
    end.

hints(#b{hints = Hints, decl = Decl}) ->
    [#{node => Node, type => Type, policy => default,
       strength => case maps:is_key(Node, Decl) of true -> declared; false -> inferred end}
     || {Node, Type} <- lists:sort(maps:to_list(Hints))].

%% ------------------------------------------------------------------ type terms
%%
%% The codex's own types, from which both the type table (intern/2) and every typing decision are made:
%%   int | float | boolean | atom | {atoms, [Name]} | bytes | {tuple, [T]} | {tagged, Tag, [T]} | {named, Name}
%%   | {list, T} | {union, [T]} | {'fun', [T], T} | {actor, T} | dynamic
%%   none             no value: exit/1, error/1; the element type of []
%%   {unknown, Why}   Erlang gives no type here; Why is the text a gap's note will carry
%%   any              only as an expected type: nothing is expected
%%
%% To extend: add a clause to ty/2 for the Erlang type, to entry/2 for a new kind of type term, and to show/1.

%% ty(ErlangType, ModuleId) -> type term.
ty({ann_type, _, [_Var, T]}, Id) -> ty(T, Id);
ty({paren_type, _, [T]}, Id) -> ty(T, Id);
ty({type, _, I, []}, _Id)
  when I =:= integer; I =:= non_neg_integer; I =:= pos_integer; I =:= neg_integer; I =:= char; I =:= byte;
       I =:= arity ->
    int;                               %% Erlang integers are unbounded: i64 is the contract's fallback (T8.7)
ty({type, _, range, _}, _Id) -> int;
ty({integer, _, _}, _Id) -> int;
ty({char, _, _}, _Id) -> int;
ty({op, _, '-', {integer, _, _}}, _Id) -> int;
ty({type, _, float, []}, _Id) -> float;
ty({type, _, number, []}, _Id) ->
    {unknown, <<"number() is integer() or float(), and the codex must state which (T8.11)">>};
ty({type, _, boolean, []}, _Id) -> boolean;
ty({type, _, A, []}, _Id) when A =:= atom; A =:= module; A =:= node -> atom;
ty({type, _, binary, []}, _Id) -> bytes;
ty({atom, _, B}, _Id) when is_boolean(B) -> boolean;
ty({atom, _, A}, _Id) -> {atoms, [atom_to_binary(A)]};
ty({type, _, pid, []}, _Id) -> {actor, dynamic};    %% pid() says nothing about the messages
ty({type, _, tuple, [{atom, _, Tag} | Es]}, Id) when not is_boolean(Tag) ->
    {tagged, atom_to_binary(Tag), [ty(E, Id) || E <- Es]};
ty({type, _, tuple, Es}, Id) when is_list(Es) -> {tuple, [ty(E, Id) || E <- Es]};
ty({type, _, record, [{atom, _, Name}]}, Id) -> {named, type_name(Id, Name)};
ty({user_type, _, Name, []}, Id) -> {named, type_name(Id, Name)};
ty({user_type, _, Name, _}, _Id) ->
    {unknown, note([atom_to_binary(Name), "(...) is a type with parameters, outside the proof of concept"])};
ty({type, _, L, [E]}, Id) when L =:= list; L =:= nonempty_list -> {list, ty(E, Id)};
ty({type, _, string, []}, _Id) -> {list, int};        %% string() is [char()]: a list of integers
ty({type, _, union, Alts}, Id) -> union([ty(A, Id) || A <- Alts]);
ty({type, _, 'fun', [{type, _, product, Args}, Ret]}, Id) -> {'fun', [ty(A, Id) || A <- Args], ty(Ret, Id)};
ty({type, _, T, []}, _Id) when T =:= any; T =:= term ->
    {unknown, note([atom_to_binary(T), "() states no type"])};
ty({var, _, V}, _Id) -> {unknown, note(["the type variable ", atom_to_binary(V), " states no type"])};
ty({remote_type, _, [{atom, _, M}, {atom, _, T}, _]}, _Id) ->
    {unknown, note([atom_to_binary(M), ":", atom_to_binary(T), "() is a type of another module"])};
ty({type, _, T, _}, _Id) -> {unknown, note([atom_to_binary(T), "() is a type this codex does not state"])};
ty(_Other, _Id) -> {unknown, <<"a type this codex does not state">>}.

%% The common type of several: one type when they agree, the atoms of all atom alternatives as one, else a union.
union(Ts) ->
    Flat = lists:append([case T of {union, As} -> As; _ -> [T] end || T <- Ts]),
    Atoms = lists:usort(lists:append([As || {atoms, As} <- Flat])),
    Lists = [T || T = {list, E} <- Flat, E =/= none],
    Others = lists:usort([T || T <- Flat, T =/= none, not is_atoms(T),
                               not (T =:= {list, none} andalso Lists =/= [])]),
    case [{atoms, Atoms} || Atoms =/= []] ++ Others of
        [One] -> One;
        Many -> {union, Many}
    end.

is_atoms({atoms, _}) -> true;
is_atoms(_) -> false.

%% The type of a value that is one of these: branches of a case, elements of a list. `none` (a branch that
%% fails) adds nothing; one unknown makes the whole unknown.
join(Ts) ->
    case [T || T <- Ts, T =/= none] of
        [] -> none;
        Ts1 ->
            case [U || U = {unknown, _} <- Ts1] of
                [U | _] -> U;
                [] -> union(Ts1)
            end
    end.

%% why(Type, EnvOrBuilderOrSession) -> ok | Reason: can the type be stated in a type table?
why(T, #b{env = Env}) -> why(T, Env);
why(T, #env{s = S}) -> why(T, S);
why({unknown, Why}, _S) -> Why;
why(any, _S) -> <<"nothing states its type">>;
why(none, _S) -> <<"it never has a value">>;
why({list, none}, _S) -> <<"nothing states the element type of the empty list">>;
why({named, N}, #{defs := Defs, bad := Bad}) ->
    case {maps:is_key(N, Defs), maps:find(N, Bad)} of
        {true, error} -> ok;
        {true, {ok, Why}} -> note(["the declared type ", N, " cannot be stated (", Why, ")"]);
        {false, _} -> note(["no record or type ", N, " is declared in this session"])
    end;
why({tuple, Ts}, S) -> why_all(Ts, S);
why({tagged, _, Ts}, S) -> why_all(Ts, S);
why({list, T}, S) -> why(T, S);
why({union, Ts}, S) -> why_all(Ts, S);
why({'fun', Ps, R}, S) -> why_all(Ps ++ [R], S);
why({actor, T}, S) -> why(T, S);
why(_Basic, _S) -> ok.

why_all(Ts, S) ->
    case [W || T <- Ts, W <- [why(T, S)], W =/= ok] of
        [] -> ok;
        [W | _] -> W
    end.

%% Does a value of type T fit where Expected is stated? (Erlang's subtyping, as far as this codex follows it.)
compat(T, X, #b{env = #env{s = S}}) -> compat(T, X, S, 8);
compat(T, X, #env{s = S}) -> compat(T, X, S, 8).

compat(_, _, _, 0) -> false;
compat(T, T, _, _) -> true;
compat(none, _, _, _) -> true;
compat(_, any, _, _) -> true;
compat({atoms, A}, {atoms, B}, _, _) -> A -- B =:= [];
compat({atoms, _}, atom, _, _) -> true;
compat(boolean, atom, _, _) -> true;
compat({list, none}, {list, _}, _, _) -> true;
compat({list, A}, {list, B}, S, D) -> compat(A, B, S, D);
compat({tuple, As}, {tuple, Bs}, S, D) when length(As) =:= length(Bs) -> compat_all(As, Bs, S, D);
compat({tagged, Tag, As}, {tagged, Tag, Bs}, S, D) when length(As) =:= length(Bs) -> compat_all(As, Bs, S, D);
compat({actor, A}, {actor, B}, _, _) -> A =:= dynamic orelse B =:= dynamic;
compat({'fun', As, R1}, {'fun', Bs, R2}, S, D) when length(As) =:= length(Bs) ->
    compat_all(Bs, As, S, D) andalso compat(R1, R2, S, D);
compat({union, As}, X, S, D) -> lists:all(fun(A) -> compat(A, X, S, D) end, As);
compat(T, {union, Bs}, S, D) -> lists:any(fun(B) -> compat(T, B, S, D) end, Bs);
compat({named, N}, X, S, D) ->
    case alias(N, S) of {ok, T} -> compat(T, X, S, D - 1); no -> false end;
compat(T, {named, N}, S, D) ->
    case alias(N, S) of {ok, X} -> compat(T, X, S, D - 1); no -> false end;
compat(_, _, _, _) -> false.

compat_all(As, Bs, S, D) -> lists:all(fun({A, B}) -> compat(A, B, S, D) end, lists:zip(As, Bs)).

alias(N, #{defs := Defs}) ->
    case Defs of
        #{N := {alias, T}} -> {ok, T};
        _ -> no
    end.

%% A -type name stands for its definition wherever the codex takes a type apart.
expand(T, B) -> expand(T, B, 8).
expand({named, N} = T, B = #b{env = #env{s = S}}, D) when D > 0 ->
    case alias(N, S) of {ok, T1} -> expand(T1, B, D - 1); no -> T end;
expand(T, _B, _D) -> T.

%% The type a construction or a literal takes: the expected one when it fits there (an atom `ok` where
%% ok | error is expected is of that type, [] where [integer()] is expected is a list of integers), else its own.
%% Only nodes whose type is theirs to take are fitted: a variable and a call keep the type they have.
fit(T, X, B) ->
    case X =/= any andalso why(X, B) =:= ok andalso compat(T, X, B) of
        true -> X;
        false -> T
    end.

%% A type as Erlang text, for the notes of gaps.
show(int) -> <<"integer()">>;
show(float) -> <<"float()">>;
show(boolean) -> <<"boolean()">>;
show(atom) -> <<"atom()">>;
show({atoms, As}) -> note(lists:join(" | ", As));
show(bytes) -> <<"binary()">>;
show(text) -> <<"text">>;
show({tuple, Ts}) -> note(["{", lists:join(", ", [show(T) || T <- Ts]), "}"]);
show({tagged, Tag, Ts}) -> note(["{", lists:join(", ", [Tag | [show(T) || T <- Ts]]), "}"]);
show({named, N}) -> N;
show({list, none}) -> <<"[]">>;
show({list, T}) -> note(["[", show(T), "]"]);
show({union, Ts}) -> note(lists:join(" | ", [show(T) || T <- Ts]));
show({'fun', Ps, R}) -> note(["fun((", lists:join(", ", [show(T) || T <- Ps]), ") -> ", show(R), ")"]);
show({actor, _}) -> <<"pid()">>;
show(dynamic) -> <<"term()">>;
show(none) -> <<"no_return()">>;
show(_) -> <<"an unstated type">>.

note(IoList) -> unicode:characters_to_binary(IoList).

%% ------------------------------------------------------------------ the type table and hints (contract 8.4, 8.5)

%% intern(Type, Builder) -> {Index, Builder}: the type's entry in the form's flat type table, children first.
%% The same type term is one entry however often it is used.
intern(T, B = #b{tmap = Map}) ->
    case Map of
        #{T := I} -> {I, B};
        _ ->
            {Entry, B1 = #b{types = Ts, tn = N, tmap = Map1}} = entry(T, B),
            {N, B1#b{types = [Entry | Ts], tn = N + 1, tmap = Map1#{T => N}}}
    end.

entry(int, B) -> {{t_int, i64}, B};
entry(float, B) -> {{t_float, f64}, B};
entry(boolean, B) -> {{t_basic, boolean}, B};
entry(atom, B) -> {{t_basic, symbol}, B};
entry(bytes, B) -> {{t_basic, bytes}, B};
entry(text, B) -> {{t_basic, text}, B};
entry(dynamic, B) -> {{t_basic, dynamic}, B};
entry({atoms, As}, B) -> {{t_symbols, As}, B};
entry({named, N}, B) -> {{t_named, N, []}, B};
entry({tuple, Ts}, B0) -> {Is, B} = interns(Ts, B0), {{t_tuple, Is}, B};
entry({tagged, Tag, Ts}, B0) -> {Is, B} = interns(Ts, B0), {{t_tagged, Tag, Is}, B};
entry({list, T}, B0) -> {I, B} = intern(T, B0), {{t_list, I}, B};
entry({union, Ts}, B0) -> {Is, B} = interns(Ts, B0), {{t_union, Is}, B};
entry({actor, T}, B0) -> {I, B} = intern(T, B0), {{t_actor, I}, B};
entry({'fun', Ps, R}, B0) ->
    {Is, B1} = interns(Ps, B0),
    {I, B} = intern(R, B1),
    {{t_fun, Is, I}, B}.

interns(Ts, B) -> lists:mapfoldl(fun intern/2, B, Ts).

%% A hint on a node (T8.5), when the type can be stated. Its strength is decided when the form is finished:
%% :declared for the nodes marked with mark/3, :inferred for the others (T8.2).
hint(I, T, B) ->
    case why(T, B) of
        ok ->
            {Ti, B1} = intern(T, B),
            B1#b{hints = (B1#b.hints)#{I => Ti}};
        _ -> B
    end.

mark(I, declared, B = #b{decl = Decl}) -> B#b{decl = Decl#{I => true}};
mark(_I, _Inferred, B) -> B.

strength(I, #b{decl = Decl}) ->
    case maps:is_key(I, Decl) of true -> declared; false -> inferred end.

%% ------------------------------------------------------------------ node tables (contract 9.1)

%% Appends one node. Every node gets its own location entry, so a node's `at` equals its index (T9.3).
emit(Tag, Anno, Fields, B = #b{nodes = Ns, n = N, locs = Ls}) ->
    Loc = {erl_anno:line(Anno), case erl_anno:column(Anno) of undefined -> 0; C -> C end},
    {N, B#b{nodes = [list_to_tuple([Tag, N | Fields]) | Ns], n = N + 1, locs = [Loc | Ls]}}.

%% A node whose type is fixed by itself (T8.9: a literal) or that has none (fail): no hint.
plain(Tag, Anno, Fields, T, B0) ->
    {I, B} = emit(Tag, Anno, Fields, B0),
    {I, T, B}.

%% A node with its type as a hint, when the type can be stated. THIS IS HOW A CONSTRUCT STATES ITS TYPE.
node(Tag, Anno, Fields, T, B0) ->
    {I, B} = emit(Tag, Anno, Fields, B0),
    {I, T, hint(I, T, B)}.

%% H40: a construct this codex does not translate, or cannot type (T9.10). B must be the builder from BEFORE the
%% construct, so that nothing built for it stays in the frame. The gap's own type is unknown, with the note as
%% the reason, so whatever needs the gap's value becomes a gap that still names the first cause.
gap(Anno, Construct, B) -> gap(Anno, Construct, <<"outside the proof of concept">>, B).
gap(Anno, Construct, Note0, B0) ->
    Note = note(Note0),
    {I, B} = emit(gap_node, Anno, [note(Construct), Note], B0),
    {I, {unknown, Note}, B}.

is_gap(I, #b{nodes = Ns, n = N}) -> element(1, lists:nth(N - I, Ns)) =:= gap_node.

%% ------------------------------------------------------------------ clauses, guards, bodies

%% clause(Kind, Clause, PatternTypes, Strength, ExpectedBodyType, B) -> {Index, PatternTypes, BodyType, B}.
%% Kind is function | 'case' | 'if' | 'receive' | lambda. A variable a clause binds is known only inside it.
clause(Kind, {clause, Anno, Patterns, Guards, Body}, PXs, Str, X, B0) ->
    GT = guard_types(Guards),
    {Ps, PTs, B1} = patterns(Patterns, PXs, Str, GT, B0),
    B1a = case Kind of
              'receive' -> message(hd(Ps), hd(PTs), B1);
              _ -> B1
          end,
    {G, B2} = guards(unstated(Guards, B1a), B1a),
    {Bd0, BT0, B3a} = body(Body, X, B2),
    {Bd, BT, B3} =
        case Kind =:= function andalso why(BT0, B3a) =:= ok andalso not compat(BT0, X, B3a) of
            true ->
                %% The -spec is a claim the code does not keep. The codex states only types the code has.
                gap(Anno, <<"function body">>,
                    ["the body's value is ", show(BT0), ", which is not the -spec's result ", show(X),
                     ": no type can be stated for both (T8.9)"], B2);
            false -> {Bd0, BT0, B3a}
        end,
    {C, B4} = emit(clause, Anno, [Ps, G, Bd], B3),
    {C, PTs, BT, B4#b{vars = B0#b.vars}}.

clauses(Kind, Cs, PXs, Str, X, B0) ->
    {Rs, B} = lists:mapfoldl(fun(C, B1) -> {I, PTs, BT, B2} = clause(Kind, C, PXs, Str, X, B1), {{I, PTs, BT}, B2} end,
                             B0, Cs),
    {[I || {I, _, _} <- Rs], [PTs || {_, PTs, _} <- Rs], [BT || {_, _, BT} <- Rs], B}.

%% T8.10 e: the message of a receive clause must have a type. It is the type of the clause's pattern.
message(Pi, PT, B) ->
    case why(PT, B) of
        ok ->
            case lists:member(element(1, lists:nth(B#b.n - Pi, B#b.nodes)), [tuple, cons, list, record, match]) of
                true -> hint(Pi, PT, B);
                false -> B              %% a literal is typed by itself, a variable by its binding
            end;
        Why -> throw({e2s_untyped, note(["the message pattern of a receive clause has no type: ", Why, " (T8.10 e)"])})
    end.

%% What the type tests of a guard say about variables: `when is_integer(N), is_pid(P)`. Only a guard with one
%% alternative counts (in `G1; G2` neither need hold). This is Erlang's own way to type a message or a fun's
%% parameter, and it is sound: the clause runs only when the test held.
guard_types([Tests]) -> maps:from_list(lists:flatmap(fun type_test/1, Tests));
guard_types(_) -> #{}.

type_test({op, _, 'andalso', L, R}) -> type_test(L) ++ type_test(R);
type_test({call, _, {remote, _, {atom, _, erlang}, F}, Args}) -> type_test({call, 0, F, Args});
type_test({call, _, {atom, _, F}, [{var, _, V}]}) ->
    case F of
        is_integer -> [{V, int}];
        is_float -> [{V, float}];
        is_boolean -> [{V, boolean}];
        is_atom -> [{V, atom}];
        is_binary -> [{V, bytes}];
        is_pid -> [{V, {actor, dynamic}}];
        _ -> []
    end;
type_test(_) -> [].

%% T8.16: a type test on a variable whose stated type is the tested type says nothing more than the type does, and
%% the transpiler knows no language's type tests: it is not sent. (`{add, N} when is_integer(N)` is the pattern
%% {add, N} with N hinted as an integer, and for a receive clause the pattern's hint is the type of the messages
%% the clause takes.) A test on a variable of any other stated type is sent as it is written (and is then a call
%% the transpiler does not know: a gap there). Only a guard with one alternative is looked at, as in guard_types/1.
unstated([Tests], B) ->
    case [T || T <- Tests, not stated(T, B)] of
        [] -> [];
        Rest -> [Rest]
    end;
unstated(Alternatives, _B) -> Alternatives.

stated({call, _, {remote, _, {atom, _, erlang}, F}, Args}, B) -> stated({call, 0, F, Args}, B);
stated({call, _, {atom, _, _}, [{var, _, V}]} = Test, #b{vars = Vars}) ->
    case {type_test(Test), Vars} of
        {[{V, T}], #{V := {T, _}}} -> true;
        _ -> false
    end;
stated(_, _) -> false.

%% A guard sequence G1; G2 is `orelse` of its guards, each guard A, B an `andalso` of its tests.
guards([], B) -> {-1, B};
guards(Alternatives, B0) ->
    {Is, B1} = lists:mapfoldl(fun(Tests, B) ->
                                      {Ts, _, Bn} = exprs(Tests, boolean, B),
                                      and_or(<<"andalso">>, Ts, hd(Tests), Bn)
                              end, B0#b{guard = true}, Alternatives),
    {I, B2} = and_or(<<"orelse">>, Is, hd(hd(Alternatives)), B1),
    {I, B2#b{guard = B0#b.guard}}.

and_or(_Op, [One], _First, B) -> {One, B};
and_or(Op, [A, B1 | Rest], First, B) ->
    {I, _, B2} = node(op, element(2, First), [Op, [A, B1]], boolean, B),
    and_or(Op, [I | Rest], First, B2).

body([One], X, B) -> expr(One, X, B);
body([First | _] = Many, X, B0) ->
    {Is, T, B1} = sequence(Many, X, B0),
    node(block, element(2, First), [Is], T, B1).

%% The expressions of a block. Every one but the last needs a type though its value is dropped (T8.10 e).
sequence([Last], X, B0) ->
    {I, T, B} = expr(Last, X, B0),
    {[I], T, B};
sequence([E | Rest], X, B0) ->
    {I, T, B1} = expr(E, any, B0),
    {I1, B2} = case T =:= none orelse why(T, B1) =:= ok orelse is_gap(I, B1) of
                   true -> {I, B1};
                   false ->
                       {G, _, Bg} = gap(element(2, E), <<"expression whose value is dropped">>,
                                        ["it has no type: ", why(T, B1), " (T8.10 e)"], B0),
                       {G, Bg}
               end,
    {Is, Tn, B3} = sequence(Rest, X, B2),
    {[I1 | Is], Tn, B3}.

exprs(Es, X, B0) ->
    {Rs, B} = lists:mapfoldl(fun(E, B1) -> {I, T, B2} = expr(E, X, B1), {{I, T}, B2} end, B0, Es),
    {[I || {I, _} <- Rs], [T || {_, T} <- Rs], B}.

exprs_each(Es, Xs, B0) ->
    {Rs, B} = lists:mapfoldl(fun({E, X}, B1) -> {I, T, B2} = expr(E, X, B1), {{I, T}, B2} end, B0, lists:zip(Es, Xs)),
    {[I || {I, _} <- Rs], [T || {_, T} <- Rs], B}.

%% ------------------------------------------------------------------ patterns
%%
%% pattern(Abstract, TypeOfWhatIsMatched, Strength, GuardTypes, B) -> {Index, TypeOfThePattern, B}.
%% Patterns use the same nodes as expressions (contract 9.4). A variable that is not bound yet is bound here,
%% with the type of its position in what is matched (T8.10 b), or else the type a guard's type test gives it; it
%% gets a hint. A variable that would be bound with no type ends the construct: {e2s_untyped, Why} is thrown and
%% the nearest function, case, receive, fun or match becomes a gap with that note.
%% An alias pattern P1 = P2 is sent as a match node (H18) in pattern position whose two children are patterns.
pattern({var, Anno, '_'}, X, _Str, _GT, B) -> plain(wild, Anno, [], X, B);
pattern({var, Anno, V}, X, Str, GT, B = #b{vars = Vars}) ->
    case Vars of
        #{V := {T, S}} ->                           %% already bound: the pattern compares with its value
            {I, B1} = emit(var, Anno, [ident(V)], B),
            {I, T, mark(I, S, B1)};
        _ ->
            {T, S} = case {why(X, B), GT} of
                         {ok, _} -> {X, Str};
                         {_, #{V := G}} -> {G, inferred};
                         _ -> {X, Str}
                     end,
            case why(T, B) of
                ok ->
                    {I, B1} = emit(var, Anno, [ident(V)], B#b{vars = Vars#{V => {T, S}}}),
                    {I, T, mark(I, S, hint(I, T, B1))};
                Why ->
                    throw({e2s_untyped, note(["the variable ", atom_to_binary(V), " would be bound without a type: ",
                                              Why, " (T8.10 b)"])})
            end
    end;
pattern({match, Anno, L, R}, X, Str, GT, B0) ->
    {Li, LT, B1} = pattern(L, X, Str, GT, B0),
    {Ri, RT, B2} = pattern(R, X, Str, GT, B1),
    {I, B3} = emit(match, Anno, [Li, Ri], B2),
    {I, case why(LT, B3) of ok -> LT; _ -> RT end, B3};
pattern({tuple, Anno, Es}, X, Str, GT, B0) ->
    Xs = case tuple_parts(expand(X, B0), Es, B0) of
             {ok, Parts} -> Parts;
             no -> lists:duplicate(length(Es), no_part(X, <<"a tuple pattern of this shape">>, B0))
         end,
    {Is, Ts, B1} = patterns(Es, Xs, Str, GT, B0),
    {I, B2} = emit(tuple, Anno, [Is], B1),
    {I, fit(tuple_type(Es, Ts), X, B2), B2};
pattern({cons, Anno, H, T}, X, Str, GT, B0) ->
    HX = case expand(X, B0) of
             {list, E} when E =/= none -> E;
             _ -> no_part(X, <<"a list pattern">>, B0)
         end,
    {Hi, HT, B1} = pattern(H, HX, Str, GT, B0),
    {Ti, _TT, B2} = pattern(T, case HX of {unknown, _} -> HX; _ -> X end, Str, GT, B1),
    {I, B3} = emit(cons, Anno, [Hi, Ti], B2),
    {I, fit({list, HT}, X, B3), B3};
pattern({nil, Anno}, X, _Str, _GT, B) -> plain(nil, Anno, [], fit({list, none}, X, B), B);
pattern({string, Anno, []}, _X, _Str, _GT, B) -> plain(nil, Anno, [], {list, int}, B);
pattern({string, Anno, S}, _X, _Str, _GT, B0) ->
    {Is, B1} = lists:mapfoldl(fun(C, B) -> emit(int, Anno, [C], B) end, B0, S),
    plain(list, Anno, [Is, -1], {list, int}, B1);
pattern({record, Anno, Name, Fields}, _X, Str, GT, B0 = #b{env = Env}) ->
    TN = type_name(Env#env.id, Name),
    case [F || F <- Fields, element(1, element(3, F)) =/= atom] of
        [] ->
            {Pairs, B1} = lists:mapfoldl(fun({record_field, _, {atom, _, F}, P}, B) ->
                                                 {I, _, Bn} = pattern(P, field_type(TN, F, B), Str, GT, B),
                                                 {{ident(F), I}, Bn}
                                         end, B0, Fields),
            plain(record, Anno, [TN, Pairs, -1], {named, TN}, B1);
        _ ->
            {I, _, B1} = gap(Anno, <<"record with a default for all fields (_ = Value)">>, B0),
            {I, {named, TN}, B1}
    end;
pattern({atom, Anno, A}, X, _Str, _GT, B) when not is_boolean(A) ->
    plain(symbol, Anno, [atom_to_binary(A)], fit({atoms, [atom_to_binary(A)]}, X, B), B);
pattern(Other, X, _Str, _GT, B) -> expr(Other, X, B).

patterns(Ps, Xs, Str, GT, B0) ->
    {Rs, B} = lists:mapfoldl(fun({P, X}, B1) -> {I, T, B2} = pattern(P, X, Str, GT, B1), {{I, T}, B2} end,
                             B0, lists:zip(Ps, Xs)),
    {[I || {I, _} <- Rs], [T || {_, T} <- Rs], B}.

%% The type of a position that the matched value's type does not have.
no_part(X, What, B) ->
    case why(X, B) of
        ok -> {unknown, note(["the matched value is ", show(X), ", which has no part for ", What])};
        _ -> X
    end.

%% The types of the elements of a tuple written with these element expressions, taken from the type of the
%% tuple: {ok, [Type]} | no. {tagged, T, Es} is the type of a tuple whose first element is the atom T.
tuple_parts({tuple, Ts}, Es, _B) when length(Ts) =:= length(Es) -> {ok, Ts};
tuple_parts({tagged, Tag, Ts}, [E1 | Rest], _B) when length(Ts) =:= length(Rest) ->
    case E1 of
        {atom, _, A} -> case atom_to_binary(A) of Tag -> {ok, [{atoms, [Tag]} | Ts]}; _ -> no end;
        _ -> {ok, [{atoms, [Tag]} | Ts]}
    end;
tuple_parts({union, Alts}, Es, B) ->
    case [Ps || A <- Alts, {ok, Ps} <- [tuple_parts(expand(A, B), Es, B)]] of
        [] -> no;
        [Ps] -> {ok, Ps};
        Several -> {ok, [join(Column) || Column <- columns(Several)]}
    end;
tuple_parts(_, _, _) -> no.

columns([[] | _]) -> [];
columns(Rows) -> [[hd(R) || R <- Rows] | columns([tl(R) || R <- Rows])].

%% A tuple whose first element is written as an atom is a tagged tuple, as its -spec type {tag, ...} is.
tuple_type([{atom, _, A} | _], [_ | Ts]) when not is_boolean(A) -> {tagged, atom_to_binary(A), Ts};
tuple_type(_Es, Ts) -> {tuple, Ts}.

field_type(TN, Field, #b{env = #env{s = #{defs := Defs}}}) ->
    case Defs of
        #{TN := {record, _, Fields}} ->
            case lists:keyfind(Field, 1, Fields) of
                {_, T} -> T;
                false -> {unknown, note(["the record type ", TN, " has no field ", atom_to_binary(Field)])}
            end;
        _ -> {unknown, note(["no record ", TN, " is declared in this session"])}
    end.

%% ------------------------------------------------------------------ expressions
%%
%% expr(Abstract, Expected, B) -> {Index, Type, B}. Expected is the type the place states (the function's result
%% for a body, a parameter's type for an argument of a function of the session, a field's type), or `any`.
%% To add a construct: build the children with expr/3, decide the type by Erlang's rules, and finish with
%%   node(Tag, Anno, Fields, Type, B)    the node and its hint;
%%   plain(Tag, Anno, Fields, Type, B)   a literal (T8.9 fixes its type) or a node with no value;
%%   gap(Anno, Construct, Note, B0)      when the contract has no node, or a type T8.10 requires is missing.

%% --- literals and data (H1..H13)
expr({integer, Anno, N}, _X, B) when N >= -(1 bsl 63), N < (1 bsl 63) -> plain(int, Anno, [N], int, B);
expr({integer, Anno, _}, _X, B) ->
    gap(Anno, <<"integer beyond 64 bits">>, <<"Erlang's integers are unbounded, the contract's are int64 (T8.7)">>, B);
expr({char, Anno, C}, _X, B) -> plain(int, Anno, [C], int, B);
expr({float, Anno, F}, _X, B) -> plain(float, Anno, [float_text(F)], float, B);
expr({atom, Anno, Bool}, _X, B) when is_boolean(Bool) -> plain(boolean, Anno, [Bool], boolean, B);
expr({atom, Anno, A}, X, B) -> plain(symbol, Anno, [atom_to_binary(A)], fit({atoms, [atom_to_binary(A)]}, X, B), B);
%% A binary is bytes in Erlang, whatever is written in it: (:bytes) with a hint, never (:text) (README).
expr({bin, Anno, []}, _X, B) -> node(bytes, Anno, [<<>>], bytes, B);
expr({bin, Anno, [{bin_element, _, {string, _, S}, default, Type}]}, _X, B) when Type =:= default; Type =:= [utf8] ->
    Bytes = case Type of
                [utf8] -> unicode:characters_to_binary(S);
                default -> list_to_binary([C band 255 || C <- S])
            end,
    node(bytes, Anno, [Bytes], bytes, B);
expr({bin, Anno, _}, _X, B) -> gap(Anno, <<"bit syntax">>, B);
expr({var, Anno, '_'}, X, B) -> plain(wild, Anno, [], X, B);
expr({var, Anno, V}, _X, B = #b{vars = Vars}) ->
    {I, B1} = emit(var, Anno, [ident(V)], B),
    case Vars of
        #{V := {T, S}} -> {I, T, mark(I, S, B1)};
        _ -> {I, {unknown, note(["the variable ", atom_to_binary(V), " has no type the codex can follow (it is bound "
                                 "in a branch, or in a construct that was sent as a gap)"])}, B1}
    end;
%% --- lists (H7, H9, H10). A literal proper list is one list node; a cell with a computed tail is a cons node.
%% A string literal is what it is in Erlang: a list of character codes. A list construction must have a type
%% (T8.10 e): the common type of its elements, or the expected one.
expr({nil, Anno}, X, B) -> construction(nil, Anno, [], fit({list, none}, X, B), <<"[]">>, B, B);
expr({cons, Anno, H, T} = Cons, X, B0) ->
    EX = case expand(X, B0) of {list, E} when E =/= none -> E; _ -> any end,
    case list_elements(Cons) of
        {ok, Es} ->
            {Is, Ts, B1} = exprs(Es, EX, B0),
            construction(list, Anno, [Is, -1], fit({list, join(Ts)}, X, B1), <<"list">>, B0, B1);
        error ->
            {Hi, HT, B1} = expr(H, EX, B0),
            {Ti, TT, B2} = expr(T, X, B1),
            LT = case TT of
                     {list, E1} -> {list, join([HT, E1])};
                     {unknown, _} -> TT;
                     _ -> {unknown, note(["the tail of the list cell is ", show(TT), ", not a list"])}
                 end,
            construction(cons, Anno, [Hi, Ti], fit(LT, X, B2), <<"list cell">>, B0, B2)
    end;
expr({string, Anno, []}, _X, B) -> node(nil, Anno, [], {list, int}, B);
expr({string, Anno, S}, _X, B0) ->
    {Is, B1} = lists:mapfoldl(fun(C, B) -> emit(int, Anno, [C], B) end, B0, S),
    node(list, Anno, [Is, -1], {list, int}, B1);
expr({tuple, Anno, Es}, X, B0) ->
    Xs = case tuple_parts(expand(X, B0), Es, B0) of
             {ok, Parts} -> Parts;
             no -> lists:duplicate(length(Es), any)
         end,
    {Is, Ts, B1} = exprs_each(Es, Xs, B0),
    node(tuple, Anno, [Is], fit(tuple_type(Es, Ts), X, B1), B1);
expr({record, Anno, Name, Fields}, _X, B) -> record(Anno, Name, Fields, -1, B, B);
expr({record, Anno, Base, Name, Fields}, _X, B0 = #b{env = Env}) ->
    {BaseIdx, _, B1} = expr(Base, {named, type_name(Env#env.id, Name)}, B0),
    record(Anno, Name, Fields, BaseIdx, B0, B1);
expr({record_field, Anno, Rec, Name, {atom, _, Field}}, _X, B0 = #b{env = Env}) ->
    TN = type_name(Env#env.id, Name),
    {R, _, B1} = expr(Rec, {named, TN}, B0),
    {I, T, B2} = node(field, Anno, [R, ident(Field)], field_type(TN, Field, B1), B1),
    {I, T, mark(I, declared, B2)};
%% --- names, matching and control (H16..H19, H28..H36)
expr({match, Anno, P, E}, _X, B0) ->
    {Ei, ET, B1} = expr(E, any, B0),
    case why(ET, B1) of
        ok ->
            try
                {Pi, _, B2} = pattern(P, ET, strength(Ei, B1), #{}, B1),
                {I, T, B3} = node(match, Anno, [Pi, Ei], ET, B2),
                {I, T, mark(I, strength(Ei, B1), B3)}
            catch
                throw:{e2s_untyped, Why} -> unbound(P, Why, gap(Anno, <<"=">>, Why, B0))
            end;
        Why ->
            unbound(P, Why, gap(Anno, <<"=">>, ["the value that = binds has no type: ", Why, " (T8.10 b, e)"], B0))
    end;
expr({block, Anno, Es}, X, B0) ->
    {Is, T, B1} = sequence(Es, X, B0),
    node(block, Anno, [Is], T, B1);
expr({'case', Anno, Subject, Clauses}, X, B0) ->
    {S, ST, B1} = expr(Subject, any, B0),
    case why(ST, B1) of
        ok ->
            try
                {Cs, _, Ts, B2} = clauses('case', Clauses, [ST], strength(S, B1), X, B1),
                node('case', Anno, [S, Cs], fit(join(Ts), X, B2), B2)
            catch
                throw:{e2s_untyped, Why} -> gap(Anno, <<"case">>, Why, B0)
            end;
        Why -> gap(Anno, <<"case">>, ["its subject has no type: ", Why, " (T8.10 e)"], B0)
    end;
expr({'if', Anno, Clauses}, X, B0) ->
    {Cs, _, Ts, B1} = clauses('if', Clauses, [], inferred, X, B0),
    node('cond', Anno, [Cs], fit(join(Ts), X, B1), B1);
%% A closure needs a (:t_fun) hint (T8.10 a). Erlang writes no types on a fun: its parameters are typed by the
%% place it is passed to (a parameter of fun type in a -spec) or by type-test guards, its result by its body.
expr({'fun', Anno, {clauses, Clauses = [{clause, _, Ps0, _, _} | _]}}, X, B0) ->
    N = length(Ps0),
    {PXs, RX} = case expand(X, B0) of
                    {'fun', Ps, R} when length(Ps) =:= N -> {Ps, R};
                    _ -> {lists:duplicate(N, ?FUN_PARAM), any}
                end,
    try
        {Cs, PTs, Ts, B1} = clauses(lambda, Clauses, PXs, inferred, RX, B0),
        Params = [join(Column) || Column <- columns(PTs)],
        Result = fit(join(Ts), RX, B1),
        case why({'fun', Params, Result}, B1) of
            ok -> node(lambda, Anno, [Cs], {'fun', Params, Result}, B1);
            Why -> gap(Anno, <<"fun">>, ["its type cannot be stated: ", Why, " (T8.10 a)"], B0)
        end
    catch
        throw:{e2s_untyped, Why1} -> gap(Anno, <<"fun">>, Why1, B0)
    end;
expr({'fun', Anno, {function, Name, Arity}}, _X, B = #b{env = Env}) when is_atom(Name) ->
    fun_ref(Anno, <<>>, Env#env.mod, Name, Arity, B);
expr({'fun', Anno, {function, {atom, _, M}, {atom, _, F}, {integer, _, A}}}, _X, B) ->
    fun_ref(Anno, atom_to_binary(M), M, F, A, B);
%% --- processes and messages (H20..H26)
expr({op, Anno, '!', {tuple, _, [{atom, _, Name}, {atom, _, Node}]}, Msg}, _X, B0 = #b{env = #env{remotes = Remotes}}) ->
    %% `{Name, Node} ! Message` to a name -silica_node declared as a remote: H39 (:send_named), which the transpiler
    %% writes as a cast to the registered name; BEES's proxy for the name carries it to the peer (contract T9.17).
    case maps:find({Name, Node}, Remotes) of
        {ok, _Tag} ->
            {M1, MT, B1} = expr(Msg, any, B0),
            case why(MT, B1) of
                ok -> node(send_named, Anno, [atom_to_binary(Name), M1], MT, B1);
                Why -> gap(Anno, <<"!">>, ["the message has no type: ", Why, " (T8.10 e)"], B0)
            end;
        error ->
            gap(Anno, <<"send to a process on another node">>,
                <<"the name and node are not declared as a remote in -silica_node (a send to a pid on another node has no meaning: BEES sends to registered names)">>, B0)
    end;
expr({op, Anno, '!', {tuple, _, [_, _]}, _}, _X, B) ->
    gap(Anno, <<"send to a process on another node">>, <<"only {Name, Node} ! Message with Name and Node atoms declared as a remote in -silica_node is sent">>, B);
expr({op, Anno, '!', {atom, _, Name}, Msg}, _X, B0) ->
    %% H39: a send to a registered name. Its value is the message, as a send's is (H22, T9.14c).
    {M1, MT, B1} = expr(Msg, any, B0),
    case why(MT, B1) of
        ok -> node(send_named, Anno, [atom_to_binary(Name), M1], MT, B1);
        Why -> gap(Anno, <<"!">>, ["the message has no type: ", Why, " (T8.10 e)"], B0)
    end;
expr({op, Anno, '!', To, Msg}, _X, B0) ->
    {T, TT, B1} = expr(To, any, B0),
    MX = case expand(TT, B1) of {actor, M} when M =/= dynamic -> M; _ -> any end,
    {M1, MT, B2} = expr(Msg, MX, B1),
    case why(MT, B2) of
        ok -> node(send, Anno, [T, M1], MT, B2);
        Why -> gap(Anno, <<"!">>, ["the message has no type: ", Why, " (T8.10 e)"], B0)
    end;
expr({'receive', Anno, Clauses}, X, B) -> receive_(Anno, Clauses, none, X, B);
expr({'receive', Anno, Clauses, Timeout, After}, X, B) -> receive_(Anno, Clauses, {Timeout, After}, X, B);
%% --- operators (Appendix B). The operands' types decide what is written: see arith/5, fdiv/4, compare/5.
expr({op, _, '+', E}, X, B) -> expr(E, X, B);
expr({op, Anno, '-', {integer, _, N}}, X, B) -> expr({integer, Anno, -N}, X, B);
expr({op, Anno, '-', {float, _, F}}, X, B) -> expr({float, Anno, -F}, X, B);
expr({op, Anno, Op, E}, _X, B0) ->
    {I, T, B1} = expr(E, any, B0),
    case {Op, T} of
        {'-', N} when N =:= int; N =:= float -> node(op, Anno, [<<"neg">>, [I]], N, B1);
        {'not', boolean} -> node(op, Anno, [<<"not">>, [I]], boolean, B1);
        {'bnot', int} -> node(op, Anno, [<<"bnot">>, [I]], int, B1);
        {'-', _} -> operand_gap(Anno, <<"-">>, <<"its operand">>, T, <<"a number">>, B0);
        {'not', _} -> operand_gap(Anno, <<"not">>, <<"its operand">>, T, <<"boolean()">>, B0);
        {'bnot', _} -> operand_gap(Anno, <<"bnot">>, <<"its operand">>, T, <<"integer()">>, B0);
        _ -> gap(Anno, <<"operator ", (atom_to_binary(Op))/binary>>, B0)
    end;
expr({op, Anno, Op, L, R}, _X, B) ->
    case op_class(Op) of
        arith -> arith(Anno, Op, L, R, B);
        fdiv -> fdiv(Anno, L, R, B);
        compare -> compare(Anno, Op, L, R, B);
        {same, T} -> same_type(Anno, Op, T, L, R, B);
        append -> append(Anno, L, R, B);
        none -> gap(Anno, <<"operator ", (atom_to_binary(Op))/binary>>, B)
    end;
%% --- calls (H32..H34) and the process built-ins
expr({call, Anno, {atom, _, '$e2s_gap'}, [{string, _, Construct}, {string, _, Note}]}, _X, B) ->
    gap(Anno, Construct, Note, B);                 %% what e2s_split could not cut
expr({call, Anno, {remote, _, {atom, _, e2s_sup}, {atom, _, static_child}},
      [{atom, _, Name}, {atom, _, Restart}, {atom, _, Strategy}, {atom, _, F}, ArgList]}, _X, B) ->
    {ok, Args} = list_elements(ArgList),           %% what e2s_sup read of a supervisor start
    static_child(Anno, Name, Restart, Strategy, F, Args, B);
expr({call, Anno, {remote, _, {atom, _, supervisor}, {atom, _, start_link}}, Args}, _X, B) ->
    gap(Anno, call_name(supervisor, start_link, Args),
        <<"a supervisor is sent only as its static children (contract T9.14b), and e2s_sup could not read this "
          "one: the start must be `{ok, _} = supervisor:start_link(Name, ?MODULE, LiteralArgs)` as a statement, "
          "init/1 must build its answer without a call, and each child's start function must be spawn_link, an "
          "optional register, {ok, Pid} (README, \"A static supervisor\")">>, B);
expr({call, Anno, {remote, _, {atom, _, io}, {atom, _, format}}, [{string, _, Format} | Rest]}, _X, B)
  when length(Rest) =< 1 ->
    io_format(Anno, Format, Rest, B);
expr({call, Anno, {remote, _, {atom, _, erlang}, {atom, _, F}}, Args}, X, B) -> call(Anno, F, Args, X, B);
expr({call, Anno, {remote, _, {atom, _, M}, {atom, _, F}}, Args}, _X, B = #b{env = #env{s = #{funs := Funs}}}) ->
    case {maps:is_key({M, F, length(Args)}, Funs), module_class(M)} of
        {true, _} -> session_call(Anno, atom_to_binary(M), M, F, Args, B);
        {false, distribution} ->
            gap(Anno, call_name(M, F, Args), <<"inter-node communication is outside the proof of concept">>, B);
        {false, otp} ->
            gap(Anno, call_name(M, F, Args), <<"OTP behaviours are outside the proof of concept (contract 9.2)">>, B);
        {false, plain} -> remote_call(Anno, M, F, Args, B)
    end;
expr({call, Anno, {remote, _, M, F}, Args}, _X, B0) ->
    {Mi, _, B1} = expr(M, any, B0),
    {Fi, _, B2} = expr(F, any, B1),
    {As, _, B3} = exprs(Args, any, B2),
    {I, B4} = emit(apply_mfa, Anno, [Mi, Fi, As], B3),
    {I, {unknown, <<"a call whose module or function is computed has no -spec the codex can follow, so its result "
                    "type cannot be stated (T8.10 d)">>}, B4};
expr({call, Anno, {atom, _, F}, Args}, X, B = #b{env = Env = #env{s = #{funs := Funs}}}) ->
    Arity = length(Args),
    case maps:is_key({Env#env.mod, F, Arity}, Funs) orelse not erl_internal:bif(F, Arity) of
        true -> session_call(Anno, <<>>, Env#env.mod, F, Args, B);
        false -> call(Anno, F, Args, X, B)
    end;
expr({call, Anno, Fun, Args}, _X, B0) ->
    {F, FT, B1} = expr(Fun, any, B0),
    case expand(FT, B1) of
        {'fun', Ps, R} when length(Ps) =:= length(Args) ->
            {As, _, B2} = exprs_each(Args, Ps, B1),
            {I, T, B3} = node(apply, Anno, [F, As], R, B2),
            {I, T, mark(I, strength(F, B1), B3)};
        _ ->
            {As, _, B2} = exprs(Args, any, B1),
            {I, B3} = emit(apply, Anno, [F, As], B2),
            Why = case why(FT, B2) of
                      ok -> note(["the called value is ", show(FT), ", not a fun of ", integer_to_binary(length(Args)), " parameters"]);
                      W -> W
                  end,
            {I, {unknown, note(["a call through a fun value whose type is not stated (", Why,
                                "), so its result type cannot be stated (T8.10 d)"])}, B3}
    end;
%% --- everything else is outside the proof of concept
expr(Other, _X, B) ->
    gap(element(2, Other), construct(element(1, Other)), B).

%% A (:record), list or list cell: built in B, given up from B0 when its type cannot be stated (T8.10 e).
construction(Tag, Anno, Fields, T, What, B0, B) ->
    case why(T, B) of
        ok -> node(Tag, Anno, Fields, T, B);
        Why -> gap(Anno, What, ["its type cannot be stated: ", Why, " (T8.10 e)"], B0)
    end.

%% After a gap in place of `P = E`: P's variables are remembered as untyped, with the first cause.
unbound(P, Why, {I, T, B = #b{vars = Vars}}) ->
    Unknown = {unknown, note(Why)},
    New = maps:from_list([{V, {Unknown, inferred}} || V <- pattern_vars(P), not maps:is_key(V, Vars)]),
    {I, T, B#b{vars = maps:merge(Vars, New)}}.

pattern_vars({var, _, '_'}) -> [];
pattern_vars({var, _, V}) -> [V];
pattern_vars(T) when is_tuple(T) -> lists:append([pattern_vars(E) || E <- tuple_to_list(T)]);
pattern_vars(L) when is_list(L) -> lists:append([pattern_vars(E) || E <- L]);
pattern_vars(_) -> [].

float_text(F) -> float_to_binary(F, [short]).

%% H12: a record construction or update (Base /= -1). Field order is the source's.
record(Anno, Name, Fields, Base, B0, B1 = #b{env = Env}) ->
    TN = type_name(Env#env.id, Name),
    case [F || F <- Fields, element(1, element(3, F)) =/= atom] of
        [] ->
            {Pairs, B2} = lists:mapfoldl(fun({record_field, _, {atom, _, F}, V}, B) ->
                                                 {I, _, Bn} = expr(V, field_type(TN, F, B), B),
                                                 {{ident(F), I}, Bn}
                                         end, B1, Fields),
            {I, T, B3} = construction(record, Anno, [TN, Pairs, Base], {named, TN}, <<"record">>, B0, B2),
            {I, T, mark(I, declared, B3)};
        _ ->
            gap(Anno, <<"record with a default for all fields (_ = Value)">>, B0)
    end.

receive_(Anno, Clauses, After, X, B0) ->
    try
        {Cs, _, Ts, B1} = clauses('receive', Clauses, [?MESSAGE], inferred, X, B0),
        {Ti, Ai, ATs, B3} = case After of
                                none -> {-1, -1, [], B1};
                                {Timeout, Body} ->
                                    {T, _, B2} = expr(Timeout, int, B1),
                                    {A, AT, B3a} = body(Body, X, B2),
                                    {T, A, [AT], B3a}
                            end,
        node('receive', Anno, [Cs, Ti, Ai], fit(join(Ts ++ ATs), X, B3), B3)
    catch
        throw:{e2s_untyped, Why} -> gap(Anno, <<"receive">>, Why, B0)
    end.

%% ------------------------------------------------------------------ operators: types and conversions
%%
%% Erlang's rules, written out for the transpiler, which converts nothing (T8.11, T8.12):
%%   + - *        integer when both operands are integers; float when either is a float, and the integer operand
%%                is then converted: an integer literal is sent as a (:float), anything else under to_float
%%   /            always float: each integer operand is converted; and a guard, because Erlang fails on a zero
%%                divisor and Silica's float division does not (limitation observed, Appendix B): fdiv/4
%%   div rem      integers only; by zero both Erlang and Silica end the process (badarith): nothing is added
%%   == /= < ...  operands of one type; an integer next to a float is converted (Erlang compares the numbers)
%%   =:= =/=      operands of one type; an integer next to a float is false, or true, whatever the values
%% An operand whose type is unknown makes the operator a gap (T8.10 c).

op_class(Op) when Op =:= '+'; Op =:= '-'; Op =:= '*' -> arith;
op_class('/') -> fdiv;
op_class(Op) when Op =:= '=='; Op =:= '/='; Op =:= '<'; Op =:= '=<'; Op =:= '>'; Op =:= '>='; Op =:= '=:=';
                  Op =:= '=/=' -> compare;
op_class(Op) when Op =:= 'div'; Op =:= 'rem'; Op =:= 'band'; Op =:= 'bor'; Op =:= 'bxor'; Op =:= 'bsl'; Op =:= 'bsr' ->
    {same, int};
op_class(Op) when Op =:= 'and'; Op =:= 'or'; Op =:= 'andalso'; Op =:= 'orelse' -> {same, boolean};
op_class('++') -> append;
op_class(_) -> none.          %% -- (lists), xor

operand_gap(Anno, Op, Which, T, Want, B0) ->
    Note = case T of
               {unknown, Why} -> [Which, " has no type: ", Why, " (T8.10 c)"];
               none -> [Which, " never has a value (T8.10 c)"];
               _ -> [Which, " is ", show(T), ", not ", Want, ": Erlang fails here, and no operator of Appendix B says that"]
           end,
    gap(Anno, <<"operator ", Op/binary>>, Note, B0).

arith(Anno, Op, L, R, B0) ->
    OpB = atom_to_binary(Op),
    {Li, LT, B1} = expr(L, any, B0),
    {Ri, RT, B2} = expr(R, any, B1),
    case {number(LT), number(RT)} of
        {no, _} -> operand_gap(Anno, OpB, <<"its left operand">>, LT, <<"a number">>, B0);
        {_, no} -> operand_gap(Anno, OpB, <<"its right operand">>, RT, <<"a number">>, B0);
        {T, T} -> node(op, Anno, [OpB, [Li, Ri]], T, B2);
        _Mixed ->
            {Lf, Rf, B3} = both_float(L, R, B0),
            node(op, Anno, [OpB, [Lf, Rf]], float, B3)
    end.

number(int) -> int;
number(float) -> float;
number(_) -> no.

%% An operand of an operator that takes floats: an integer literal is written as a float literal, an integer
%% value goes under to_float (T8.12), a float stays. {ok, Index, B} | {no, Type}.
as_float({integer, Anno, N}, B0) ->
    {I, _, B} = plain(float, Anno, [float_text(float(N))], float, B0),
    {ok, I, B};
as_float(E, B0) ->
    {I, T, B1} = expr(E, any, B0),
    case T of
        float -> {ok, I, B1};
        int ->
            {F, _, B2} = node(op, element(2, E), [<<"to_float">>, [I]], float, B1),
            {ok, F, B2};
        _ -> {no, T}
    end.

%% Both operands as floats, left first. The caller has checked that both are numbers.
both_float(L, R, B0) ->
    {ok, Lf, B1} = as_float(L, B0),
    {ok, Rf, B2} = as_float(R, B1),
    {Lf, Rf, B2}.

%% Erlang's `/`. T8.15: Erlang fails the process when the divisor is zero; Silica's float division does not
%% (limitation observed), so the guard is sent:  cond Divisor == 0.0 -> fail(badarith); true -> L / Divisor.
%% Each operand is evaluated once and in Erlang's order: one that is not a variable or a literal is bound to a
%% variable of the codex first (E2s__t1: no Erlang variable is spelled so after ident/1). A literal divisor
%% other than zero needs no guard.
fdiv(Anno, L, R, B0 = #b{guard = Guard}) ->
    case Guard andalso not nonzero_literal(R) of
        true ->
            gap(Anno, <<"operator /">>,
                <<"/ in a guard: Erlang makes a failing guard false, and the zero-divisor guard the codex writes "
                  "for / (T8.15) would end the process instead">>, B0);
        false -> fdiv_(Anno, L, R, B0)
    end.

nonzero_literal({Lit, _, V}) when Lit =:= integer; Lit =:= float -> V /= 0;
nonzero_literal(_) -> false.

fdiv_(Anno, L, R, B0) ->
    case as_float(L, B0) of
        {no, LT} -> operand_gap(Anno, <<"/">>, <<"its left operand">>, LT, <<"a number">>, B0);
        {ok, Li, B1} ->
            case {as_float(R, B1), nonzero_literal(R)} of
                {{no, RT}, _} -> operand_gap(Anno, <<"/">>, <<"its right operand">>, RT, <<"a number">>, B0);
                {{ok, Ri, B2}, true} -> node(op, Anno, [<<"/">>, [Li, Ri]], float, B2);
                {{ok, _, _}, false} ->
                    {LRef, S1, Ba} = once(L, B0),
                    {RRef, S2, Bb} = once(R, Ba),
                    {D1, Bc} = again(RRef, Bb),
                    {Zero, _, Bd} = plain(float, Anno, [<<"0.0">>], float, Bc),
                    {IsZero, _, Be} = node(op, Anno, [<<"==">>, [D1, Zero]], boolean, Bd),
                    {Reason, _, Bf} = plain(symbol, Anno, [<<"badarith">>], atom, Be),
                    {Fail, _, Bg} = plain(fail, Anno, [Reason], none, Bf),
                    {C1, Bh} = emit(clause, Anno, [[], IsZero, Fail], Bg),
                    {True, _, Bi} = plain(boolean, Anno, [true], boolean, Bh),
                    {N1, Bj} = again(LRef, Bi),
                    {D2, Bk} = again(RRef, Bj),
                    {Div, _, Bl} = node(op, Anno, [<<"/">>, [N1, D2]], float, Bk),
                    {C2, Bm} = emit(clause, Anno, [[], True, Div], Bl),
                    {Cond, _, Bn} = node('cond', Anno, [[C1, C2]], float, Bm),
                    case S1 ++ S2 of
                        [] -> {Cond, float, Bn};
                        Bound -> node(block, Anno, [Bound ++ [Cond]], float, Bn)
                    end
            end
    end.

%% An operand that is used more than once. A variable or a literal is simply written again; anything else is
%% bound once: {Reference, [the match node], B}.
once(E, B0 = #b{tmp = N}) ->
    case simple(E) of
        true -> {{again, E}, [], B0};
        false -> bind_once(E, B0#b{tmp = N + 1}, N + 1)
    end.

simple(E) -> lists:member(element(1, E), [var, integer, float, char]).

bind_once(E, B0, N) ->
    Anno = element(2, E),
    Name = <<"E2s__t", (integer_to_binary(N))/binary>>,
    {ok, V, B1} = as_float(E, B0),
    {P, _, B2} = node(var, Anno, [Name], float, B1),
    {M, _, B3} = node(match, Anno, [P, V], float, B2),
    {{bound, Anno, Name}, [M], B3}.

again({again, E}, B0) -> {ok, I, B} = as_float(E, B0), {I, B};
again({bound, Anno, Name}, B) -> emit(var, Anno, [Name], B).

%% == /= < =< > >= =:= =/=. T8.11: both operands must have one stated type.
compare(Anno, Op, L, R, B0) ->
    OpB = atom_to_binary(Op),
    {Li0, LT0, B1a} = expr(L, any, B0),
    {Ri0, RT0, B2a} = expr(R, LT0, B1a),
    %% When the types differ, the left operand may be a literal or a construction that takes the right
    %% operand's type (`ok == X`, `[] == L`): it is built again with that type expected.
    {Li, LT, Ri, RT, B2} =
        case LT0 =:= RT0 orelse why(RT0, B2a) =/= ok orelse (number(LT0) =/= no andalso number(RT0) =/= no) of
            true -> {Li0, LT0, Ri0, RT0, B2a};
            false ->
                {Li1, LT1, B1b} = expr(L, RT0, B0),
                {Ri1, RT1, B2b} = expr(R, LT1, B1b),
                {Li1, LT1, Ri1, RT1, B2b}
        end,
    Exact = Op =:= '=:=' orelse Op =:= '=/=',
    case {LT, RT} of
        {{unknown, _}, _} -> operand_gap(Anno, OpB, <<"its left operand">>, LT, <<>>, B0);
        {_, {unknown, _}} -> operand_gap(Anno, OpB, <<"its right operand">>, RT, <<>>, B0);
        {none, _} -> operand_gap(Anno, OpB, <<"its left operand">>, LT, <<>>, B0);
        {_, none} -> operand_gap(Anno, OpB, <<"its right operand">>, RT, <<>>, B0);
        {T, T} -> node(op, Anno, [OpB, [Li, Ri]], boolean, B2);
        {N1, N2} when (N1 =:= int andalso N2 =:= float orelse N1 =:= float andalso N2 =:= int), Exact ->
            %% An integer is never exactly equal to a float in Erlang (Appendix B): the answer is known here.
            case simple(L) andalso simple(R) of
                true -> plain(boolean, Anno, [Op =:= '=/='], boolean, B0);
                false ->
                    {V, _, B3} = plain(boolean, Anno, [Op =:= '=/='], boolean, B2),
                    node(block, Anno, [[Li, Ri, V]], boolean, B3)      %% the operands are still evaluated
            end;
        {N1, N2} when N1 =:= int, N2 =:= float; N1 =:= float, N2 =:= int ->
            {Lf, Rf, B3} = both_float(L, R, B0),
            node(op, Anno, [OpB, [Lf, Rf]], boolean, B3);
        _ ->
            gap(Anno, <<"operator ", OpB/binary>>,
                ["its operands have different types, ", show(LT), " and ", show(RT), " (T8.11): Erlang "
                 "compares any two terms, and no operator of Appendix B does"], B0)
    end.

%% div rem, the bitwise operators, and or andalso orelse: both operands of the type T, the result too.
same_type(Anno, Op, _T, L, R, B0 = #b{guard = true}) when Op =:= 'div'; Op =:= 'rem' ->
    case nonzero_literal(R) of
        true -> same_type_(Anno, Op, int, L, R, B0);
        false ->
            gap(Anno, <<"operator ", (atom_to_binary(Op))/binary>>,
                [atom_to_binary(Op), " in a guard: Erlang makes a failing guard false, and a zero divisor would end "
                 "the process instead (T8.15)"], B0)
    end;
same_type(Anno, Op, T, L, R, B0) -> same_type_(Anno, Op, T, L, R, B0).

same_type_(Anno, Op, T, L, R, B0) ->
    OpB = atom_to_binary(Op),
    {Li, LT, B1} = expr(L, T, B0),
    {Ri, RT, B2} = expr(R, T, B1),
    case {LT, RT} of
        {T, T} -> node(op, Anno, [OpB, [Li, Ri]], T, B2);
        {T, _} -> operand_gap(Anno, OpB, <<"its right operand">>, RT, show(T), B0);
        _ -> operand_gap(Anno, OpB, <<"its left operand">>, LT, show(T), B0)
    end.

%% ++. Not an operator T8.10 c names; its value is a list construction, which needs a type (T8.10 e).
append(Anno, L, R, B0) ->
    {Li, LT, B1} = expr(L, any, B0),
    {Ri, RT, B2} = expr(R, LT, B1),
    T = case {LT, RT} of
            {{list, A}, {list, B}} -> {list, join([A, B])};
            {{list, _}, _} -> wrong_operand(<<"right">>, RT);
            _ -> wrong_operand(<<"left">>, LT)
        end,
    construction(op, Anno, [<<"++">>, [Li, Ri]], T, <<"operator ++">>, B0, B2).

wrong_operand(_Side, {unknown, _} = U) -> U;
wrong_operand(Side, T) -> {unknown, note(["the ", Side, " operand of ++ is ", show(T), ", not a list"])}.

%% ------------------------------------------------------------------ calls: results and conversions

%% A call to a function of the session (this module, or another module that is sent in the same session). Its
%% result type is the callee's -spec result (T8.10 d): the hint is :declared. Without a usable -spec the call
%% is sent with no hint, which is allowed where its value is only passed on or returned; whatever needs its
%% type becomes a gap that carries the reason given here.
session_call(Anno, ModField, Mod, F, Args, B0 = #b{env = Env}) ->
    Name = fname(Mod, F, length(Args), Env),
    MFA = {Mod, F, length(Args)},
    case fsig(MFA, Env#env.s) of
        {ok, Ps, R} ->
            {As, _, B1} = exprs_each(Args, Ps, B0),
            {I, T, B2} = node(call, Anno, [ModField, Name, As], R, B1),
            {I, T, mark(I, declared, B2)};
        Made when element(1, Made) =:= made; element(1, Made) =:= pending ->
            %% A function e2s_split made: this call's arguments say what its parameters are (gen_sigs/2).
            {Xs, R} = case Made of
                          {made, Ps, R0} -> {Ps, R0};
                          {pending, R0} -> {lists:duplicate(length(Args), any), R0}
                      end,
            {As, Ts, B1} = exprs_each(Args, Xs, B0),
            put({e2s_calls, MFA}, case get({e2s_calls, MFA}) of
                                      undefined -> Ts;
                                      Old -> [join([A, B]) || {A, B} <- lists:zip(Old, Ts)]
                                  end),
            {I, T, B2} = node(call, Anno, [ModField, Name, As], R, B1),
            {I, T, mark(I, declared, B2)};
        {no, Why} ->
            {As, _, B1} = exprs(Args, any, B0),
            {I, B2} = emit(call, Anno, [ModField, Name, As], B1),
            Kind = case ModField of <<>> -> <<"local call ">>; _ -> <<"call ">> end,
            {I, {unknown, note([Kind, call_name(ModField, F, Args), " ", Why,
                                ", so its result type cannot be stated (T8.10 d)"])}, B2}
    end.

%% A call into a module outside the session. The codex knows the results of a few functions (bif_type/3).
remote_call(Anno, M, F, Args, B0) ->
    {As, Ts, B1} = exprs(Args, any, B0),
    case bif_type(M, F, Ts) of
        {ok, T} -> node(call, Anno, [atom_to_binary(M), ident(F), As], T, B1);
        no ->
            {I, B2} = emit(call, Anno, [atom_to_binary(M), ident(F), As], B1),
            {I, {unknown, note(["call ", call_name(M, F, Args), " goes into a module that is not in this session and "
                                "is not in the codex's table of known results (bif_type/3), so its result type "
                                "cannot be stated (T8.10 d)"])}, B2}
    end.

fun_ref(Anno, ModField, Mod, F, Arity, B = #b{env = Env = #env{s = #{funs := Funs}}}) ->
    Fields = [ModField, fname(Mod, F, Arity, Env), Arity],
    case maps:find({Mod, F, Arity}, Funs) of
        {ok, {ok, Ps, R}} ->
            {I, T, B1} = node(fun_ref, Anno, Fields, {'fun', Ps, R}, B),
            {I, T, mark(I, declared, B1)};
        _ ->
            {I, B1} = emit(fun_ref, Anno, Fields, B),
            {I, {unknown, note(["fun ", call_name(ModField, F, lists:duplicate(Arity, x)),
                                " names a function with no usable -spec, so its type cannot be stated"])}, B1}
    end.

%% io:format with a literal format: Erlang's own formatting language is this sender's business, so the call is
%% sent as what it does: one L1 call of a Silica print builtin (contract T9.16) for each piece of the format,
%% then `ok`. The control sequences: ~n and ~~ are text; ~p and ~w print an integer, a float, an atom or a
%% boolean; ~b an integer; ~s a binary. The arguments are evaluated first, in Erlang's order (each one that is
%% not a variable or a literal is bound to a variable of the codex), then the pieces are printed.
%% NOT ERLANG'S OUTPUT: a float is printed by Silica's print_float64 (at most 15 decimal places, cut and not
%% rounded, where Erlang's ~p writes the shortest text that reads back: 13.333333333333334 comes out as
%% 13.333333333333333; contract T9.16).
io_format(Anno, Format, Rest, B0) ->
    Args = case Rest of
               [] -> {ok, []};
               [List] -> list_elements(List)
           end,
    try
        {ok, As} = Args,
        Pieces = format_pieces(Format, []),
        length([x || {arg, _} <- Pieces]) =:= length(As) orelse throw(<<"the format does not take the arguments given">>),
        {Refs, Binds, B1} =
            lists:foldl(fun(E, {Rs, Ms, B}) ->
                                {I, T, Bn} = expr(E, any, B),
                                why(T, Bn) =:= ok orelse throw(note(["an argument has no type: ", why(T, Bn), " (T8.10 e)"])),
                                case simple(E) orelse element(1, E) =:= atom of
                                    true -> {Rs ++ [{again, E, T}], Ms, B};
                                    false ->
                                        N = Bn#b.tmp + 1,
                                        Name = <<"E2s__t", (integer_to_binary(N))/binary>>,
                                        {P, _, B2} = node(var, Anno, [Name], T, Bn#b{tmp = N}),
                                        {M, _, B3} = node(match, Anno, [P, I], T, B2),
                                        {Rs ++ [{bound, Name, T}], Ms ++ [M], B3}
                                end
                        end, {[], [], B0}, As),
        {Prints, _, B2} =
            lists:foldl(fun({text, Text}, {Ps, Rs, B}) ->
                                {S, _, Ba} = plain(text, Anno, [unicode:characters_to_binary(Text)], text, B),
                                {P, _, Bb} = node(sl_call, Anno, [<<>>, <<"print">>, [S]], atom, Ba),
                                {Ps ++ [P], Rs, Bb};
                           ({arg, Control}, {Ps, [Ref | Rs], B}) ->
                                {V, T, Ba} = case Ref of
                                                 {again, E, T0} -> {I, _, Bx} = expr(E, any, B), {I, T0, Bx};
                                                 {bound, Name, T0} -> {I, Bx} = emit(var, Anno, [Name], B), {I, T0, Bx}
                                             end,
                                {P, Bb} = print_value(Anno, Control, V, T, Ba),
                                {Ps ++ [P], Rs, Bb}
                        end, {[], Refs, B1}, Pieces),
        {Ok, _, B3} = plain(symbol, Anno, [<<"ok">>], {atoms, [<<"ok">>]}, B2),
        node(block, Anno, [Binds ++ Prints ++ [Ok]], {atoms, [<<"ok">>]}, B3)
    catch
        throw:Why when is_binary(Why) -> gap(Anno, <<"io:format">>, Why, B0);
        error:{badmatch, error} -> gap(Anno, <<"io:format">>, <<"its arguments are not a literal list">>, B0)
    end.

format_pieces([], Acc) -> lists:reverse(Acc);
format_pieces([$~, $n | T], Acc) -> format_pieces(T, text("\n", Acc));
format_pieces([$~, $~ | T], Acc) -> format_pieces(T, text("~", Acc));
format_pieces([$~, C | T], Acc) when C =:= $p; C =:= $w; C =:= $b; C =:= $s -> format_pieces(T, [{arg, C} | Acc]);
format_pieces([$~ | _], _Acc) ->
    throw(<<"a control sequence of the format other than ~p ~w ~b ~s ~n ~~ (field widths and the other "
            "sequences are not lowered)">>);
format_pieces([C | T], Acc) -> format_pieces(T, text([C], Acc)).

text(Chars, [{text, T} | Acc]) -> [{text, T ++ Chars} | Acc];
text(Chars, Acc) -> [{text, Chars} | Acc].

%% One argument of the format as an L1 call of the Silica builtin that prints a value of its type.
print_value(Anno, Control, V, T, B0) ->
    Builtin = case {Control, T} of
                  {C, int} when C =:= $p; C =:= $w; C =:= $b -> <<"print_int64">>;
                  {C, float} when C =:= $p; C =:= $w -> <<"print_float64">>;
                  {C, boolean} when C =:= $p; C =:= $w -> <<"print_boolean">>;
                  {C, atom} when C =:= $p; C =:= $w; C =:= $s -> atom_name;
                  {C, {atoms, _}} when C =:= $p; C =:= $w; C =:= $s -> atom_name;
                  {$s, bytes} -> <<"print">>;
                  _ -> throw(note(["~", [Control], " of a value of the type ", show(T), " is not lowered (integers, "
                                   "floats, atoms and booleans with ~p or ~w, integers with ~b, binaries with ~s)"]))
              end,
    case Builtin of
        atom_name ->
            %% an atom is printed as its name. (Erlang's ~p quotes an atom that needs quotes; this does not.)
            {N, _, B1} = node(sl_call, Anno, [<<>>, <<"atom_name">>, [V]], text, B0),
            {P, _, B2} = node(sl_call, Anno, [<<>>, <<"print">>, [N]], atom, B1),
            {P, B2};
        _ ->
            {P, _, B1} = node(sl_call, Anno, [<<>>, Builtin, [V]], atom, B0),
            {P, B1}
    end.

%% The result type of a function outside the session, by Erlang's documentation: {ok, Type} | no.
%% TO EXTEND: add a clause. The arguments' types are given, so a result may depend on them (abs/1, hd/1).
bif_type(erlang, F, [_]) when F =:= is_integer; F =:= is_float; F =:= is_number; F =:= is_atom; F =:= is_boolean;
                             F =:= is_binary; F =:= is_bitstring; F =:= is_list; F =:= is_tuple; F =:= is_pid;
                             F =:= is_map; F =:= is_function; F =:= is_reference; F =:= is_port;
                             F =:= is_process_alive -> {ok, boolean};
bif_type(erlang, F, [_, _]) when F =:= is_function; F =:= is_record -> {ok, boolean};
bif_type(erlang, F, [_]) when F =:= length; F =:= byte_size; F =:= tuple_size; F =:= size; F =:= bit_size;
                             F =:= list_to_integer; F =:= binary_to_integer -> {ok, int};
bif_type(erlang, abs, [T]) when T =:= int; T =:= float -> {ok, T};
bif_type(erlang, F, [T, T]) when (F =:= min orelse F =:= max), (T =:= int orelse T =:= float) -> {ok, T};
bif_type(erlang, hd, [{list, T}]) when T =/= none -> {ok, T};
bif_type(erlang, tl, [{list, T}]) when T =/= none -> {ok, {list, T}};
bif_type(erlang, F, [_]) when F =:= atom_to_binary; F =:= integer_to_binary; F =:= float_to_binary;
                             F =:= list_to_binary -> {ok, bytes};
bif_type(erlang, F, [_]) when F =:= atom_to_list; F =:= integer_to_list; F =:= float_to_list;
                             F =:= binary_to_list -> {ok, {list, int}};
bif_type(erlang, F, [_]) when F =:= list_to_float; F =:= binary_to_float -> {ok, float};
bif_type(io, format, Args) when length(Args) >= 1, length(Args) =< 3 -> {ok, {atoms, [<<"ok">>]}};
bif_type(io, nl, []) -> {ok, {atoms, [<<"ok">>]}};
bif_type(lists, reverse, [{list, T}]) when T =/= none -> {ok, {list, T}};
bif_type(lists, append, [{list, T}, {list, T}]) when T =/= none -> {ok, {list, T}};
bif_type(lists, sum, [{list, T}]) when T =:= int; T =:= float -> {ok, T};
bif_type(lists, member, [_, {list, _}]) -> {ok, boolean};
bif_type(_, _, _) -> no.

%% A call to erlang:F. The conversions are operators (T8.12), the process built-ins have nodes of their own, the
%% rest is an ordinary call into the module erlang.
call(Anno, float, [E], _X, B0) ->
    %% float/1: an integer becomes a float; a float is the operand itself.
    case as_float(E, B0) of
        {ok, I, B1} -> {I, float, B1};
        {no, T} -> operand_gap(Anno, <<"float/1">>, <<"its operand">>, T, <<"a number">>, B0)
    end;
call(Anno, F, [E], _X, B0) when F =:= trunc; F =:= round ->
    %% trunc/1, round/1: the operators of the same names on a float; an integer is the operand itself.
    {I, T, B1} = expr(E, any, B0),
    case T of
        float -> node(op, Anno, [atom_to_binary(F), [I]], int, B1);
        int -> {I, int, B1};
        _ -> operand_gap(Anno, <<(atom_to_binary(F))/binary, "/1">>, <<"its operand">>, T, <<"a number">>, B0)
    end;
call(Anno, self, [], _X, B) -> node(self, Anno, [], {actor, dynamic}, B);
call(Anno, Spawn, [Fun], _X, B0) when Spawn =:= spawn; Spawn =:= spawn_link ->
    {F, _, B1} = expr(Fun, any, B0),
    node(spawn, Anno, [F, [], Spawn =:= spawn_link], {actor, dynamic}, B1);
call(Anno, Spawn, [{atom, _, M}, {atom, _, F}, ArgList], _X, B0)
  when Spawn =:= spawn; Spawn =:= spawn_link ->
    case list_elements(ArgList) of
        {ok, Args} ->
            {Fi, FT, B1} = fun_ref(Anno, atom_to_binary(M), M, F, length(Args), B0),
            Xs = case FT of {'fun', Ps, _} -> Ps; _ -> lists:duplicate(length(Args), any) end,
            {As, _, B2} = exprs_each(Args, Xs, B1),
            node(spawn, Anno, [Fi, As, Spawn =:= spawn_link], {actor, dynamic}, B2);
        error ->
            gap(Anno, <<"spawn with a computed argument list">>, B0)
    end;
call(Anno, Spawn, Args, _X, B)
  when Spawn =:= spawn; Spawn =:= spawn_link; Spawn =:= spawn_monitor; Spawn =:= spawn_opt; Spawn =:= spawn_request ->
    gap(Anno, call_name(erlang, Spawn, Args), <<"spawn on another node or with options is outside the proof of concept">>, B);
call(Anno, send, [To, Msg], X, B) -> expr({op, Anno, '!', To, Msg}, X, B);
call(Anno, link, [P], _X, B0) ->
    {Pi, _, B1} = expr(P, any, B0),
    node(link, Anno, [Pi], boolean, B1);
call(Anno, exit, [P, Reason], _X, B0) ->
    {Pi, _, B1} = expr(P, any, B0),
    {Ri, _, B2} = expr(Reason, any, B1),
    node(exit_signal, Anno, [Pi, Ri], boolean, B2);
call(Anno, Fail, [Reason], _X, B0) when Fail =:= exit; Fail =:= error ->
    {Ri, _, B1} = expr(Reason, any, B0),
    plain(fail, Anno, [Ri], none, B1);
call(Anno, F, Args, _X, B)
  when F =:= node; F =:= nodes; F =:= monitor_node; F =:= disconnect_node; F =:= is_alive; F =:= set_cookie;
       F =:= get_cookie ->
    gap(Anno, call_name(erlang, F, Args), <<"inter-node communication is outside the proof of concept">>, B);
call(Anno, F, Args, _X, B) when F =:= register; F =:= unregister; F =:= whereis; F =:= registered ->
    gap(Anno, call_name(erlang, F, Args),
        <<"a name is given only to a supervisor's static child, in its start function (contract T9.14b: the "
          "transpiler writes no other (:register)); a send to a name is sent (H39)">>, B);
call(Anno, F, Args, _X, B)
  when F =:= process_flag; F =:= monitor; F =:= demonitor; F =:= unlink; F =:= throw; F =:= apply ->
    gap(Anno, call_name(erlang, F, Args), B);
call(Anno, F, Args, _X, B) -> remote_call(Anno, erlang, F, Args, B).

%% A static child (contract T9.14b): a (:register) of a (:spawn) whose arguments are literals. The transpiler
%% writes it into the child list its unit's supervisor has from its start, registered under Name. The child's
%% own restart policy and its supervisor's strategy, AS THE ERLANG SOURCE WRITES THEM, are an A4.4 override on
%% the (:spawn) (T7.6). The spawn is not linked: the child is under a supervisor, which is what the link of a
%% supervisor's child is for. Its value is `true`, as register/2's is.
static_child(Anno, Name, Restart, Strategy, F, Args, B0 = #b{env = #env{mod = Mod}}) ->
    {Fi, FT, B1} = fun_ref(Anno, atom_to_binary(Mod), Mod, F, length(Args), B0),
    Xs = case FT of {'fun', Ps, _} -> Ps; _ -> lists:duplicate(length(Args), any) end,
    {As, Ts, B2} = exprs_each(Args, Xs, B1),
    case {FT, why_all(Ts, B2)} of
        {{'fun', _, _}, ok} ->
            {Si, _, B3} = node(spawn, Anno, [Fi, As, false], {actor, dynamic}, B2),
            Override = #{node => Si, requirement => a4_4, choice => chosen,
                         detail => #{params => [{<<"restart">>, atom_to_binary(Restart)},
                                                {<<"strategy">>, atom_to_binary(Strategy)}],
                                     note => <<"the child specification and the supervisor flags of init/1">>}},
            node(register, Anno, [atom_to_binary(Name), Si], boolean, B3#b{overrides = [Override | B3#b.overrides]});
        _ ->
            gap(Anno, <<"a supervisor's static child">>,
                ["the child ", atom_to_binary(Name), " runs ", atom_to_binary(F), "/", integer_to_binary(length(Args)),
                 ", which has no -spec that types its parameters, or is given an argument of another type (T9.14)"], B0)
    end.

call_name(<<>>, F, Args) -> iolist_to_binary([atom_to_binary(F), $/, integer_to_binary(length(Args))]);
call_name(M, F, Args) when is_atom(M) -> call_name(atom_to_binary(M), F, Args);
call_name(M, F, Args) -> iolist_to_binary([M, $:, atom_to_binary(F), $/, integer_to_binary(length(Args))]).

module_class(M) ->
    case lists:member(M, [rpc, erpc, global, global_group, pg, pg2, net_kernel, net_adm, slave, peer, dist_util]) of
        true -> distribution;
        false ->
            case lists:member(M, [gen_server, gen_statem, gen_event, gen_fsm, supervisor, supervisor_bridge,
                                  application, proc_lib, sys]) of
                true -> otp;
                false -> plain
            end
    end.

%% The elements of a literal proper list.
list_elements({nil, _}) -> {ok, []};
list_elements({cons, _, H, T}) ->
    case list_elements(T) of
        {ok, Es} -> {ok, [H | Es]};
        error -> error
    end;
list_elements(_) -> error.

construct(lc) -> <<"list comprehension">>;
construct(bc) -> <<"binary comprehension">>;
construct(mc) -> <<"map comprehension">>;
construct(map) -> <<"map">>;
construct('try') -> <<"try">>;
construct('catch') -> <<"catch">>;
construct('maybe') -> <<"maybe">>;
construct(record_index) -> <<"record index">>;
construct(named_fun) -> <<"named fun">>;
construct(Other) -> atom_to_binary(Other).
