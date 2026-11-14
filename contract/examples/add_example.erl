%% Worked example for the to-silica TCP transport contract, version 1 (tcp-transport-v1.md section 12).
%% Erlang is used here only because the example program is Erlang; any language may write these frames.
%%
%% Source program being sent (Erlang, file "demo.erl"):
%%
%%   1  -module(demo).
%%   2  -export([add/2]).
%%   3  -spec add(integer(), integer()) -> integer().
%%   4  add(A, B) -> A + B.
%%
%% frames/0 returns every frame the sender sends, in order. Each is passed to term_to_binary/1 and sent with a 4-byte
%% big-endian length in front (wire/0). The normative shapes are in ../tcp_transport_v1.silica; check these frames
%% with ../tools/check_frames (see ../tools/README.md).

-module(add_example).
-export([frames/0, wire/0, write_wire/1]).

frames() ->
    [
     %% M1 hello. New session, profile bees, one choice per BEES requirement (T7.1), recommended hint policy (T8.4).
     {hello, #{contract => 1,
               session => <<>>,
               sender => #{language => <<"erlang">>,
                           prefix => <<"erl_">>,
                           codex => <<"erlang-to-silica-poc">>,
                           codex_version => <<"0.1.0">>},
               options => #{profile => bees,
                            choices => [choice(a3_2, default, [{<<"release">>, <<"release_on_return">>}]),
                                        choice(a3_3, phase_field, []),
                                        choice(a3_4, back_edge, []),
                                        choice(a4_2, single_pool, [{<<"pool_size">>, <<"1024">>}]),
                                        choice(a4_3, uniform_shape, []),
                                        choice(a4_4, chosen, [{<<"restart">>, <<"transient">>},
                                                              {<<"strategy">>, <<"one_for_one">>}]),
                                        choice(a5_1, result_values, []),
                                        choice(a5_4, accept_sender_death, []),
                                        choice(a5_5, supervisor_request, []),
                                        choice(a6_8, lookup_tables, []),
                                        choice(a7_1, module_table, [])],
                            hints => #{proven => trust, declared => check, inferred => check},
                            run => #{mode => transpile, max_frame => 1048576}}}},

     %% (wait for {welcome, ...}; assume credit >= 4 and resume_from = 0)

     %% M2 unit_begin, seq 0.
     {unit_begin, #{seq => 0, unit_name => <<"demo">>, silica_unit => <<"erl_demo">>, source => <<"demo.erl">>}},

     %% M3 the function add/2, seq 1.
     %% locations: 0 = {4,1} clause, 1 = {4,5} A, 2 = {4,8} B, 3 = {4,14} A, 4 = {4,18} B, 5 = {4,16} +
     %% nodes, children before parents (T9.2): 0 pattern A, 1 pattern B, 2 A, 3 B, 4 A + B, 5 the clause
     %% types: 0 = int64, 1 = fun(int64, int64) -> int64
     %% hints: the -spec as the form's signature (node -1), strength declared (Erlang specs are not enforced).
     {form, #{seq => 1,
              unit_name => <<"demo">>,
              body => {function, #{head => #{name => <<"add">>, arity => 2, exported => true, file => <<"demo.erl">>},
                                   code => #{locations => [{4, 1}, {4, 5}, {4, 8}, {4, 14}, {4, 18}, {4, 16}],
                                             nodes => [{var, 1, <<"A">>},
                                                       {var, 2, <<"B">>},
                                                       {var, 3, <<"A">>},
                                                       {var, 4, <<"B">>},
                                                       {op, 5, <<"+">>, [2, 3]},
                                                       {clause, 0, [0, 1], -1, 4}],
                                             clauses => [5]},
                                   types => [{t_int, i64}, {t_fun, [0, 0], 0}],
                                   notes => #{hints => [#{node => -1, type => 1, strength => declared,
                                                          policy => default}],
                                              overrides => []}}}}},

     %% M4 unit_end, seq 2. One form was sent.
     {unit_end, #{seq => 2, unit_name => <<"demo">>, forms => 1}},

     %% M5 end, seq 3. No entry form: the session is a library (T9.6).
     {'end', #{seq => 3, units => 1}}
    ].

choice(Requirement, Choice, Params) ->
    #{requirement => Requirement, choice => Choice, params => Params, note => <<>>}.

%% The bytes on the wire: each frame as <<Length:32/big, (term_to_binary(Frame))/binary>>.
wire() ->
    [begin B = term_to_binary(F), <<(byte_size(B)):32/big, B/binary>> end || F <- frames()].

%% Writes the wire bytes of every frame to File, for ../tools/check_frames.
write_wire(File) ->
    ok = file:write_file(File, wire()).
