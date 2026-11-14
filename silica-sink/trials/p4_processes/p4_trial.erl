%% p4_trial: the trial of the process nodes (contract H20 to H26, 9.4a; app design 5.5). Two transpile sessions.
%%
%% Session 1, the unit `procs` (erl_procs): one function for each thing the printer writes for processes (a
%% process function with a loop, symbol and tuple messages, a guard, a send, a failure with a reason; a spawn by
%% (:fun_ref) and by (:lambda); self; a receive with a timeout from a literal and from a variable; a tail call of
%% another process function; a spawn of a function that does not receive; a send whose value is used) and one
%% for each thing it does not write, which must get its diagnostic at its own file, line and column and a
%% failing stub: a linked spawn, a link, an exit request whose reason is not a symbol, a receive that is not in
%% tail position, a receive clause that takes any message, a message with no stated type, a message that is not a
%% symbol or tagged tuple. An exit request with a symbol reason is written (the hello's a5_5 supervisor_request).
%% A static child (contract T9.14b: keep/0, keep2/0) and a send to its name (T9.14c: tell_keeper/1,
%% blow_keeper/0) are written; a (:register) of anything else is not (name/1, keep3/1).
%% The receive that is not in tail position is also sent the way the contract asks a sender to send it (T9.13a):
%% split, as mid2/0 and its continuation mid2__k1/1, which are written and run; pre/0, a piece that is not exported
%% and goes on in mid2/0, gets no note about an ordinary call of a process function. (:sl_call) of the Silica
%% print builtins is written (contract T9.16: say/1 prints a line); with an argument of another type it is T3103,
%% and a builtin that is not on the list is T4002.
%% Session 2, the unit `entry` (erl_entry): a program with an entry point (contract T9.6), whose entry function
%% is named main and is a process function.
%%
%% Run:  erl -noshell -pa <dir> -s p4_trial main <port> <file to write the two session ids to, one a line>
%% run_trials.sh then exports both units, compiles erl_procs with the caller call_procs.silica.in and runs it
%% (the output must be expected.txt), and compiles erl_entry alone and runs it (it must end by itself, status 0).
-module(p4_trial).
-export([main/1, frames/0, entry_frames/0]).

-define(UNIT, <<"procs">>).
-define(FILE_NAME, <<"procs.erl">>).

i64() -> {t_int, i64}.
dyn() -> {t_basic, dynamic}.
syms(Names) -> {t_symbols, Names}.

fn(Name, Arity, Line, Nodes, Types, Hints) -> fn(?FILE_NAME, Name, Arity, Line, Nodes, Types, Hints).

%% The same, not exported.
private({function, F = #{head := H}}) -> {function, F#{head := H#{exported := false}}}.
fn(File, Name, Arity, Line, Nodes, Types, Hints) ->
    {function, #{head => #{name => Name, arity => Arity, exported => true, file => File},
                 code => #{locations => [{Line, 1}, {Line, 9}], nodes => Nodes, clauses => [length(Nodes) - 1]},
                 types => Types,
                 notes => #{hints => [#{node => N, type => T, strength => declared, policy => default} || {N, T} <- Hints],
                            overrides => []}}}.

%% {Name, what is expected of it, the form}. Expected: ok, or {Code, Line, Column}.
forms() ->
    [
     {"add/2", ok,
      fn(<<"add">>, 2, 10,
         [{var, 0, <<"A">>}, {var, 0, <<"B">>}, {var, 0, <<"A">>}, {var, 0, <<"B">>}, {op, 0, <<"+">>, [2, 3]},
          {clause, 0, [0, 1], -1, 4}],
         [i64(), {t_fun, [0, 0], 0}], [{-1, 1}])},
     %% echo() -> receive {say, From, N} when N > 0 -> From ! {said, add(N, 1)}, echo();
     %%                   {say, From, _} -> From ! {said, 0}, echo();
     %%                   boom -> exit(kaboom);
     %%                   stop -> done end.
     {"echo/0: a process function: tuple and symbol messages, a guard, a send, a loop, a failure, an end", ok,
      fn(<<"echo">>, 0, 20,
         [{symbol, 0, <<"say">>}, {var, 0, <<"From">>}, {var, 0, <<"N">>}, {tuple, 0, [0, 1, 2]},
          {var, 0, <<"N">>}, {int, 0, 0}, {op, 0, <<">">>, [4, 5]},
          {var, 0, <<"From">>}, {symbol, 0, <<"said">>}, {var, 0, <<"N">>}, {int, 0, 1},
          {call, 0, <<>>, <<"add">>, [9, 10]}, {tuple, 0, [8, 11]}, {send, 0, 7, 12},
          {call, 0, <<>>, <<"echo">>, []}, {block, 0, [13, 14]}, {clause, 0, [3], 6, 15},
          {symbol, 0, <<"say">>}, {var, 0, <<"From">>}, {wild, 0}, {tuple, 0, [17, 18, 19]},
          {var, 0, <<"From">>}, {symbol, 0, <<"said">>}, {int, 0, 0}, {tuple, 0, [22, 23]}, {send, 0, 21, 24},
          {call, 0, <<>>, <<"echo">>, []}, {block, 0, [25, 26]}, {clause, 0, [20], -1, 27},
          {symbol, 0, <<"boom">>}, {symbol, 0, <<"kaboom">>}, {fail, 0, 30}, {clause, 0, [29], -1, 31},
          {symbol, 0, <<"stop">>}, {symbol, 0, <<"done">>}, {clause, 0, [33], -1, 34},
          {'receive', 0, [16, 28, 32, 35], -1, -1}, {clause, 0, [], -1, 36}],
         [i64(), dyn(), {t_actor, 1}, {t_tagged, <<"say">>, [2, 0]}, {t_tagged, <<"said">>, [0]}, syms([<<"done">>]),
          {t_fun, [], 5}],
         [{-1, 6}, {3, 3}, {20, 3}, {11, 0}, {12, 4}, {24, 4}])},
     %% start_echo() -> spawn(procs, echo, []).
     {"start_echo/0: a spawn of a function of the unit named by a (:fun_ref) with the unit's own module", ok,
      fn(<<"start_echo">>, 0, 28,
         [{fun_ref, 0, ?UNIT, <<"echo">>, 0}, {spawn, 0, 0, [], false}, {clause, 0, [], -1, 1}],
         [dyn(), {t_actor, 0}, {t_fun, [], 1}], [{-1, 2}, {1, 1}])},
     %% ask(N) -> E = spawn(fun() -> echo() end), E ! {say, self(), N},
     %%           receive {said, M} -> E ! stop, M after 500 -> timeout end.
     {"ask/1: a spawn by (:lambda), self, a receive with a timeout; a result type the printer cannot write", ok,
      fn(<<"ask">>, 1, 30,
         [{var, 0, <<"N">>}, {call, 0, <<>>, <<"echo">>, []}, {clause, 0, [], -1, 1}, {lambda, 0, [2]},
          {spawn, 0, 3, [], false}, {var, 0, <<"E">>}, {match, 0, 5, 4},
          {var, 0, <<"E">>}, {symbol, 0, <<"say">>}, {self, 0}, {var, 0, <<"N">>}, {tuple, 0, [8, 9, 10]},
          {send, 0, 7, 11},
          {symbol, 0, <<"said">>}, {var, 0, <<"M">>}, {tuple, 0, [13, 14]},
          {var, 0, <<"E">>}, {symbol, 0, <<"stop">>}, {send, 0, 16, 17}, {var, 0, <<"M">>}, {block, 0, [18, 19]},
          {clause, 0, [15], -1, 20}, {int, 0, 500}, {symbol, 0, <<"timeout">>},
          {'receive', 0, [21], 22, 23}, {block, 0, [6, 12, 24]}, {clause, 0, [0], -1, 25}],
         [i64(), dyn(), {t_actor, 1}, {t_tagged, <<"say">>, [2, 0]}, {t_tagged, <<"said">>, [0]},
          syms([<<"timeout">>]), {t_union, [5, 0]}, {t_fun, [0], 6}],
         [{-1, 7}, {5, 2}, {11, 3}, {15, 4}])},
     %% wait(T) -> receive never -> no after T -> late end.
     {"wait/1: a timeout that is a variable, and runs out", ok,
      fn(<<"wait">>, 1, 40,
         [{var, 0, <<"T">>}, {symbol, 0, <<"never">>}, {symbol, 0, <<"no">>}, {clause, 0, [1], -1, 2},
          {var, 0, <<"T">>}, {symbol, 0, <<"late">>}, {'receive', 0, [3], 4, 5}, {clause, 0, [0], -1, 6}],
         [i64(), syms([<<"late">>, <<"no">>]), {t_fun, [0], 1}], [{-1, 2}])},
     %% forward(To) -> receive {say, From, N} -> To ! {say, From, N}, done end.
     {"forward/1: a message built from variables", ok,
      fn(<<"forward">>, 1, 50,
         [{var, 0, <<"To">>}, {symbol, 0, <<"say">>}, {var, 0, <<"From">>}, {var, 0, <<"N">>}, {tuple, 0, [1, 2, 3]},
          {var, 0, <<"To">>}, {symbol, 0, <<"say">>}, {var, 0, <<"From">>}, {var, 0, <<"N">>}, {tuple, 0, [6, 7, 8]},
          {send, 0, 5, 9}, {symbol, 0, <<"done">>}, {block, 0, [10, 11]}, {clause, 0, [4], -1, 12},
          {'receive', 0, [13], -1, -1}, {clause, 0, [0], -1, 14}],
         [i64(), dyn(), {t_actor, 1}, {t_tagged, <<"say">>, [2, 0]}, syms([<<"done">>]), {t_fun, [2], 4}],
         [{-1, 5}, {4, 3}, {9, 3}])},
     %% relay(To) -> receive go -> forward(To) end.   The process goes on in another function: T4004.
     {"relay/1: a tail call of another process function is written, with the selective-receive warning",
      {<<"T4004">>, 55, 1},
      fn(<<"relay">>, 1, 55,
         [{var, 0, <<"To">>}, {symbol, 0, <<"go">>}, {var, 0, <<"To">>}, {call, 0, <<>>, <<"forward">>, [2]},
          {clause, 0, [1], -1, 3}, {'receive', 0, [4], -1, -1}, {clause, 0, [0], -1, 5}],
         [dyn(), {t_actor, 0}, syms([<<"done">>]), {t_fun, [1], 2}], [{-1, 3}, {3, 2}])},
     %% twice(N) -> add(N, N).   No receive; its tail call lets a process run it.
     {"twice/1: a function that does not receive, spawned as a process", ok,
      fn(<<"twice">>, 1, 60,
         [{var, 0, <<"N">>}, {var, 0, <<"N">>}, {var, 0, <<"N">>}, {call, 0, <<>>, <<"add">>, [1, 2]},
          {clause, 0, [0], -1, 3}],
         [i64(), {t_fun, [0], 0}], [{-1, 1}, {3, 0}])},
     %% start_add() -> spawn(procs, add, [1, 2]).
     {"start_add/0: a spawn with arguments of a function the unit has only as an ordinary function", ok,
      fn(<<"start_add">>, 0, 62,
         [{fun_ref, 0, ?UNIT, <<"add">>, 2}, {int, 0, 1}, {int, 0, 2}, {spawn, 0, 0, [1, 2], false},
          {clause, 0, [], -1, 3}],
         [dyn(), {t_actor, 0}, {t_fun, [], 1}], [{-1, 2}, {3, 1}])},
     %% notify(P) -> P ! stop.
     {"notify/1: a send whose value (the message) is the function's result", ok,
      fn(<<"notify">>, 1, 64,
         [{var, 0, <<"P">>}, {var, 0, <<"P">>}, {symbol, 0, <<"stop">>}, {send, 0, 1, 2}, {clause, 0, [0], -1, 3}],
         [dyn(), {t_actor, 0}, syms([<<"stop">>]), {t_fun, [1], 2}], [{-1, 3}])},
     %% kill(P) -> exit(P, kill), ok.     spare(P) -> exit(P, normal), ok.
     {"kill/1: an exit request ends the process (a5_5 supervisor_request)", ok,
      fn(<<"kill">>, 1, 66,
         [{var, 0, <<"P">>}, {var, 0, <<"P">>}, {symbol, 0, <<"kill">>}, {exit_signal, 0, 1, 2}, {symbol, 0, <<"ok">>},
          {block, 0, [3, 4]}, {clause, 0, [0], -1, 5}],
         [dyn(), {t_actor, 0}, syms([<<"ok">>]), {t_fun, [1], 2}], [{-1, 3}])},
     {"spare/1: an exit request with the reason normal does nothing", ok,
      fn(<<"spare">>, 1, 67,
         [{var, 0, <<"P">>}, {var, 0, <<"P">>}, {symbol, 0, <<"normal">>}, {exit_signal, 0, 1, 2}, {symbol, 0, <<"ok">>},
          {block, 0, [3, 4]}, {clause, 0, [0], -1, 5}],
         [dyn(), {t_actor, 0}, syms([<<"ok">>]), {t_fun, [1], 2}], [{-1, 3}])},
     %% use_ask(N) -> ask(N).   An ordinary function that calls a process function under whose name no stub
     %% stands (its result type cannot be written): written, and made a failing stub when the unit is complete.
     {"use_ask/1: an ordinary call of a process function that has no stub", ok,
      fn(<<"use_ask">>, 1, 68,
         [{var, 0, <<"N">>}, {var, 0, <<"N">>}, {call, 0, <<>>, <<"ask">>, [1]}, {clause, 0, [0], -1, 2}],
         [i64(), {t_fun, [0], 0}], [{-1, 1}, {2, 0}])},
     %% blow(P) -> P ! boom, ok.   The message is a symbol whose hint states the whole message type, as a typed
     %% language states it for a constructor of no fields: boom | stop | {said, integer()} (contract T9.12).
     {"blow/1: a symbol message whose hint states a sum that has the symbol", ok,
      fn(<<"blow">>, 1, 69,
         [{var, 0, <<"P">>}, {var, 0, <<"P">>}, {symbol, 0, <<"boom">>}, {send, 0, 1, 2}, {symbol, 0, <<"ok">>},
          {block, 0, [3, 4]}, {clause, 0, [0], -1, 5}],
         [dyn(), {t_actor, 0}, syms([<<"ok">>]), i64(), {t_tagged, <<"said">>, [3]}, syms([<<"boom">>, <<"stop">>]),
          {t_union, [5, 4]}, {t_fun, [1], 2}],
         [{-1, 7}, {2, 6}])},
     %% --- not written: each a failing stub and a diagnostic at the node
     {"linked/0: a spawn with link true", {<<"T4002">>, 70, 9},
      fn(<<"linked">>, 0, 70,
         [{fun_ref, 0, ?UNIT, <<"echo">>, 0}, {spawn, 1, 0, [], true}, {clause, 0, [], -1, 1}],
         [dyn(), {t_actor, 0}, {t_fun, [], 1}], [{-1, 2}, {1, 1}])},
     {"link_to/1: a link", {<<"T4002">>, 71, 9},
      fn(<<"link_to">>, 1, 71,
         [{var, 0, <<"P">>}, {var, 0, <<"P">>}, {link, 1, 1}, {symbol, 0, <<"ok">>}, {block, 0, [2, 3]},
          {clause, 0, [0], -1, 4}],
         [dyn(), {t_actor, 0}, syms([<<"ok">>]), {t_fun, [1], 2}], [{-1, 3}])},
     %% kill_why(P, R) -> exit(P, R), ok.
     {"kill_why/2: an exit request whose reason is not a symbol", {<<"T4002">>, 72, 9},
      fn(<<"kill_why">>, 2, 72,
         [{var, 0, <<"P">>}, {var, 0, <<"R">>}, {var, 0, <<"P">>}, {var, 0, <<"R">>}, {exit_signal, 1, 2, 3},
          {symbol, 0, <<"ok">>}, {block, 0, [4, 5]}, {clause, 0, [0, 1], -1, 6}],
         [dyn(), {t_actor, 0}, syms([<<"ok">>]), syms([<<"kill">>, <<"normal">>]), {t_fun, [1, 3], 2}], [{-1, 4}])},
     %% mid() -> X = receive {said, N} -> N end, X + 1.
     {"mid/0: a receive that is not in tail position", {<<"T4002">>, 73, 9},
      fn(<<"mid">>, 0, 73,
         [{symbol, 0, <<"said">>}, {var, 0, <<"N">>}, {tuple, 0, [0, 1]}, {var, 0, <<"N">>}, {clause, 0, [2], -1, 3},
          {'receive', 1, [4], -1, -1}, {var, 0, <<"X">>}, {match, 0, 6, 5}, {var, 0, <<"X">>}, {int, 0, 1},
          {op, 0, <<"+">>, [8, 9]}, {block, 0, [7, 10]}, {clause, 0, [], -1, 11}],
         [i64(), {t_tagged, <<"said">>, [0]}, {t_fun, [], 0}], [{-1, 2}, {2, 1}, {6, 0}])},
     %% The same function as the sender must send it (contract T9.13a): split at the receive.
     %% mid2() -> receive {said, N} -> mid2__k1(N) end.      mid2__k1(X) -> X + 1.
     {"mid2/0: the receive in tail position, its clause going on in the continuation", {<<"T4004">>, 80, 1},
      fn(<<"mid2">>, 0, 80,
         [{symbol, 0, <<"said">>}, {var, 0, <<"N">>}, {tuple, 0, [0, 1]}, {var, 0, <<"N">>},
          {call, 0, <<>>, <<"mid2__k1">>, [3]}, {clause, 0, [2], -1, 4}, {'receive', 0, [5], -1, -1},
          {clause, 0, [], -1, 6}],
         [i64(), {t_tagged, <<"said">>, [0]}, {t_fun, [], 0}], [{-1, 2}, {2, 1}, {4, 0}])},
     {"mid2__k1/1: the code after the receive, a function of its own", ok,
      fn(<<"mid2__k1">>, 1, 81,
         [{var, 0, <<"X">>}, {var, 0, <<"X">>}, {int, 0, 1}, {op, 0, <<"+">>, [1, 2]}, {clause, 0, [0], -1, 3}],
         [i64(), {t_fun, [0], 0}], [{-1, 1}])},
     %% pre() -> mid2().   Not exported: a piece of a process. It is written twice (as an ordinary function and in
     %% tail mode); nothing calls its ordinary version, so its call of mid2 is no ordinary call anybody makes.
     {"pre/0: a function that is not exported and goes on in a process function", ok,
      private(fn(<<"pre">>, 0, 82,
                 [{call, 0, <<>>, <<"mid2">>, []}, {clause, 0, [], -1, 0}],
                 [i64(), {t_fun, [], 0}], [{-1, 1}, {0, 0}]))},
     %% say(N) -> print("say: n = "), print_int64(N), println(""), ok.   L1: Silica's print builtins (T9.16).
     {"say/1: (:sl_call) of the Silica print builtins", ok,
      fn(<<"say">>, 1, 83,
         [{var, 0, <<"N">>}, {text, 0, <<"say: n = ">>}, {sl_call, 0, <<>>, <<"print">>, [1]}, {var, 0, <<"N">>},
          {sl_call, 0, <<>>, <<"print_int64">>, [3]}, {text, 0, <<>>}, {sl_call, 0, <<>>, <<"println">>, [5]},
          {symbol, 0, <<"ok">>}, {block, 0, [2, 4, 6, 7]}, {clause, 0, [0], -1, 8}],
         [i64(), syms([<<"ok">>]), {t_fun, [0], 1}], [{-1, 2}])},
     %% bad_print(F) -> print_int64(F).   F is a float: the builtin takes an integer, and nothing is converted
     %% (the diagnostic is the argument's: its place, the builtin's parameter, states int64).
     {"bad_print/1: (:sl_call) with an argument of another type than the builtin takes", {<<"T3103">>, 84, 9},
      fn(<<"bad_print">>, 1, 84,
         [{var, 0, <<"F">>}, {var, 1, <<"F">>}, {sl_call, 0, <<>>, <<"print_int64">>, [1]}, {clause, 0, [0], -1, 2}],
         [{t_float, f64}, {t_basic, symbol}, {t_fun, [0], 1}], [{-1, 2}])},
     {"bad_builtin/0: (:sl_call) of a builtin that is not on the list", {<<"T4002">>, 85, 9},
      fn(<<"bad_builtin">>, 0, 85,
         [{sl_call, 1, <<>>, <<"halt">>, []}, {clause, 0, [], -1, 0}],
         [{t_basic, symbol}, {t_fun, [], 0}], [{-1, 1}])},
     %% any() -> receive X -> X end.
     {"any/0: a receive clause that takes any message", {<<"T4002">>, 74, 9},
      fn(<<"any">>, 0, 74,
         [{var, 1, <<"X">>}, {var, 0, <<"X">>}, {clause, 0, [0], -1, 1}, {'receive', 0, [2], -1, -1},
          {clause, 0, [], -1, 3}],
         [i64(), {t_fun, [], 0}], [{-1, 1}, {0, 0}])},
     {"untyped_msg/0: a message pattern with no stated type", {<<"T3101">>, 75, 9},
      fn(<<"untyped_msg">>, 0, 75,
         [{symbol, 0, <<"said">>}, {var, 0, <<"N">>}, {tuple, 1, [0, 1]}, {var, 0, <<"N">>}, {clause, 0, [2], -1, 3},
          {'receive', 0, [4], -1, -1}, {clause, 0, [], -1, 5}],
         [i64(), {t_fun, [], 0}], [{-1, 1}])},
     %% tell(P) -> P ! {said, 1}.   with the result type ok: the value of a send is the message (contract H22)
     {"tell/1: a send whose value is stated as another type than the message", {<<"T3103">>, 77, 9},
      fn(<<"tell">>, 1, 77,
         [{var, 0, <<"P">>}, {var, 0, <<"P">>}, {symbol, 0, <<"said">>}, {int, 0, 1}, {tuple, 0, [2, 3]},
          {send, 1, 1, 4}, {clause, 0, [0], -1, 5}],
         [dyn(), {t_actor, 0}, i64(), {t_tagged, <<"said">>, [2]}, syms([<<"ok">>]), {t_fun, [1], 4}],
         [{-1, 5}, {4, 3}])},
     %% bad_send(P) -> P ! 42, ok.
     {"bad_send/1: a message that is not a symbol or a tagged tuple", {<<"T4002">>, 76, 9},
      fn(<<"bad_send">>, 1, 76,
         [{var, 0, <<"P">>}, {var, 0, <<"P">>}, {int, 1, 42}, {send, 0, 1, 2}, {symbol, 0, <<"ok">>},
          {block, 0, [3, 4]}, {clause, 0, [0], -1, 5}],
         [dyn(), {t_actor, 0}, syms([<<"ok">>]), {t_fun, [1], 2}], [{-1, 3}])},
     %% --- a static child (contract T9.14b) and a send to its name (H39, T9.14c)
     %% keep() -> register(keeper, spawn(fun echo/0)), ok.     the child `keeper` of the unit's supervisor, from its
     %% start; the A4.4 override on the (:spawn) is the child's own restart policy
     {"keep/0: a static child: (:register) of a (:spawn) with an A4.4 override", ok,
      overrides(fn(<<"keep">>, 0, 90,
                   [{fun_ref, 0, <<>>, <<"echo">>, 0}, {spawn, 0, 0, [], false}, {register, 0, <<"keeper">>, 1},
                    {symbol, 0, <<"ok">>}, {block, 0, [2, 3]}, {clause, 0, [], -1, 4}],
                   [syms([<<"ok">>]), {t_fun, [], 0}, {t_basic, boolean}], [{-1, 1}, {2, 2}]),
                [{1, <<"transient">>, <<"one_for_one">>}])},
     %% keep2() -> register(idler, spawn(fun wait/1, [50])), ok.   a second static child, with a literal argument;
     %% nothing calls keep2/0: the child is in the supervisor's list all the same. Its override states a strategy
     %% that is not the session's: reported (T2001, on the unit), not followed.
     {"keep2/0: a static child with a literal argument; its strategy is not the unit's", ok,
      overrides(fn(<<"keep2">>, 0, 91,
                   [{fun_ref, 0, <<>>, <<"wait">>, 1}, {int, 0, 50}, {spawn, 0, 0, [1], false},
                    {register, 0, <<"idler">>, 2}, {symbol, 0, <<"ok">>}, {block, 0, [3, 4]}, {clause, 0, [], -1, 5}],
                   [syms([<<"ok">>]), {t_fun, [], 0}, {t_basic, boolean}], [{-1, 1}, {3, 2}]),
                [{2, <<"temporary">>, <<"one_for_all">>}])},
     %% tell_keeper(N) -> keeper ! {say, self(), N}, ok.
     {"tell_keeper/1: a send to a registered name, a tuple message", ok,
      fn(<<"tell_keeper">>, 1, 92,
         [{var, 0, <<"N">>}, {symbol, 0, <<"say">>}, {self, 0}, {var, 0, <<"N">>}, {tuple, 0, [1, 2, 3]},
          {send_named, 0, <<"keeper">>, 4}, {symbol, 0, <<"ok">>}, {block, 0, [5, 6]}, {clause, 0, [0], -1, 7}],
         [i64(), dyn(), {t_actor, 1}, {t_tagged, <<"say">>, [2, 0]}, syms([<<"ok">>]), {t_fun, [0], 4}],
         [{-1, 5}, {4, 3}])},
     %% blow_keeper() -> keeper ! boom, ok.
     {"blow_keeper/0: a send to a registered name, a symbol message", ok,
      fn(<<"blow_keeper">>, 0, 93,
         [{symbol, 0, <<"boom">>}, {send_named, 0, <<"keeper">>, 0}, {symbol, 0, <<"ok">>}, {block, 0, [1, 2]},
          {clause, 0, [], -1, 3}],
         [syms([<<"ok">>]), {t_fun, [], 0}], [{-1, 1}])},
     %% name(P) -> register(someone, P), ok.
     {"name/1: a (:register) of a process that is running", {<<"T4002">>, 94, 9},
      fn(<<"name">>, 1, 94,
         [{var, 0, <<"P">>}, {var, 0, <<"P">>}, {register, 1, <<"someone">>, 1}, {symbol, 0, <<"ok">>},
          {block, 0, [2, 3]}, {clause, 0, [0], -1, 4}],
         [dyn(), {t_actor, 0}, syms([<<"ok">>]), {t_fun, [1], 2}, {t_basic, boolean}], [{-1, 3}, {2, 4}])},
     %% keep3(T) -> register(late, spawn(fun wait/1, [T])), ok.
     {"keep3/1: a (:register) of a (:spawn) whose argument is not a literal", {<<"T4002">>, 95, 9},
      fn(<<"keep3">>, 1, 95,
         [{var, 0, <<"T">>}, {fun_ref, 0, <<>>, <<"wait">>, 1}, {var, 0, <<"T">>}, {spawn, 0, 1, [2], false},
          {register, 1, <<"late">>, 3}, {symbol, 0, <<"ok">>}, {block, 0, [4, 5]}, {clause, 0, [0], -1, 6}],
         [i64(), syms([<<"ok">>]), {t_fun, [0], 1}, {t_basic, boolean}], [{-1, 2}, {4, 3}])}
    ].

%% The form with A4.4 overrides (contract T7.6): {the (:spawn) node, restart, strategy}.
overrides({function, F = #{notes := Notes}}, Os) ->
    {function, F#{notes := Notes#{overrides := [#{node => Node, requirement => a4_4, choice => chosen,
                                                  detail => #{params => [{<<"restart">>, Restart}, {<<"strategy">>, Strategy}],
                                                              note => <<"the child's specification">>}}
                                                || {Node, Restart, Strategy} <- Os]}}}.

frames() ->
    Forms = forms(),
    N = length(Forms),
    [{unit_begin, #{seq => 0, unit_name => ?UNIT, silica_unit => <<"erl_procs">>, source => ?FILE_NAME}}] ++
        [{form, #{seq => Seq, unit_name => ?UNIT, body => Body}} || {Seq, {_, _, Body}} <- lists:zip(lists:seq(1, N), Forms)] ++
        [{unit_end, #{seq => N + 1, unit_name => ?UNIT, forms => N}}, {'end', #{seq => N + 2, units => 1}}].

%% server() -> receive {inc, From, N} -> From ! {res, N + 1}, server(); stop -> ok end.
%% main() -> S = spawn(fun() -> server() end), S ! {inc, self(), 41}, receive {res, 42} -> S ! stop, ok end.
%% The program ends only when main has received {res, 42}.
entry_forms() ->
    F = <<"entry.erl">>,
    [fn(F, <<"server">>, 0, 3,
        [{symbol, 0, <<"inc">>}, {var, 0, <<"From">>}, {var, 0, <<"N">>}, {tuple, 0, [0, 1, 2]},
         {var, 0, <<"From">>}, {symbol, 0, <<"res">>}, {var, 0, <<"N">>}, {int, 0, 1}, {op, 0, <<"+">>, [6, 7]},
         {tuple, 0, [5, 8]}, {send, 0, 4, 9}, {call, 0, <<>>, <<"server">>, []}, {block, 0, [10, 11]},
         {clause, 0, [3], -1, 12},
         {symbol, 0, <<"stop">>}, {symbol, 0, <<"ok">>}, {clause, 0, [14], -1, 15},
         {'receive', 0, [13, 16], -1, -1}, {clause, 0, [], -1, 17}],
        [i64(), dyn(), {t_actor, 1}, {t_tagged, <<"inc">>, [2, 0]}, {t_tagged, <<"res">>, [0]}, syms([<<"ok">>]),
         {t_fun, [], 5}],
        [{-1, 6}, {3, 3}, {9, 4}]),
     fn(F, <<"main">>, 0, 6,
        [{call, 0, <<>>, <<"server">>, []}, {clause, 0, [], -1, 0}, {lambda, 0, [1]}, {spawn, 0, 2, [], false},
         {var, 0, <<"S">>}, {match, 0, 4, 3},
         {var, 0, <<"S">>}, {symbol, 0, <<"inc">>}, {self, 0}, {int, 0, 41}, {tuple, 0, [7, 8, 9]}, {send, 0, 6, 10},
         {symbol, 0, <<"res">>}, {int, 0, 42}, {tuple, 0, [12, 13]},
         {var, 0, <<"S">>}, {symbol, 0, <<"stop">>}, {send, 0, 15, 16}, {symbol, 0, <<"ok">>}, {block, 0, [17, 18]},
         {clause, 0, [14], -1, 19}, {'receive', 0, [20], -1, -1}, {block, 0, [5, 11, 21]}, {clause, 0, [], -1, 22}],
        [i64(), dyn(), {t_actor, 1}, {t_tagged, <<"inc">>, [2, 0]}, {t_tagged, <<"res">>, [0]}, syms([<<"ok">>]),
         {t_fun, [], 5}],
        [{-1, 6}, {4, 2}, {10, 3}, {14, 4}]),
     {entry, #{function => <<"main">>, arity => 0}}].

entry_frames() ->
    Forms = entry_forms(),
    N = length(Forms),
    [{unit_begin, #{seq => 0, unit_name => <<"entry">>, silica_unit => <<"erl_entry">>, source => <<"entry.erl">>}}] ++
        [{form, #{seq => Seq, unit_name => <<"entry">>, body => Body}} || {Seq, Body} <- lists:zip(lists:seq(1, N), Forms)] ++
        [{unit_end, #{seq => N + 1, unit_name => <<"entry">>, forms => N}}, {'end', #{seq => N + 2, units => 1}}].

%% ------------------------------------------------------------------ the sessions

recv(S) ->
    case gen_tcp:recv(S, 0, 120000) of
        {ok, Bin} -> binary_to_term(Bin);
        {error, Why} -> Why
    end.

go(S, [], _Credit, Acc) -> finish(S, Acc);
go(S, Frames, 0, Acc) ->
    case recv(S) of
        {credit, N} -> go(S, Frames, N, Acc);
        Other when is_atom(Other) -> lists:reverse([Other | Acc]);
        Other -> go(S, Frames, 0, [Other | Acc])
    end;
go(S, [F | Rest], Credit, Acc) ->
    ok = gen_tcp:send(S, term_to_binary(F)),
    go(S, Rest, Credit - 1, Acc).

finish(S, Acc) ->
    case recv(S) of
        {result, _} = R -> lists:reverse([R | Acc]);
        Other when is_atom(Other) -> lists:reverse([Other | Acc]);
        Other -> finish(S, [Other | Acc])
    end.

%% The hello of the contract's worked example, with a pool of 8 child ids (a4_2 single_pool, pool_size).
hello() ->
    p0_trial:hello(transpile,
                   fun(H) ->
                           O = maps:get(options, H),
                           H#{options := O#{choices := [case C of
                                                            #{requirement := a4_2} -> C#{params := [{<<"pool_size">>, <<"8">>}]};
                                                            _ -> C
                                                        end || C <- maps:get(choices, O)]}}
                   end).

session(Port, Frames) ->
    {ok, S} = gen_tcp:connect("127.0.0.1", Port, [binary, {packet, 4}, {active, false}]),
    ok = gen_tcp:send(S, term_to_binary(hello())),
    {welcome, #{session := Id, flow := #{credit := Credit}}} = recv(S),
    Replies = go(S, Frames, Credit, []),
    gen_tcp:close(S),
    {Id, Replies}.

main([PortArg, IdFile]) ->
    Port = list_to_integer(atom_to_list(PortArg)),
    {Id, Replies} = session(Port, frames()),
    Forms = forms(),
    Diags = [D || {diagnostic, D} <- Replies],
    check("procs: no frame is rejected", [R || {rejected, _} = R <- Replies] =:= [], Replies),
    lists:foreach(
      fun({Seq, {Name, Expect, _}}) ->
              Mine = [{C, L, Col, Sev} || #{seq := Q, finding := #{code := C, severity := Sev},
                                             place := #{line := L, column := Col}} <- Diags, Q =:= Seq],
              case Expect of
                  ok -> check(Name ++ ": written, no diagnostic", Mine =:= [], Mine);
                  {Code, Line, Column} ->
                      Sev = case Code of <<"T31", _/binary>> -> error; _ -> warning end,
                      check(lists:flatten(io_lib:format("~s: ~s at ~s:~b:~b", [Name, Code, ?FILE_NAME, Line, Column])),
                            Mine =:= [{Code, Line, Column, Sev}], Mine)
              end
      end, lists:zip(lists:seq(1, length(Forms)), Forms)),
    Messages = [M || #{finding := #{message := M}} <- Diags],
    Has = fun(Part) -> lists:any(fun(M) -> binary:match(M, Part) =/= nomatch end, Messages) end,
    check("procs: the diagnostics name the construct",
          Has(<<"(:spawn) with link true">>) andalso Has(<<"(:link)">>) andalso Has(<<"(:exit_signal)">>)
          andalso Has(<<"its reason is not a (:symbol)">>)
          andalso Has(<<"(:receive)">>) andalso Has(<<"the message pattern (:var) of a receive clause">>)
          andalso Has(<<"the message pattern (:tuple) of a receive clause">>)
          andalso Has(<<"the message (:int) of a send">>)
          andalso Has(<<"(:sl_call) of halt">>)
          andalso Has(<<"its process is not a (:spawn)">>) andalso Has(<<"an argument of the spawn is not a literal">>), Messages),
    check("procs: the static child whose A4.4 override states another strategy than the unit's supervisor has is named in the T2001 (contract T9.14b)",
          Has(<<"the a4_4 override of the static child idler states the strategy one_for_all, which is not followed">>), Messages),
    check("procs: the receive that is not in tail position tells the sender to split the function (contract T9.13a)",
          Has(<<"THE SENDER MUST SPLIT THE FUNCTION AT THIS RECEIVE (contract T9.13a)">>), Messages),
    check("procs: no note about an ordinary call of mid2/0: its only caller is the ordinary version of a piece nothing calls",
          not Has(<<"the function mid2/0 receives">>), Messages),
    check("procs: one T2001 diagnostic names the lowering choices the unit does not follow (contract T7.5)",
          length([C || #{finding := #{code := C}} <- Diags, C =:= <<"T2001">>]) =:= 1 andalso Has(<<"a3_4 ">>), Messages),
    check("procs: a T4002 on the unit says that a function calls ask, under whose name nothing stands, and is a failing stub",
          length([M || #{seq := Q, finding := #{code := <<"T4002">>, message := M}} <- Diags, Q =:= length(Forms) + 1,
                       binary:match(M, <<"calls ask">>) =/= nomatch]) =:= 1, Messages),
    Bad = length([E || {_, {C, _, _} = E, _} <- Forms, C =/= <<"T4004">>]) + 1,
    Result = [R || {result, R} <- Replies],
    check("procs: the result is partial, one file, and counts each unwritten form and the unit's T4002 as a gap (T4004 and T2001 are none)",
          case Result of
              [#{status := partial, files := 1, counts := #{units := 1, gaps := Bad, rejected := 0}}] -> true;
              _ -> false
          end, Result),
    {Id2, Replies2} = session(Port, entry_frames()),
    Codes2 = [C || {diagnostic, #{finding := #{code := C}}} <- Replies2],
    check("entry: every form is written and main is written for the entry point: the result is ok, no gap",
          case [R || {result, R} <- Replies2] of
              [#{status := ok, files := 1, counts := #{units := 1, gaps := 0, rejected := 0}}] -> Codes2 -- [<<"T2001">>] =:= [];
              _ -> false
          end, Replies2),
    ok = file:write_file(atom_to_list(IdFile), [Id, "\n", Id2, "\n"]),
    case get(failed) of
        true -> halt(1);
        _ -> halt(0)
    end.

check(Name, true, _) -> io:format("ok    ~s~n", [Name]);
check(Name, _, Got) -> put(failed, true), io:format("FAIL  ~s~n      got ~p~n", [Name, Got]).
