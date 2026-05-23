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
    registry_load/0,
    inflight_init/0,
    inflight_insert/3,
    inflight_lookup/1,
    inflight_delete/1,
    inflight_size/0,
    request_workers_init/0,
    request_workers_insert/2,
    request_workers_lookup/1,
    request_workers_delete/1,
    request_workers_size/0,
    pool_register/1,
    pool_lookup/0,
    sessions_register/1,
    sessions_lookup/0,
    lsp_proc_subjects_init/0,
    lsp_proc_subjects_insert/4,
    lsp_proc_subjects_lookup/3,
    lsp_proc_subjects_delete/3,
    register_root_supervisor/1,
    find_root_supervisor/0,
    trace_filter_cache_set/1,
    trace_filter_cache_is_on/0,
    config_store/1,
    config_load/0,
    session_overrides_store/1,
    session_overrides_load/0,
    argv/0,
    burrito_cache_root/0,
    beam_version_info/0,
    self_mailbox_len/0,
    pool_diag/1,
    iolist_to_binary_safe/1,
    safe_call_0/1,
    trap_exits/0,
    describe_term/1,
    install_sasl_capture_handler/0,
    redirect_erl_crash_dump/0,
    init_stop/0,
    format/2,
    lsp_capabilities_init/0,
    lsp_capabilities_store/2,
    lsp_capabilities_lookup/1,
    latin1_to_utf8/1,
    latin1_warned_p/0,
    mark_latin1_warned/0
]).

%% ETS-backed LSP capabilities store (8A capability detection).
%% Keyed by lsp_proc pid; value is the InitializeResult.capabilities
%% Dynamic the server returned during the initialize handshake.
%% Tools read this before dispatching optional methods (inlay_hints,
%% type_hierarchy_prepare, etc.) so we can return a typed
%% "method not advertised" response without burning a network round
%% trip on servers that don't implement it. Owner: pharos:boot/0.
-define(LSP_CAPABILITIES_TABLE, pharos_lsp_capabilities).

lsp_capabilities_init() ->
    case ets:info(?LSP_CAPABILITIES_TABLE) of
        undefined ->
            ets:new(?LSP_CAPABILITIES_TABLE, [
                named_table, public, set, {read_concurrency, true}
            ]);
        _ ->
            ok
    end,
    nil.

lsp_capabilities_store(Pid, Capabilities) when is_pid(Pid) ->
    case ets:info(?LSP_CAPABILITIES_TABLE) of
        undefined -> nil;
        _ ->
            ets:insert(?LSP_CAPABILITIES_TABLE, {Pid, Capabilities}),
            nil
    end.

lsp_capabilities_lookup(Pid) when is_pid(Pid) ->
    case ets:info(?LSP_CAPABILITIES_TABLE) of
        undefined -> {error, nil};
        _ ->
            case ets:lookup(?LSP_CAPABILITIES_TABLE, Pid) of
                [{_, Caps}] -> {ok, Caps};
                [] -> {error, nil}
            end
    end.

%% Set process_flag(trap_exit, true) on the calling process. EXIT
%% signals from linked processes will then be delivered as
%% {'EXIT', From, Reason} mailbox messages instead of terminating
%% the trapping process. Used by pool actor to diagnose silent
%% restarts: when an EXIT arrives, the actor's `select_other`
%% catches it and logs the source + reason rather than dying.
%% Side-effect: pool's supervisor shutdown becomes graceful
%% (acknowledge + actor.stop) rather than immediate kill.
trap_exits() ->
    process_flag(trap_exit, true),
    nil.

%% Render any Erlang term as a printable binary via io_lib:format("~p", ...).
%% Used by Gleam-side diagnostics to log a Dynamic without crashing on
%% non-iolist values (the safe-iolist FFI absorbs format's output).
describe_term(Term) ->
    iolist_to_binary_safe(io_lib:format("~p", [Term])).

%% Install a logger handler that captures every SASL crash/supervisor/
%% progress report and writes the raw event term to stderr via
%% io:format(standard_error, ...). Bypasses both:
%%   - The default logger_std_h that the gleam `logging` library
%%     filters down (it stops sub-domains `sasl` and
%%     `supervisor_report` and the `progress` filter).
%%   - The `error (default): EndOfStream` failure mode we saw in
%%     dogfood pass 11's stderr capture, where the standard handler
%%     errored once early and the logger silently retired it.
%%
%% Catches everything (filter_default=log) but only formats reports
%% whose meta carries one of the SASL/crash domains. Other events
%% pass through to the default handler unchanged.
install_sasl_capture_handler() ->
    %% Two handlers, both backed by `pharos_logger_h` (ADR-030 B1):
    %%
    %% 1. `:default` — replaces OTP's boot-time `:simple` handler
    %%    (`logger_simple_h`) which writes via `:user` and corrupts
    %%    MCP JSON-RPC frames on stdout. Adding ANY handler named
    %%    `:default` triggers OTP to auto-remove `:simple` (see
    %%    `kernel-10.4/src/logger.erl:844`). The gleam `logging`
    %%    library subsequently overwrites this handler's formatter
    %%    with its own (`logging_ffi:format/2`) via
    %%    `logger:update_handler_config/3`, so the formatter we set
    %%    here is short-lived.
    %% 2. `:pharos_sasl_capture` — secondary handler whose formatter
    %%    is `pharos_runtime_ffi:format/2` (this module). It dumps
    %%    the raw event term for SASL crash reports / supervisor
    %%    restarts / progress reports — the gleam `logging` library
    %%    filters those domains away from `:default`, so we add a
    %%    second handler with empty filters to keep them on-screen
    %%    for diagnostics.
    %%
    %% Both handlers write to `standard_error` via `pharos_logger_h`,
    %% which wraps `io:put_chars/2` in try/catch. A closed fd 2 drops
    %% the event silently instead of cascading through the BEAM
    %% logger crash path that terminated the runtime three times on
    %% 2026-05-22.
    try
        DefaultConfig = #{
            config => #{type => standard_error},
            filter_default => log,
            filters => []
        },
        _ = logger:add_handler(default, pharos_logger_h, DefaultConfig),
        SaslConfig = #{
            config => #{type => standard_error, sync_mode_qlen => 0},
            filter_default => log,
            filters => [],
            formatter => {?MODULE, #{}}
        },
        Result = logger:add_handler(pharos_sasl_capture, pharos_logger_h, SaslConfig),
        try
            io:format(standard_error,
                "[pharos-sasl] handler install result: ~p~n", [Result])
        catch
            _:_ -> ok
        end,
        %% Emit a synthetic log event right after install so we can confirm
        %% events flow through this handler at all.
        try
            logger:error("pharos-sasl handler smoke test (expect to see this line)")
        catch
            _:_ -> ok
        end
    catch
        Class:Reason ->
            %% Best-effort breadcrumb so users diagnosing a quiet
            %% pharos can find this if stderr is reachable. If it
            %% isn't, the cascade just falls through.
            try
                io:format(standard_error,
                    "[pharos-sasl] handler install skipped: ~p:~p~n",
                    [Class, Reason])
            catch
                _:_ -> ok
            end
    end,
    nil.

%% Set ERL_CRASH_DUMP early in pharos:main/0 so a BEAM-level halt
%% writes its dump alongside pharos's own crash files (which live
%% under `$HOME/.cache/pharos/log/`) instead of polluting the
%% invoker's cwd — the historical default that surprised every
%% benchmark + dogfood pass.
%%
%% Best-effort: respects an existing ERL_CRASH_DUMP if the host
%% already pinned a location. Silent if $HOME is unset or the
%% target dir can't be created (fall back to BEAM's default of
%% `./erl_crash.dump`).
%% ADR-030 graceful-exit hook. Called from `stdio_worker.handle_eof/1`
%% (and from a future SIGTERM trap if we add one) once stdin closes
%% and the worker has drained its in-flight requests. Triggers OTP's
%% standard shutdown sequence:
%%
%%   1. application_controller stops each running application in
%%      reverse start order (pharos goes first).
%%   2. Each app's stop/1 callback fires — for pharos this calls
%%      `pharos_instance_track_ffi:clear_instance_dir/0`, removing
%%      the per-PID dir under `~/.local/share/pharos/instances/`.
%%   3. Supervisors terminate children, ports close, BEAM halts.
%%
%% Without this hook the stdio_worker stops itself via `actor.stop()`
%% but `pharos:main/0`'s `process.sleep_forever/0` keeps BEAM alive
%% until the parent harness times out (5 s in `bench/oracle.py`) and
%% sends SIGKILL — which skips every stop/1 callback and leaks the
%% instance directory. Observed leaking 10 dirs across Phase 5
%% attempt 3 (2026-05-22).
init_stop() ->
    %% Spawn the halt so the caller's actor message handler returns
    %% before OTP starts tearing down — otherwise the stdio_worker
    %% would be inside its own message handler when supervisor sends
    %% it the shutdown signal, causing a noisy "killed during
    %% terminate" log line.
    spawn(fun() ->
        init:stop()
    end),
    nil.

redirect_erl_crash_dump() ->
    case os:getenv("ERL_CRASH_DUMP") of
        false ->
            try
                Home = case os:getenv("HOME") of
                    false -> "/tmp";
                    H     -> H
                end,
                Dir = filename:join([Home, ".cache", "pharos", "log"]),
                ok = filelib:ensure_dir(filename:join(Dir, "x")),
                Stamp = iolist_to_binary(
                    io_lib:format("~B", [erlang:system_time(millisecond)])),
                Path = filename:join(Dir,
                    binary_to_list(<<"erl_crash-", Stamp/binary, ".dump">>)),
                os:putenv("ERL_CRASH_DUMP", Path)
            catch
                _:_ -> ok
            end;
        _AlreadySet ->
            ok
    end,
    nil.

%% logger formatter callback: write SASL-class reports raw to stderr.
%% Returning a binary tells logger to emit it; returning <<>> drops.
%% logger formatter callback. Module ref `{?MODULE, _}` in
%% logger:add_handler config wires this in — logger calls
%% Module:format/2 per OTP convention. We render every event the
%% handler receives as `[pharos-sasl] ts level=L domain=D msg=...`,
%% bypassing the gleam logging library's SASL/supervisor_report
%% filters that suppress these events on the default handler.
format(LogEvent, _Config) ->
    try
        Level = maps:get(level, LogEvent, info),
        Msg = maps:get(msg, LogEvent, undefined),
        Meta = maps:get(meta, LogEvent, #{}),
        Domain = maps:get(domain, Meta, []),
        io_lib:format("[pharos-sasl] level=~p domain=~p msg=~p~n",
                      [Level, Domain, Msg])
    catch
        C:E:_ -> io_lib:format("[pharos-sasl] FORMATTER ERR ~p:~p~n", [C, E])
    end.


%% ETS bridge for ADR-017a — maps a (Language, Workspace) tuple
%% to the Gleam-side Subject for the lsp_proc actor handling that
%% pair. (Language, Workspace) is the pool's natural cache key,
%% and using it here means a supervisor-driven worker restart
%% (which spawns a new actor with the same args) overwrites the
%% same ETS row. The pool's cache-miss path reads this table as
%% its first move so a restarted worker's new Subject is found
%% without spawning a duplicate via supervisor:start_child.
%%
%% Public, set, named_table so any process can read; concurrent
%% readers benefit from read_concurrency.
-define(LSP_PROC_SUBJECTS_TABLE, pharos_lsp_proc_subjects).

lsp_proc_subjects_init() ->
    case ets:info(?LSP_PROC_SUBJECTS_TABLE) of
        undefined ->
            ets:new(?LSP_PROC_SUBJECTS_TABLE, [
                named_table, public, set, {read_concurrency, true}
            ]);
        _ -> ?LSP_PROC_SUBJECTS_TABLE
    end,
    nil.

lsp_proc_subjects_insert(Language, Workspace, ServerId, Subject)
        when is_binary(Language), is_binary(Workspace),
             is_binary(ServerId) ->
    case ets:info(?LSP_PROC_SUBJECTS_TABLE) of
        undefined -> nil;
        _ ->
            ets:insert(?LSP_PROC_SUBJECTS_TABLE,
                {{Language, Workspace, ServerId}, Subject}),
            nil
    end.

lsp_proc_subjects_lookup(Language, Workspace, ServerId)
        when is_binary(Language), is_binary(Workspace),
             is_binary(ServerId) ->
    case ets:info(?LSP_PROC_SUBJECTS_TABLE) of
        undefined -> {error, nil};
        _ ->
            case ets:lookup(?LSP_PROC_SUBJECTS_TABLE,
                            {Language, Workspace, ServerId}) of
                [{_Key, Subject}] -> {ok, Subject};
                [] -> {error, nil}
            end
    end.

lsp_proc_subjects_delete(Language, Workspace, ServerId)
        when is_binary(Language), is_binary(Workspace),
             is_binary(ServerId) ->
    case ets:info(?LSP_PROC_SUBJECTS_TABLE) of
        undefined -> nil;
        _ ->
            ets:delete(?LSP_PROC_SUBJECTS_TABLE,
                       {Language, Workspace, ServerId}),
            nil
    end.

sessions_register(Subject) ->
    persistent_term:put(pharos_sessions_subject, Subject),
    nil.

sessions_lookup() ->
    try
        Subject = persistent_term:get(pharos_sessions_subject),
        {ok, Subject}
    catch
        error:badarg -> {error, nil}
    end.

%% Persistent-term backing for the pool's Subject so any process
%% can call `pool.global/0` without threading the Subject through
%% function signatures (ADR-017).
pool_register(Subject) ->
    persistent_term:put(pharos_pool_subject, Subject),
    nil.

pool_lookup() ->
    try
        Subject = persistent_term:get(pharos_pool_subject),
        {ok, Subject}
    catch
        error:badarg -> {error, nil}
    end.

%% ETS-backed in-flight request tracker (ADR-016). Keyed by MCP
%% request id (binary). Value: {ProcSubject, LspRequestId}. Used by
%% notifications/cancelled to route cancels to the right proc.
-define(INFLIGHT_TABLE, pharos_inflight).

inflight_init() ->
    case ets:info(?INFLIGHT_TABLE) of
        undefined ->
            ets:new(?INFLIGHT_TABLE, [named_table, public, set,
                                       {read_concurrency, true},
                                       {write_concurrency, true}]);
        _ -> ?INFLIGHT_TABLE
    end,
    nil.

inflight_insert(McpId, ProcSubject, LspId) when is_binary(McpId), is_integer(LspId) ->
    case ets:info(?INFLIGHT_TABLE) of
        undefined -> nil;
        _ ->
            ets:insert(?INFLIGHT_TABLE, {McpId, ProcSubject, LspId}),
            nil
    end.

inflight_lookup(McpId) when is_binary(McpId) ->
    case ets:info(?INFLIGHT_TABLE) of
        undefined -> {error, nil};
        _ ->
            case ets:lookup(?INFLIGHT_TABLE, McpId) of
                [{McpId, ProcSubject, LspId}] -> {ok, {ProcSubject, LspId}};
                [] -> {error, nil}
            end
    end.

inflight_delete(McpId) when is_binary(McpId) ->
    case ets:info(?INFLIGHT_TABLE) of
        undefined -> nil;
        _ ->
            ets:delete(?INFLIGHT_TABLE, McpId),
            nil
    end.

inflight_size() ->
    case ets:info(?INFLIGHT_TABLE, size) of
        undefined -> 0;
        N -> N
    end.

%% ETS-backed MCP request worker tracker (M10 cancel worker, ADR-016
%% follow-up). Keyed by MCP request id. Value: worker process pid.
%% Populated by `pharos@stdio_worker` immediately before handing the
%% request line to a freshly-spawned dispatcher process; deleted by
%% the dispatcher itself in its `after` block. The cancel handler
%% reads this table to kill the in-flight worker via
%% `process.send_exit/2` so a stdio cancel arriving while the LSP
%% request is still outstanding short-circuits the wait.
-define(REQUEST_WORKERS_TABLE, pharos_request_workers).

request_workers_init() ->
    case ets:info(?REQUEST_WORKERS_TABLE) of
        undefined ->
            ets:new(?REQUEST_WORKERS_TABLE, [
                named_table, public, set,
                {read_concurrency, true},
                {write_concurrency, true}
            ]);
        _ -> ?REQUEST_WORKERS_TABLE
    end,
    nil.

request_workers_insert(McpId, WorkerPid)
        when is_binary(McpId), is_pid(WorkerPid) ->
    case ets:info(?REQUEST_WORKERS_TABLE) of
        undefined -> nil;
        _ ->
            ets:insert(?REQUEST_WORKERS_TABLE, {McpId, WorkerPid}),
            nil
    end.

request_workers_lookup(McpId) when is_binary(McpId) ->
    case ets:info(?REQUEST_WORKERS_TABLE) of
        undefined -> {error, nil};
        _ ->
            case ets:lookup(?REQUEST_WORKERS_TABLE, McpId) of
                [{McpId, WorkerPid}] -> {ok, WorkerPid};
                [] -> {error, nil}
            end
    end.

request_workers_delete(McpId) when is_binary(McpId) ->
    case ets:info(?REQUEST_WORKERS_TABLE) of
        undefined -> nil;
        _ ->
            ets:delete(?REQUEST_WORKERS_TABLE, McpId),
            nil
    end.

request_workers_size() ->
    case ets:info(?REQUEST_WORKERS_TABLE, size) of
        undefined -> 0;
        N -> N
    end.

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
    %% Use recon:scheduler_usage/1 (millisecond-accurate, returns
    %% [{SchedId, Usage}]) instead of scheduler:utilization/1.
    %% The latter hung indefinitely in M9.5 dogfood — likely an OTP
    %% scheduler-API quirk with the runtime_tools-style sampling. recon
    %% wraps scheduler:sample_all + diff over a sleep window in pure
    %% Erlang code, which behaves predictably.
    Clamped = max(1, IntervalMs),
    Samples = recon:scheduler_usage(Clamped),
    [format_scheduler_sample(S) || S <- Samples].

format_scheduler_sample({Type, Id, Util}) when is_atom(Type) ->
    {scheduler_sample,
        atom_to_binary(Type, utf8),
        format_id(Id),
        ensure_float(Util)};
format_scheduler_sample({SchedId, Util}) when is_integer(SchedId) ->
    %% recon:scheduler_usage/1 shape: {SchedId, Usage}.
    {scheduler_sample,
        <<"normal">>,
        integer_to_binary(SchedId),
        ensure_float(Util)};
format_scheduler_sample({Type, Util}) when is_atom(Type) ->
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

%% Root supervisor registration (limitation 2a fix). Registers the
%% pharos root supervisor pid under the name `pharos_root_supervisor`
%% so OTP application_controller can walk the tree from the
%% application's primary process. Without this, runtime_supervision_tree
%% reports kernel/sasl/elixir only because pharos_app_ffi:start/2 used
%% to return a plain spawn_link pid that app_controller could not
%% introspect.
%%
%% Idempotent: re-registering the same pid (e.g. from a second
%% pharos:boot/0 call inside the same BEAM) is a no-op.
register_root_supervisor(Pid) when is_pid(Pid) ->
    case whereis(pharos_root_supervisor) of
        undefined ->
            try register(pharos_root_supervisor, Pid) catch _:_ -> ok end;
        Existing when Existing =:= Pid ->
            ok;
        _ ->
            ok
    end,
    nil.

find_root_supervisor() ->
    case whereis(pharos_root_supervisor) of
        undefined -> {error, nil};
        Pid -> {ok, Pid}
    end.

%% Trace-target filter cache (M10 emit-side prefilter, ADR-019 prep).
%%
%% `pharos/lsp/trace` is a high-volume target that must NOT be emitted
%% when the filter would silence it — both for cost and to avoid the
%% writer-mailbox cast race that left runtime_trace_lsp captures empty
%% in M9.5 dogfood. Producers (trace.gleam) read this cache before
%% casting an Emit; SetTargetSync's writer handler updates it in
%% lockstep so caller sees the new value as soon as set_target_global
%% returns.
%%
%% persistent_term is the right home: O(1) read, GC pressure only on
%% write (rare — only on filter changes). We store a single boolean
%% atom `on` | `off` rather than the whole filter struct, since the
%% only consumer cares about a single yes/no.
%% Atoms match Gleam's `TraceCacheOn` / `TraceCacheOff` constructors
%% (Gleam lowercases record-tag atoms).
trace_filter_cache_set(trace_cache_on) ->
    persistent_term:put(pharos_trace_filter_on, true), nil;
trace_filter_cache_set(trace_cache_off) ->
    persistent_term:put(pharos_trace_filter_on, false), nil.

trace_filter_cache_is_on() ->
    case persistent_term:get(pharos_trace_filter_on, false) of
        true -> true;
        _ -> false
    end.

%% Persistent-term backing for the loaded Config record. Stored once
%% at boot by `pharos/config:load/0`; read O(1) by every consumer.
config_store(ConfigTerm) ->
    persistent_term:put(pharos_config, ConfigTerm),
    nil.

config_load() ->
    try
        Cfg = persistent_term:get(pharos_config),
        {ok, Cfg}
    catch
        error:badarg -> {error, nil}
    end.

%% Session-scoped tool_config overrides (ADR 021 layer 4). The
%% runtime_set_tool_timeout MCP tool writes here; resolve_tool_timeout
%% reads. Map shape:
%%   #{ ToolName => #{global => Option(Int), languages => #{Lang => Int}} }
%% Stored under a distinct key from pharos_config so config reloads
%% don't clobber session-scoped tuning.
session_overrides_store(Map) ->
    persistent_term:put(pharos_session_overrides, Map),
    nil.

session_overrides_load() ->
    try
        Map = persistent_term:get(pharos_session_overrides),
        {ok, Map}
    catch
        error:badarg -> {error, nil}
    end.

%% Plain CLI argv (after BEAM/Erlang flags). Returns the args the user
%% supplied to the Burrito-wrapped binary. Empty list under `mix run`.
argv() ->
    [unicode:characters_to_binary(A) || A <- init:get_plain_arguments()].

%% Burrito's per-app extract-cache root: `<user_cache>/burrito_runtime/_/pharos`
%% covers every installed version. Used by `pharos --purge-cache` to
%% clean up extracted ERTS+BEAM payloads from prior runs.
%%
%% On Linux: ~/.cache/burrito_runtime/_/pharos/
%% On macOS: ~/Library/Caches/burrito_runtime/_/pharos/
%% On Windows: <LOCALAPPDATA>\burrito_runtime\_\pharos\
%%
%% Returns the path as a binary even when the directory does not yet
%% exist (e.g. running under `mix start` rather than the wrapped
%% binary). Caller is expected to check `filelib:is_dir/1` before
%% trying to delete.
burrito_cache_root() ->
    Base = filename:basedir(user_cache, "burrito_runtime"),
    Path = filename:join([Base, "_", "pharos"]),
    list_to_binary(Path).

%% BEAM + ERTS version snapshot for `pharos --doctor`. Every value
%% is a binary so the Gleam side can render without atom-to-string
%% conversions. ERTS is the subsystem that actually runs the binary
%% (matters when reporting Burrito-wrapped vs `mix run` invocation).
beam_version_info() ->
    Erts = list_to_binary(erlang:system_info(version)),
    Otp = list_to_binary(erlang:system_info(otp_release)),
    Sys = list_to_binary(erlang:system_info(system_version)),
    Trim = string:trim(Sys),
    {ok, {beam_info, Erts, Otp, Trim}}.

%% Convert any iolist / binary / charlist / pid_to_list result to a
%% Gleam-friendly UTF-8 binary. Used by pool's describe_pid and
%% describe_dynamic. unicode:characters_to_binary returns a raw
%% binary (or an {error, _, _} tuple), NOT a {ok, _} / {error, _}
%% pair, so calling it directly from Gleam with a `Result(...)` FFI
%% signature pattern-match fails and crashes the calling process.
%% This shim absorbs the shape mismatch.
iolist_to_binary_safe(IO) ->
    try unicode:characters_to_binary(IO) of
        Bin when is_binary(Bin) -> Bin;
        {error, Partial, _Rest} when is_binary(Partial) -> Partial;
        {incomplete, Partial, _Rest} when is_binary(Partial) -> Partial;
        _ -> <<"<unprintable>">>
    catch
        %% Atoms, integers, and other non-iolist terms raise badarg
        %% rather than returning a tuple. The shim must absorb that
        %% too — describe_dynamic's whole purpose is "rendering ANY
        %% term to a string", and a panic here would defeat that.
        %% Runtime FFI test caught this gap on Pass 7+.
        _:_ -> <<"<unprintable>">>
    end.

%% Wrap a zero-arg Gleam closure in a try/catch so a `callee exited`
%% panic (from gleam_otp actor.call against a dead Subject) returns
%% Error instead of killing the calling process. Used by pool's
%% probe_call to close the is_alive→actor.call race window where
%% the lsp_proc can die between the is_alive read and the actual
%% message send. ADR-024 follow-up M14 Pass 1c finding.
%%
%% Returns {ok, ResultValue} on success or {error, BinaryReason} on
%% any error/exit/throw. ResultValue is whatever the closure
%% returned — the caller is responsible for further pattern matching.
safe_call_0(Fun) when is_function(Fun, 0) ->
    try
        {ok, Fun()}
    catch
        error:#{gleam_error := _, message := Msg}:_ when is_binary(Msg) ->
            {error, Msg};
        error:Reason:_ ->
            {error, iolist_to_binary(io_lib:format("error: ~p", [Reason]))};
        exit:Reason:_ ->
            {error, iolist_to_binary(io_lib:format("exit: ~p", [Reason]))};
        throw:Reason:_ ->
            {error, iolist_to_binary(io_lib:format("throw: ~p", [Reason]))}
    end.

%% Pool actor calls this from inside handle_snapshot to record its
%% own mailbox depth. Counts other Msg's queued behind the
%% SnapshotReq; non-zero = pool is keeping up but not free.
self_mailbox_len() ->
    case erlang:process_info(self(), message_queue_len) of
        {message_queue_len, N} -> N;
        undefined -> 0
    end.

%% recon-backed pool diagnostics. Returns a 4-tuple:
%%   {pool_diag, PoolInfo, TopMailboxes, PoolStateDump, SpawnerStacktraces}
%%
%% - PoolInfo: {pool_info_row, PidText, RegName, MailboxLen, MemoryBytes,
%%               CurrentFunctionText, Status}
%% - TopMailboxes: list of {top_proc, PidText, RegName, MailboxLen, MemoryBytes, CurrentFunctionText}
%%   ranked by message_queue_len descending; limited to TopN.
%% - PoolStateDump: best-effort sys:get_state(PoolPid, 1000) rendered
%%   as a binary; empty binary on failure (pool is gen_server-ish so
%%   this usually works).
%% - SpawnerStacktraces: list of {spawner_trace, PidText, CurrentFunctionText, StackText}
%%   for every process whose initial_call's first element is
%%   `pharos@lsp@pool` (these are the spawn workers — knowing where
%%   they're parked tells us if they're stuck inside lifecycle.wait
%%   or probe_call). Best-effort; empty list under load.
%%
%% Used by runtime_pool_recon MCP tool for diagnosing pool-blocked
%% spawn cascades.
pool_diag(TopN) when is_integer(TopN), TopN > 0 ->
    PoolPid = case persistent_term:get(pharos_pool_subject, undefined) of
        undefined -> undefined;
        Subject ->
            %% Subject is a gleam process Subject — record shape
            %% {subject, OwnerPid, Tag} or similar. Try unwrap.
            extract_pid(Subject)
    end,
    PoolInfo = case PoolPid of
        undefined -> {pool_info_row, <<>>, <<>>, 0, 0, <<>>, <<"unregistered">>};
        _ -> describe_proc(PoolPid)
    end,
    Top = top_by_mailbox(TopN),
    PoolStateDump = case PoolPid of
        undefined -> <<>>;
        _ ->
            try
                State = sys:get_state(PoolPid, 1000),
                iolist_to_binary(io_lib:format("~p", [State]))
            catch
                _:_ -> <<>>
            end
    end,
    Spawners = find_spawner_traces(),
    {pool_diag, PoolInfo, Top, PoolStateDump, Spawners}.

extract_pid(Subject) ->
    %% gleam_erlang Subjects are records — try a few likely shapes.
    case Subject of
        {subject, Pid, _Tag} when is_pid(Pid) -> Pid;
        Pid when is_pid(Pid) -> Pid;
        T when is_tuple(T), tuple_size(T) >= 2 ->
            case element(2, T) of
                Pid when is_pid(Pid) -> Pid;
                _ -> undefined
            end;
        _ -> undefined
    end.

describe_proc(Pid) when is_pid(Pid) ->
    case erlang:process_info(Pid, [
        registered_name,
        message_queue_len,
        memory,
        current_function,
        status
    ]) of
        undefined ->
            {pool_info_row, list_to_binary(pid_to_list(Pid)),
                <<>>, 0, 0, <<>>, <<"dead">>};
        Info ->
            Get = fun(K) -> proplists:get_value(K, Info) end,
            Name = case Get(registered_name) of
                [] -> <<>>;
                undefined -> <<>>;
                A when is_atom(A) -> atom_to_binary(A, utf8)
            end,
            Cur = case Get(current_function) of
                {M, F, Ar} ->
                    iolist_to_binary(io_lib:format("~p:~p/~p", [M, F, Ar]));
                _ -> <<>>
            end,
            Status = case Get(status) of
                S when is_atom(S) -> atom_to_binary(S, utf8);
                _ -> <<>>
            end,
            {pool_info_row,
                list_to_binary(pid_to_list(Pid)),
                Name,
                default(Get(message_queue_len), 0),
                default(Get(memory), 0),
                Cur,
                Status}
    end.

top_by_mailbox(N) ->
    Pids = erlang:processes(),
    Rows = lists:foldl(fun(Pid, Acc) ->
        case erlang:process_info(Pid, [
            registered_name,
            message_queue_len,
            memory,
            current_function
        ]) of
            undefined -> Acc;
            Info ->
                Get = fun(K) -> proplists:get_value(K, Info) end,
                MQ = default(Get(message_queue_len), 0),
                case MQ > 0 of
                    false -> Acc;
                    true ->
                        Name = case Get(registered_name) of
                            [] -> <<>>;
                            undefined -> <<>>;
                            A when is_atom(A) -> atom_to_binary(A, utf8)
                        end,
                        Cur = case Get(current_function) of
                            {M, F, Ar} ->
                                iolist_to_binary(io_lib:format("~p:~p/~p", [M, F, Ar]));
                            _ -> <<>>
                        end,
                        Row = {top_proc,
                            list_to_binary(pid_to_list(Pid)),
                            Name,
                            MQ,
                            default(Get(memory), 0),
                            Cur},
                        [Row | Acc]
                end
        end
    end, [], Pids),
    Sorted = lists:sort(fun(A, B) ->
        element(4, A) >= element(4, B)
    end, Rows),
    lists:sublist(Sorted, N).

find_spawner_traces() ->
    Pids = erlang:processes(),
    lists:foldl(fun(Pid, Acc) ->
        case erlang:process_info(Pid, [initial_call, current_function]) of
            undefined -> Acc;
            Info ->
                IC = proplists:get_value(initial_call, Info),
                case is_spawner_initial_call(IC) of
                    false -> Acc;
                    true ->
                        Cur = case proplists:get_value(current_function, Info) of
                            {M, F, Ar} ->
                                iolist_to_binary(io_lib:format("~p:~p/~p", [M, F, Ar]));
                            _ -> <<>>
                        end,
                        Stack = case erlang:process_info(Pid, current_stacktrace) of
                            {current_stacktrace, S} ->
                                iolist_to_binary(io_lib:format("~p", [S]));
                            _ -> <<>>
                        end,
                        [{spawner_trace,
                            list_to_binary(pid_to_list(Pid)),
                            Cur,
                            Stack} | Acc]
                end
        end
    end, [], Pids).

%% A pool spawner is `process.spawn_unlinked(fun)` invoked from
%% pharos@lsp@pool:spawn_worker. erlang process_info's initial_call
%% records the entry MFA; gleam compiles closure-spawners through
%% `erlang:spawn/1` so the initial_call ends up `erlang:apply/2`.
%% We can't filter on module name alone; instead match anything
%% whose current_stacktrace mentions our pool module. This is
%% best-effort but cheap.
is_spawner_initial_call({pharos@lsp@pool, _, _}) -> true;
is_spawner_initial_call(_) -> false.

%% Universal Latin-1 fallback for non-UTF-8 LSP responses.
%% JSON-RPC mandates UTF-8 but real-world LSPs (lua-language-server
%% under non-UTF-8 locales; older PLS builds) occasionally emit
%% bytes outside the UTF-8 range inside JSON string fields. Latin-1
%% always succeeds — every byte maps to a Unicode codepoint in the
%% 0..255 range. The resulting string may have a slightly garbled
%% non-ASCII path but JSON parsing still works and the response
%% reaches the LLM. Returns {ok, Binary} on success, {error, nil}
%% if even the latin1 conversion fails (shouldn't happen for any
%% real byte sequence, but kept for completeness).
latin1_to_utf8(Body) ->
    case unicode:characters_to_binary(Body, latin1, utf8) of
        Binary when is_binary(Binary) -> {ok, Binary};
        _ -> {error, nil}
    end.

%% Single-shot warning latch. Stored as a persistent_term so it
%% survives process death and is shared across all classifiers.
%% Pharos boots clean every BEAM start, so a fresh key works.
-define(LATIN1_WARN_KEY, pharos_latin1_fallback_warned).

latin1_warned_p() ->
    persistent_term:get(?LATIN1_WARN_KEY, false).

mark_latin1_warned() ->
    persistent_term:put(?LATIN1_WARN_KEY, true),
    nil.
