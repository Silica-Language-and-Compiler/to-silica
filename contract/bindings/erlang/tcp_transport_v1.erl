%% tcp_transport_v1 (Erlang binding): Erlang type declarations for the frames of the to-silica TCP transport contract.
%%
%% DERIVED AND NON-NORMATIVE. The normative schema is ../../tcp_transport_v1.silica. This binding is a convenience for
%% senders written in a BEAM language, on equal footing with bindings for any other language. If it disagrees with
%% the Silica schema, the Silica schema is right and this file is wrong.
%%
%% Mapping: atom literal -> ETF atom; binary() -> BINARY_EXT; integer() -> int64; {A, B} -> tuple; [T] -> proper list;
%% #{k := T} -> MAP_EXT with exactly these atom keys. 'end', 'case', 'cond', 'receive', 'try' are quoted only because
%% they are Erlang reserved words; on the wire they are ordinary atoms.
%%
%% check_frame.erl beside this file checks a term against these types.

-module(tcp_transport_v1).

-export_type([frame_to_transpiler/0, frame_to_sender/0, form/0, ast_node/0, type_node/0]).

-type idx()      :: integer().
-type seq()      :: non_neg_integer().
-type count()    :: non_neg_integer().
-type location() :: {integer(), integer()}.
-type param()    :: {binary(), binary()}.
-type policy()   :: trust | check | advisory.

-type requirement() :: a3_2 | a3_3 | a3_4 | a4_2 | a4_3 | a4_4 | a5_1 | a5_4 | a5_5 | a6_8 | a7_1.
-type choice_name() :: lowered | default | phase_field | continuation_table | back_edge | budget_counter | none
                     | single_pool | pool_tree | one_per_shape | uniform_shape | chosen | result_values
                     | result_variants | mixed | rejected | proxy | liveness_check | accept_sender_death
                     | silica_link | supervisor_request | not_supported | lookup_tables | module_table
                     | own_dispatch | other | not_applicable.
-type choice()   :: #{requirement := requirement(), choice := choice_name(), params := [param()], note := binary()}.
-type override() :: #{node := idx(), requirement := requirement(), choice := choice_name(),
                      detail := #{params := [param()], note := binary()}}.
-type hint()     :: #{node := idx(), type := idx(), strength := proven | declared | inferred,
                      policy := default | policy()}.

%% sender or driver -> transpiler (M1..M7)
-type frame_to_transpiler() ::
        {hello, #{contract := integer(), session := binary(),
                  sender := #{language := binary(), prefix := binary(), codex := binary(), codex_version := binary()},
                  options := #{profile := bees | silica, choices := [choice()],
                               hints := #{proven := policy(), declared := policy(), inferred := policy()},
                               run := #{mode := transpile | check, max_frame := integer()}}}}
      | {unit_begin, #{seq := seq(), unit_name := binary(), silica_unit := binary(), source := binary()}}
      | {form, #{seq := seq(), unit_name := binary(), body := form()}}
      | {unit_end, #{seq := seq(), unit_name := binary(), forms := count()}}
      | {'end', #{seq := seq(), units := count()}}
      | {abort, #{reason := binary()}}
      | {release, #{session := binary()}}.

%% transpiler -> sender (R1..R9)
-type frame_to_sender() ::
        {welcome, #{session := binary(), contract := integer(), transpiler := binary(),
                    flow := #{resume_from := seq(), credit := count(), max_frame := integer()}}}
      | {refused, #{reason := contract | session_mismatch | unknown_session | busy | choices | bad_hello,
                    detail := binary()}}
      | {credit, integer()}
      | {stored, integer()}
      | {rejected, #{seq := integer(), reason := atom(), where := binary()}}
      | {progress, #{stage := resolve | hints | lower | mechanics | print | write, unit_name := binary()}}
      | {diagnostic, #{seq := integer(), unit_name := binary(),
                       finding := #{severity := error | warning | note, code := binary(), message := binary()},
                       place := #{file := binary(), line := integer(), column := integer()}}}
      | {result, #{status := ok | partial | failed,
                   counts := #{units := count(), gaps := count(), rejected := count()},
                   session := binary(), files := count()}}
      | {released, #{session := binary(), freed := boolean()}}.

-type form() ::
        {function, #{head := #{name := binary(), arity := integer(), exported := boolean(), file := binary()},
                     code := #{locations := [location()], nodes := [ast_node()], clauses := [idx()]},
                     types := [type_node()],
                     notes := #{hints := [hint()], overrides := [override()]}}}
      | {type, #{head := #{name := binary(), params := [binary()], exported := boolean(), file := binary()},
                 at_line := integer(), types := [type_node()], root := idx()}}
      | {node, #{name := binary(), timing := #{creation := integer(), net_ticktime_s := integer(),
                                       redial_initial_ms := integer(), redial_max_ms := integer()},
                 net := #{listen_address := binary(), listen_port := integer(), epmd_port := integer(), cookie_file := binary()},
                 tables := #{peers := [#{name := binary(), host := binary(), port := integer(), role := dial | listen}],
                             remotes := [#{name := binary(), peer := binary(), tag := binary(), fields := [binary()]}],
                             locals := [#{name := binary(), tag := binary(), fields := [binary()]}]}}}
      | {entry, #{function := binary(), arity := integer()}}
      | {gap, #{name := binary(), place := #{file := binary(), line := integer()}, construct := binary(),
                note := binary()}}.

-type type_node() ::
        {t_int, i8 | i16 | i32 | i64 | u8 | u16 | u32 | u64} | {t_float, f32 | f64}
      | {t_basic, boolean | char | text | bytes | symbol | dynamic}
      | {t_symbols, [binary()]} | {t_tuple, [idx()]} | {t_tagged, binary(), [idx()]}
      | {t_record, [{binary(), idx()}]} | {t_list, idx()} | {t_union, [idx()]} | {t_fun, [idx()], idx()}
      | {t_actor, idx()} | {t_named, binary(), [idx()]} | {t_var, binary()}.

-type ast_node() ::
        {int, idx(), integer()} | {float, idx(), binary()} | {text, idx(), binary()} | {bytes, idx(), binary()}
      | {symbol, idx(), binary()} | {boolean, idx(), boolean()} | {nil, idx()} | {tuple, idx(), [idx()]}
      | {cons, idx(), idx(), idx()} | {list, idx(), [idx()], idx()} | {map, idx(), [{idx(), idx()}], idx()}
      | {record, idx(), binary(), [{binary(), idx()}], idx()} | {field, idx(), idx(), binary()}
      | {bits, idx(), [idx()]}
      | {segment, idx(), idx(), idx(), integer(), integer | float | binary | utf8, boolean(), big | little}
      | {var, idx(), binary()} | {wild, idx()} | {match, idx(), idx(), idx()} | {block, idx(), [idx()]}
      | {'case', idx(), idx(), [idx()]} | {clause, idx(), [idx()], idx(), idx()} | {'cond', idx(), [idx()]}
      | {op, idx(), binary(), [idx()]} | {call, idx(), binary(), binary(), [idx()]}
      | {apply, idx(), idx(), [idx()]} | {apply_mfa, idx(), idx(), idx(), [idx()]}
      | {fun_ref, idx(), binary(), binary(), integer()} | {lambda, idx(), [idx()]} | {loop_hint, idx(), idx()}
      | {self, idx()} | {spawn, idx(), idx(), [idx()], boolean()} | {send, idx(), idx(), idx()}
      | {'receive', idx(), [idx()], idx(), idx()} | {link, idx(), idx()} | {exit_signal, idx(), idx(), idx()}
      | {fail, idx(), idx()} | {'try', idx(), idx(), [idx()], [idx()], idx()}
      | {register, idx(), binary(), idx()} | {send_named, idx(), binary(), idx()}
      | {gap_node, idx(), binary(), binary()}
      | {sl_call, idx(), binary(), binary(), [idx()]} | {sl_cast, idx(), idx(), idx()}
      | {sl_spawn_child, idx(), idx(), binary(), binary(), idx(),
         #{reserve := integer(), release := binary(), state_policy := binary()}}
      | {sl_fail_self, idx(), idx()} | {sl_stop_self, idx()}
      | {sl_phase, idx(), integer(), [idx()], binary()} | {sl_yield, idx(), binary(), [idx()]}
      | {sl_behaviour, idx(), idx(), idx(), idx()}.
