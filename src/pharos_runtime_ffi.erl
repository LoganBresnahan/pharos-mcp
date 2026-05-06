%% Erlang FFI for the runtime introspection tools (M9.5 Part C).
%%
%% Each function returns a value in a shape that maps cleanly onto a
%% Gleam record or list of records — the Gleam side never sees raw
%% Erlang proplists or atoms. The MCP tool handler then encodes the
%% Gleam value to JSON via gleam_json.
%%
%% Pids round-trip as text (`<<"<0.143.0>">>`). They are not stable
%% across restarts; storing them in long-lived state is a bug. The
%% `parse_pid/1` helper is the only way to turn a text pid back into
%% a real one for further introspection.
%%
%% recon_trace is wrapped here rather than via direct Gleam FFI so
%% the trace cleanup `try ... after` lives in one place — every exit
%% path through this module's tracer functions clears the trace
%% flags from every monitored process.

-module(pharos_runtime_ffi).
-export([
    list_processes/1,
    process_info_for/1,
    parse_pid/1,
    pid_to_text/1,
    list_ets_tables/0,
    memory_breakdown/0,
    list_applications/0,
    scheduler_utilization/1,
    supervision_tree/0,
    trace_calls/4,
    trace_calls_clear/0,
    wildcard/0,
    int_to_dynamic/1,
    as_dynamic/1,
    registry_store/1,
    registry_load/0
]).

%% Persistent-term backing for the language registry. One slot,
%% replaced on every `init/0`. Reads are O(1) and lock-free.
registry_store(Registry) ->
    persistent_term:put(pharos_language_registry, Registry),
    nil.

registry_load() ->
    try
        Registry = persistent_term:get(pharos_language_registry),
        {ok, Registry}
    catch
        error:badarg -> {error, nil}
    end.

%% Identity for an integer — used by Gleam's tier4 module to pass
%% integer arity through `Dynamic` typed parameters into recon.
int_to_dynamic(N) when is_integer(N) -> N.

%% Type-erasing identity. Returns the term verbatim so Gleam can
%% widen any value to `Dynamic` without copy or coercion. Used by
%% pool's monitor selector which must hand an `ExitReason` (opaque
%% enum) into a `dynamic.Dynamic` field. `int_to_dynamic` was the
%% original target but its `is_integer` guard made it crash for
%% non-integer values.
as_dynamic(Term) -> Term.

%% Atom `'_'` as a Dynamic, for use in trace patterns. Cheaper than
%% threading the literal through Gleam's Dynamic constructors.
wildcard() -> '_'.

%% ----- processes -----

list_processes(Limit) when is_integer(Limit) ->
    Pids = erlang:processes(),
    Truncated = lists:sublist(Pids, Limit),
    [process_summary(P) || P <- Truncated].

process_summary(Pid) ->
    Info = erlang:process_info(Pid, [
        registered_name,
        current_function,
        message_queue_len,
        memory,
        status
    ]),
    PidText = list_to_binary(pid_to_list(Pid)),
    case Info of
        undefined ->
            {process_summary, PidText, <<>>, <<>>, 0, 0, <<"dead">>};
        _ ->
            Get = fun(K) -> proplists:get_value(K, Info) end,
            Name = case Get(registered_name) of
                [] -> <<>>;
                undefined -> <<>>;
                Atom when is_atom(Atom) -> atom_to_binary(Atom, utf8)
            end,
            Cur = case Get(current_function) of
                undefined -> <<>>;
                {M, F, A} ->
                    iolist_to_binary(io_lib:format("~p:~p/~p", [M, F, A]))
            end,
            Status = case Get(status) of
                undefined -> <<>>;
                S when is_atom(S) -> atom_to_binary(S, utf8)
            end,
            {process_summary,
                PidText,
                Name,
                Cur,
                default(Get(message_queue_len), 0),
                default(Get(memory), 0),
                Status}
    end.

default(undefined, D) -> D;
default(V, _) -> V.

%% ----- pid_info -----

process_info_for(PidText) when is_binary(PidText) ->
    case parse_pid(PidText) of
        {error, _} = Err -> Err;
        {ok, Pid} ->
            case erlang:process_info(Pid) of
                undefined -> {error, nil};
                Info ->
                    {ok, format_full_info(Info)}
            end
    end.

format_full_info(Info) ->
    %% process_info/1 returns a long proplist; serialize each value
    %% to a printable binary so the Gleam side can stuff the whole
    %% map into a JSON object without per-key decoders.
    [{atom_to_binary(K, utf8),
      iolist_to_binary(io_lib:format("~tp", [V]))}
     || {K, V} <- Info].

parse_pid(PidText) when is_binary(PidText) ->
    parse_pid(binary_to_list(PidText));
parse_pid(PidStr) when is_list(PidStr) ->
    try
        {ok, list_to_pid(PidStr)}
    catch
        error:badarg -> {error, nil}
    end.

pid_to_text(Pid) when is_pid(Pid) ->
    list_to_binary(pid_to_list(Pid)).

%% ----- ets -----

list_ets_tables() ->
    [table_summary(T) || T <- ets:all(), is_inspectable(T)].

is_inspectable(T) ->
    %% Skip tables we cannot ets:info — usually ones owned by procs
    %% that died mid-iteration. The retry pattern is to filter, not
    %% catch.
    case ets:info(T) of
        undefined -> false;
        _ -> true
    end.

table_summary(T) ->
    Info = ets:info(T),
    Get = fun(K) -> proplists:get_value(K, Info) end,
    Name = case Get(name) of
        N when is_atom(N) -> atom_to_binary(N, utf8);
        Other -> iolist_to_binary(io_lib:format("~p", [Other]))
    end,
    OwnerPid = Get(owner),
    OwnerText = case OwnerPid of
        P when is_pid(P) -> list_to_binary(pid_to_list(P));
        _ -> <<>>
    end,
    Type = case Get(type) of
        Atom when is_atom(Atom) -> atom_to_binary(Atom, utf8);
        _ -> <<>>
    end,
    Protection = case Get(protection) of
        ProtAtom when is_atom(ProtAtom) -> atom_to_binary(ProtAtom, utf8);
        _ -> <<>>
    end,
    {ets_table,
        Name,
        default(Get(size), 0),
        default(Get(memory), 0),
        OwnerText,
        Type,
        Protection}.

%% ----- memory -----

memory_breakdown() ->
    Mem = erlang:memory(),
    [{atom_to_binary(K, utf8), V} || {K, V} <- Mem].

%% ----- applications -----

list_applications() ->
    Running = application:which_applications(),
    [{app_summary,
        atom_to_binary(N, utf8),
        iolist_to_binary(D),
        iolist_to_binary(V)} || {N, D, V} <- Running].

%% ----- scheduler util -----

scheduler_utilization(IntervalMs) when is_integer(IntervalMs) ->
    %% scheduler:utilization(IntervalMs) blocks for IntervalMs
    %% sampling, then returns a list of {Type, Id, Util} tuples plus
    %% one "total" tuple. Treat each entry uniformly.
    Samples = scheduler:utilization(IntervalMs),
    [format_scheduler_sample(S) || S <- Samples].

format_scheduler_sample({Type, Id, Util}) ->
    {scheduler_sample,
        atom_to_binary(Type, utf8),
        format_id(Id),
        ensure_float(Util)};
format_scheduler_sample({Type, Util}) ->
    {scheduler_sample,
        atom_to_binary(Type, utf8),
        <<>>,
        ensure_float(Util)}.

ensure_float(N) when is_float(N) -> N;
ensure_float(N) when is_integer(N) -> float(N);
ensure_float(_) -> 0.0.

format_id(Id) when is_integer(Id) -> integer_to_binary(Id);
format_id(Id) when is_atom(Id) -> atom_to_binary(Id, utf8);
format_id(Id) -> iolist_to_binary(io_lib:format("~p", [Id])).

%% ----- supervision tree -----
%%
%% Walk every running supervisor under every running application's
%% master process. Returns a flat list of nodes; the Gleam side
%% reconstructs the tree from `parent` references.

supervision_tree() ->
    Roots = [Pid || {_App, Pid} <- application_controller_top_supervisors()],
    Visited = walk_all(Roots, [], []),
    Visited.

application_controller_top_supervisors() ->
    %% application_controller doesn't expose a public API for this;
    %% iterate which_applications and call get_master.
    Apps = [A || {A, _, _} <- application:which_applications()],
    lists:filtermap(fun(App) ->
        case application_controller:get_master(App) of
            undefined -> false;
            Master ->
                case catch application_master:get_child(Master) of
                    {Pid, _} when is_pid(Pid) -> {true, {App, Pid}};
                    _ -> false
                end
        end
    end, Apps).

walk_all([], _Seen, Acc) ->
    lists:reverse(Acc);
walk_all([Pid | Rest], Seen, Acc) when is_pid(Pid) ->
    case lists:member(Pid, Seen) of
        true -> walk_all(Rest, Seen, Acc);
        false ->
            Node = describe_supervised(Pid),
            Children = case is_supervisor(Pid) of
                true -> child_pids(Pid);
                false -> []
            end,
            walk_all(Rest ++ Children, [Pid | Seen], [Node | Acc])
    end;
walk_all([_ | Rest], Seen, Acc) ->
    walk_all(Rest, Seen, Acc).

is_supervisor(Pid) ->
    case erlang:process_info(Pid, dictionary) of
        {dictionary, Dict} ->
            case proplists:get_value('$initial_call', Dict) of
                {supervisor, _, _} -> true;
                _ -> false
            end;
        undefined -> false
    end.

child_pids(SupervisorPid) ->
    try supervisor:which_children(SupervisorPid) of
        Children ->
            [P || {_Id, P, _Type, _Mods} <- Children, is_pid(P)]
    catch
        _:_ -> []
    end.

describe_supervised(Pid) ->
    Name = case erlang:process_info(Pid, registered_name) of
        {registered_name, N} -> atom_to_binary(N, utf8);
        _ -> <<>>
    end,
    Cur = case erlang:process_info(Pid, current_function) of
        {current_function, {M, F, A}} ->
            iolist_to_binary(io_lib:format("~p:~p/~p", [M, F, A]));
        _ -> <<>>
    end,
    Kind = case is_supervisor(Pid) of
        true -> <<"supervisor">>;
        false -> <<"worker">>
    end,
    {supervised_node,
        list_to_binary(pid_to_list(Pid)),
        Name,
        Cur,
        Kind}.

%% ----- recon_trace wrapper -----
%%
%% Caller passes:
%%   Module    - target module atom or `'_'` for any
%%   Function  - target function atom or `'_'` for any
%%   Arity     - target arity integer or `'_'` for any
%%   Spec      - {DurationMs, MaxEvents}
%%
%% Returns:
%%   {ok, Lines}  — list of formatted trace lines (binaries)
%%   {error, R}   — recon refused (bad pattern, hot module, etc.)
%%
%% recon_trace.calls/2 emits to a configurable formatter. We point it
%% at a per-call collector pid; the collector accumulates binary
%% lines until the time/event trip stops the trace.

trace_calls(Module, Function, Arity, {DurationMs, MaxEvents})
  when is_atom(Module), is_integer(DurationMs), is_integer(MaxEvents) ->
    Self = self(),
    Collector = spawn(fun() -> collect_loop(Self, []) end),
    Pattern = {Module, Function, Arity},
    FormatFun = fun(TraceMsg) ->
        Line = iolist_to_binary(recon_trace:format(TraceMsg)),
        Collector ! {trace_line, Line},
        ok
    end,
    try
        case recon_trace:calls(
            Pattern,
            MaxEvents,
            [{time, DurationMs}, {formatter, FormatFun}]
        ) of
            N when is_integer(N) ->
                receive after DurationMs + 200 -> ok end,
                recon_trace:clear(),
                Collector ! drain,
                receive {drained, Lines} -> {ok, Lines}
                after 1000 -> {ok, []}
                end;
            Other ->
                recon_trace:clear(),
                {error, iolist_to_binary(io_lib:format("~p", [Other]))}
        end
    catch
        Class:Reason:Stack ->
            recon_trace:clear(),
            {error, iolist_to_binary(
                io_lib:format("~p:~p~n~p", [Class, Reason, Stack])
            )}
    end.

trace_calls_clear() ->
    catch recon_trace:clear(),
    nil.

collect_loop(Owner, Acc) ->
    receive
        {trace_line, Line} -> collect_loop(Owner, [Line | Acc]);
        drain -> Owner ! {drained, lists:reverse(Acc)}
    after 30_000 ->
        Owner ! {drained, lists:reverse(Acc)}
    end.
