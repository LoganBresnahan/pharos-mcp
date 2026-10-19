%% ADR-030 S3: per-LSP PID tracking and instance directory management.
%%
%% Pharos may run multiple concurrent instances (one per MCP client
%% session). Each instance owns a subdirectory under
%% `$HOME/.local/share/pharos/instances/<pharos-pid>/`. Inside that
%% subdirectory we write one `<lsp-pid>.pid` file per spawned LSP.
%%
%% File format (key=value, one per line):
%%   pharos_pid=<int>
%%   lsp_pid=<int>
%%   lsp_binary=<absolute path used by open_port>
%%   server_id=<registry id, e.g. "rust-analyzer">
%%   workspace=<cwd handed to open_port>
%%   started_at=<ISO 8601 UTC>
%%
%% Lifecycle:
%%   - `init/0`: called from `pharos:main/0` after config load.
%%     Creates the per-PID instance directory.
%%   - `register_lsp/4`: called immediately after `port.spawn` returns
%%     an `Ok(Port)`. Reads the subprocess OS PID via
%%     `erlang:port_info/2`, writes the metadata file. Returns the
%%     LSP OS PID (or `nil` if port_info fails) so callers can store
%%     it for `deregister_lsp/1`.
%%   - `deregister_lsp/1`: called from `client.close/1`. Hands the
%%     LSP to its reaper (below), which removes the `<lsp-pid>.pid`
%%     file once the LSP's process group is empty. Idempotent.
%%
%% Reaping (ADR-037): an LSP that exits on stdin EOF can leave
%% children behind in its process group (rust-analyzer's in-flight
%% `cargo check` and its build script, measured surviving 120 s), and
%% some LSPs take 5-30 s to exit at all (jdtls). `register_lsp/4`
%% therefore starts one reaper process per LSP. It monitors the
%% process that spawned the LSP (the lsp_proc actor) and, when that
%% actor goes for any reason (close, eviction, idle stop, session
%% end, daemon stop, crash) or `deregister_lsp/1` is called, waits a
%% grace period for the group to empty by itself, then TERMs what is
%% left, then KILLs. `final_reap/0` does the same synchronously for
%% whatever is still recorded when the application stops, and
%% `boot_reap/0` for the instance dirs of pharos processes that died
%% without stopping (SIGKILL, OOM).
%%   - `clear_instance_dir/0`: called from the pharos application
%%     stop callback. Removes the instance directory entirely on
%%     graceful exit — orphan-detection by `pharos cleanup` only
%%     fires on dirs whose owning pharos PID is *not* alive, so the
%%     directory MUST disappear when pharos shuts down cleanly.
%%
%% Best-effort throughout: HOME unset, dir unwritable, ENOSPC, etc.
%% all degrade silently. Pharos's core path does not depend on
%% successful tracking; it is purely a cleanup-helper aid for the
%% `pharos cleanup` CLI subcommand and post-mortem diagnostics.

-module(pharos_instance_track_ffi).
-export([
    init/0,
    instance_dir/0,
    register_lsp/4,
    deregister_lsp/1,
    clear_instance_dir/0,
    %% pharos cleanup CLI surface (ADR-030 Layer 3).
    instances_root/0,
    list_instance_dirs/0,
    list_pid_files/1,
    read_pid_file/1,
    is_pid_alive/1,
    process_comm/1,
    signal_pid/2,
    %% Exported for tests: the group-vs-pid decision is the risky part
    %% of the kill path and is worth asserting directly.
    signal_target/1,
    remove_dir_recursive/1,
    sleep_ms/1,
    %% ADR-037 reaping.
    reap_group/4,
    group_members/1,
    process_start/1,
    final_reap/0,
    boot_reap/0,
    reap_instance_dir/3
]).

%% Grace for an LSP's group to empty by itself once pharos is done with
%% it (most LSPs exit on stdin EOF within milliseconds), then how long
%% TERM gets before KILL. The application-stop pass uses shorter ones:
%% the VM is about to halt.
-define(REAP_GRACE_MS, 3000).
-define(REAP_TERM_WAIT_MS, 2000).
-define(FINAL_GRACE_MS, 1000).
-define(FINAL_TERM_WAIT_MS, 1000).
-define(REAP_POLL_MS, 100).
-define(REAPERS, pharos_lsp_reapers).

%% Create the per-PID instance directory if it does not exist.
%% Returns nil unconditionally — failures are logged via stderr
%% (best-effort) but never raise.
init() ->
    try
        Dir = instance_dir_path(),
        ok = filelib:ensure_dir(filename:join(Dir, "x"))
    catch
        _:_ -> ok
    end,
    nil.

%% Return the absolute path of this pharos instance's tracking
%% directory. Format: `$HOME/.local/share/pharos/instances/<os_pid>/`.
%% Falls back to `/tmp/pharos-instances/<os_pid>/` if $HOME is unset.
instance_dir() ->
    list_to_binary(instance_dir_path()).

instance_dir_path() ->
    Home = case os:getenv("HOME") of
        false -> "/tmp/pharos-instances";
        H -> filename:join([H, ".local", "share", "pharos", "instances"])
    end,
    OsPid = integer_to_list(os_pid_self()),
    filename:join(Home, OsPid).

%% Write a tracking file for a freshly-spawned LSP. Returns the
%% subprocess OS PID as an Erlang integer, or 0 if port_info is
%% unavailable (port already closed or BEAM does not have the os_pid
%% — rare).
%%
%% Arguments are Erlang-side (binaries) so the Gleam caller can pass
%% values straight through without conversion.
register_lsp(Port, ServerId, ResolvedBinary, Workspace)
        when is_port(Port),
             is_binary(ServerId),
             is_binary(ResolvedBinary),
             is_binary(Workspace) ->
    OsPid = case erlang:port_info(Port, os_pid) of
        {os_pid, P} when is_integer(P) -> P;
        _ -> 0
    end,
    case OsPid of
        0 -> 0;
        _ ->
            try
                Dir = instance_dir_path(),
                ok = filelib:ensure_dir(filename:join(Dir, "x")),
                Path = filename:join(Dir, integer_to_list(OsPid) ++ ".pid"),
                Start = process_start(OsPid),
                Body = iolist_to_binary([
                    <<"pharos_pid=">>, integer_to_binary(os_pid_self()), $\n,
                    <<"lsp_pid=">>, integer_to_binary(OsPid), $\n,
                    <<"lsp_start=">>, Start, $\n,
                    <<"lsp_binary=">>, ResolvedBinary, $\n,
                    <<"server_id=">>, ServerId, $\n,
                    <<"workspace=">>, Workspace, $\n,
                    <<"started_at=">>, iso8601_now(), $\n
                ]),
                ok = file:write_file(Path, Body),
                start_reaper(self(), OsPid, Start, Path)
            catch
                _:_ -> ok
            end,
            OsPid
    end;
register_lsp(_, _, _, _) ->
    0.

%% Remove the tracking file for an LSP. Idempotent. Pass the OS PID
%% that `register_lsp/4` returned.
deregister_lsp(0) ->
    nil;
deregister_lsp(LspPid) when is_integer(LspPid) ->
    case reaper_for(LspPid) of
        {ok, Reaper} ->
            Reaper ! reap;
        none ->
            try
                Dir = instance_dir_path(),
                Path = filename:join(Dir, integer_to_list(LspPid) ++ ".pid"),
                _ = file:delete(Path)
            catch
                _:_ -> ok
            end
    end,
    nil.

%% Remove the entire instance directory on graceful pharos exit.
%% Best-effort: failures fall through silently.
clear_instance_dir() ->
    try
        Dir = instance_dir_path(),
        _ = del_dir_recursive(Dir)
    catch
        _:_ -> ok
    end,
    nil.

%% Return the root directory containing all per-PID instance subdirs
%% (one level up from `instance_dir/0`). The `pharos cleanup` CLI
%% enumerates this directory to find candidate orphan instances.
instances_root() ->
    Home = case os:getenv("HOME") of
        false -> "/tmp/pharos-instances";
        H -> filename:join([H, ".local", "share", "pharos", "instances"])
    end,
    list_to_binary(Home).

%% List instance subdirs as `[{OwnerPid :: integer(), AbsPath :: binary()}]`.
%% Skips entries whose name is not parseable as a positive integer
%% (defensive — guards against stray files).
list_instance_dirs() ->
    Home = case os:getenv("HOME") of
        false -> "/tmp/pharos-instances";
        H -> filename:join([H, ".local", "share", "pharos", "instances"])
    end,
    case file:list_dir(Home) of
        {ok, Entries} ->
            lists:filtermap(
                fun(Entry) ->
                    case string:to_integer(Entry) of
                        {Pid, []} when is_integer(Pid), Pid > 0 ->
                            {true, {Pid, list_to_binary(filename:join(Home, Entry))}};
                        _ -> false
                    end
                end,
                Entries);
        _ -> []
    end.

%% List `.pid` files inside an instance directory as
%% `[{LspPid :: integer(), AbsPath :: binary()}]`.
list_pid_files(InstanceDir) when is_binary(InstanceDir) ->
    case file:list_dir(binary_to_list(InstanceDir)) of
        {ok, Entries} ->
            lists:filtermap(
                fun(Entry) ->
                    case lists:suffix(".pid", Entry) of
                        true ->
                            Base = string:slice(Entry, 0, length(Entry) - 4),
                            case string:to_integer(Base) of
                                {LspPid, []} when is_integer(LspPid), LspPid > 0 ->
                                    Path = filename:join(binary_to_list(InstanceDir), Entry),
                                    {true, {LspPid, list_to_binary(Path)}};
                                _ -> false
                            end;
                        false -> false
                    end
                end,
                Entries);
        _ -> []
    end.

%% Parse a `.pid` file into key/value pairs as
%% `[{Key :: binary(), Value :: binary()}]`. Lines that do not match
%% `key=value` are silently skipped (defensive).
read_pid_file(Path) when is_binary(Path) ->
    case file:read_file(Path) of
        {ok, Content} ->
            Lines = binary:split(Content, <<"\n">>, [global, trim_all]),
            lists:filtermap(
                fun(Line) ->
                    case binary:split(Line, <<"=">>) of
                        [K, V] -> {true, {K, V}};
                        _ -> false
                    end
                end,
                Lines);
        _ -> []
    end.

%% True when `kill -0 <pid>` would succeed: signal 0 verifies the PID
%% exists and we can deliver to it. Returns false for ESRCH (gone)
%% and EPERM (exists but not ours — we treat as "not safe to touch").
is_pid_alive(Pid) when is_integer(Pid), Pid > 0 ->
    case os:cmd("kill -0 " ++ integer_to_list(Pid) ++ " 2>/dev/null; echo $?") of
        "0\n" -> true;
        _ -> false
    end;
is_pid_alive(_) ->
    false.

%% Read the executable basename for a PID (Linux: `/proc/<pid>/comm`;
%% fallback to `ps -o comm=` for portability — macOS / BSD). Returns
%% an empty binary if the lookup fails or the PID is gone.
process_comm(Pid) when is_integer(Pid), Pid > 0 ->
    %% Try /proc first (cheap, no shell-out)
    case file:read_file(filename:join(["/proc", integer_to_list(Pid), "comm"])) of
        {ok, Content} ->
            binary:replace(Content, <<"\n">>, <<"">>, [global]);
        _ ->
            %% Fall back to ps for non-Linux platforms.
            Cmd = "ps -p " ++ integer_to_list(Pid) ++ " -o comm= 2>/dev/null",
            Out = os:cmd(Cmd),
            list_to_binary(string:trim(Out))
    end;
process_comm(_) ->
    <<>>.

%% Send a signal to a PID. `Signal` is one of the binaries `<<"TERM">>`,
%% `<<"KILL">>`, `<<"INT">>`. Returns ok on success, error otherwise
%% (best-effort: any non-zero exit from `kill` becomes error).
%%
%% Targets the process GROUP when the pid leads its own group. A bare
%% `kill <pid>` reaches only the LSP itself, so any grandchild it
%% spawned survives — jdtls and metals both spawn them, and a
%% grandchild that reparents to init is structurally unreachable from
%% a process-tree walk. ADR-030 failure mode 4.
signal_pid(Pid, Signal)
        when is_integer(Pid), Pid > 0,
             is_binary(Signal) ->
    Cmd = io_lib:format("kill -~s ~B 2>/dev/null; echo $?",
                        [Signal, signal_target(Pid)]),
    case os:cmd(lists:flatten(Cmd)) of
        "0\n" -> ok;
        _ -> error
    end;
signal_pid(_, _) ->
    error.

%% Choose what `kill` aims at: the NEGATED process-group id (which
%% signals the whole group) when `Pid` leads its own group, else the
%% bare pid.
%%
%% The group path is the normal one for an LSP pharos spawned: BEAM's
%% `erl_child_setup` already calls setsid() on every port child, so
%% the child comes back as its own session and group leader
%% (pid == pgid == sid) with any grandchild inheriting that pgid.
%% Verified empirically, not assumed — this is also why pharos needs
%% no external setsid wrapper.
%%
%% Three guards, each protecting against a way a group kill goes very
%% wrong. All must hold or we fall back to the single-pid signal,
%% which is never unsafe, only incomplete:
%%
%%   Pgid =:= Pid      the pid actually LEADS the group. Signalling
%%                     `-N` where N is not a group leader hits some
%%                     unrelated group that merely happens to be
%%                     numbered N.
%%   Pgid  >  1        never group 0 — `kill -TERM -0` means "my own
%%                     process group", i.e. pharos signals itself and
%%                     every sibling. Never group 1 either.
%%   Pgid =/= OwnPgid  belt-and-braces against the same suicide via a
%%                     different route (a pid that somehow shares
%%                     pharos's own group).
signal_target(Pid) ->
    case {process_pgid(Pid), own_pgid()} of
        {Pgid, OwnPgid}
                when is_integer(Pgid), is_integer(OwnPgid),
                     Pgid =:= Pid, Pgid > 1, Pgid =/= OwnPgid ->
            -Pgid;
        _ ->
            Pid
    end.

%% Process-group id for a pid, or `undefined` when it can't be read
%% (pid gone, or a platform without a POSIX `ps`). `ps -o pgid=` is
%% used rather than /proc so this works on macOS as well as Linux —
%% same portability reasoning as `process_comm/1` above.
process_pgid(Pid) when is_integer(Pid), Pid > 0 ->
    Out = os:cmd("ps -o pgid= -p " ++ integer_to_list(Pid)
                 ++ " 2>/dev/null"),
    parse_pgid(string:trim(Out));
process_pgid(_) ->
    undefined.

own_pgid() ->
    case parse_pgid(os:getpid()) of
        undefined -> undefined;
        SelfPid -> process_pgid(SelfPid)
    end.

parse_pgid(S) ->
    try list_to_integer(lists:flatten(S))
    catch _:_ -> undefined
    end.

%% Public wrapper for the same recursive delete we use internally on
%% graceful shutdown. Exposed so the cleanup CLI can remove an
%% individual orphan directory after reaping its LSPs.
remove_dir_recursive(Dir) when is_binary(Dir) ->
    try
        del_dir_recursive(binary_to_list(Dir))
    catch
        _:_ -> ok
    end,
    nil.

%% Block the calling Erlang process for Millis milliseconds. Wraps
%% `timer:sleep/1` so Gleam can call it without importing the timer
%% module via FFI. Used by the cleanup CLI to wait the SIGTERM grace
%% period before escalating to SIGKILL.
sleep_ms(Millis) when is_integer(Millis), Millis >= 0 ->
    timer:sleep(Millis),
    nil;
sleep_ms(_) ->
    nil.

%% -- reaping (ADR-037) ------------------------------------------------

%% One reaper per LSP, unlinked so it outlives the actor it watches.
start_reaper(Owner, LspPid, Start, Path) ->
    ensure_reapers_table(),
    Reaper = spawn(fun() ->
        Ref = erlang:monitor(process, Owner),
        receive
            {'DOWN', Ref, process, _, _} -> ok;
            reap -> erlang:demonitor(Ref, [flush])
        end,
        _ = reap_group(LspPid, Start, ?REAP_GRACE_MS, ?REAP_TERM_WAIT_MS),
        _ = file:delete(Path),
        catch ets:delete(?REAPERS, LspPid)
    end),
    ets:insert(?REAPERS, {LspPid, Reaper}),
    ok.

ensure_reapers_table() ->
    case ets:info(?REAPERS) of
        undefined ->
            %% Owned by a process that lives as long as the VM: the
            %% table must not vanish with the first lsp_proc actor.
            Parent = self(),
            spawn(fun() ->
                try ets:new(?REAPERS, [named_table, public, set]) of
                    _ -> Parent ! {?REAPERS, ready}, receive stop -> ok end
                catch error:badarg -> Parent ! {?REAPERS, ready}
                end
            end),
            receive {?REAPERS, ready} -> ok after 1000 -> ok end;
        _ ->
            ok
    end.

reaper_for(LspPid) ->
    case catch ets:lookup(?REAPERS, LspPid) of
        [{_, Reaper}] -> {ok, Reaper};
        _ -> none
    end.

%% Wait up to `GraceMs` for the process group led by `Pgid` (an LSP's
%% os pid; erl_child_setup setsid()s every port child) to empty by
%% itself; TERM what is left; wait `TermWaitMs`; KILL what is left.
%% Returns the signals sent, for tests and logs: [] | [term] |
%% [term, kill].
%%
%% `Start` is the leader's start time as `process_start/1` read it at
%% spawn (<<>> if the LSP was already gone by then). It guards pid
%% reuse: the kernel never reuses a number while any process still
%% uses it as a group id, so if a process now holds pid `Pgid` and
%% didn't start at `Start`, the old group is necessarily empty and
%% nothing is signalled. While the leader is ours the whole group is
%% signalled (`kill -SIG -Pgid`, ADR-031's guards); once the leader is
%% gone, each remaining member is signalled by pid.
reap_group(Pgid, Start, GraceMs, TermWaitMs)
        when is_integer(Pgid), Pgid > 1 ->
    case Pgid =:= os_pid_self() orelse Pgid =:= own_pgid() of
        true -> [];
        false ->
            case wait_group_empty(Pgid, Start, GraceMs) of
                empty -> [];
                {left, _} ->
                    signal_group(Pgid, Start, "TERM"),
                    case wait_group_empty(Pgid, Start, TermWaitMs) of
                        empty -> [term];
                        {left, _} ->
                            signal_group(Pgid, Start, "KILL"),
                            [term, kill]
                    end
            end
    end;
reap_group(_, _, _, _) ->
    [].

wait_group_empty(Pgid, Start, Ms) ->
    Deadline = erlang:monotonic_time(millisecond) + Ms,
    wait_group_empty_until(Pgid, Start, Deadline).

wait_group_empty_until(Pgid, Start, Deadline) ->
    case group_state(Pgid, Start) of
        empty -> empty;
        {left, Members} ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> {left, Members};
                false ->
                    timer:sleep(?REAP_POLL_MS),
                    wait_group_empty_until(Pgid, Start, Deadline)
            end
    end.

%% `empty` when nothing of ours is left in the group (including when
%% the number has been reused), else `{left, Pids}`.
group_state(Pgid, Start) ->
    case leader(Pgid, Start) of
        reused -> empty;
        _ ->
            case group_members(Pgid) of
                [] -> empty;
                Members -> {left, Members}
            end
    end.

%% `ours` (pid `Pgid` alive and started when we recorded), `gone`, or
%% `reused` (alive, and not provably ours: a different start time, or
%% none recorded). Never guess in favour of signalling.
leader(Pgid, Start) ->
    case process_start(Pgid) of
        <<>> -> gone;
        Start when Start =/= <<>> -> ours;
        _ -> reused
    end.

signal_group(Pgid, Start, Sig) ->
    case leader(Pgid, Start) of
        ours ->
            case signal_target(Pgid) of
                Target when Target < 0 -> kill(Sig, Target);
                _ -> [kill(Sig, P) || P <- group_members(Pgid)]
            end;
        gone ->
            [kill(Sig, P) || P <- group_members(Pgid)];
        reused ->
            ok
    end,
    ok.

kill(Sig, Target) ->
    _ = os:cmd(lists:flatten(io_lib:format("kill -~s ~B 2>/dev/null", [Sig, Target]))),
    ok.

%% The live (non-zombie) processes in group `Pgid`, from one `ps` (portable:
%% Linux and macOS), never including this VM.
group_members(Pgid) when is_integer(Pgid) ->
    Self = os_pid_self(),
    [P || {P, G, State} <- ps_pid_pgid(), G =:= Pgid, P =/= Self, State =/= $Z].

ps_pid_pgid() ->
    Out = os:cmd("ps -A -o pid=,pgid=,stat= 2>/dev/null"),
    lists:filtermap(
        fun(Line) ->
            case string:lexemes(Line, " \t") of
                [P, G, [St | _]] ->
                    try {true, {list_to_integer(P), list_to_integer(G), St}}
                    catch _:_ -> false
                    end;
                _ -> false
            end
        end,
        string:split(Out, "\n", all)).

%% A process's start time as `ps -o lstart=` prints it (portable), or
%% <<>> when it is gone. Two reads of one process agree; a different
%% process under a reused pid shows a different one.
process_start(Pid) when is_integer(Pid), Pid > 0 ->
    Out = os:cmd("ps -o lstart= -p " ++ integer_to_list(Pid) ++ " 2>/dev/null"),
    list_to_binary(string:trim(Out));
process_start(_) ->
    <<>>.

%% Application stop: reap whatever this instance still records, at
%% once and with the short timings, before the VM halts. Reapers still
%% running do the same; signalling twice is harmless.
final_reap() ->
    _ = reap_instance_dir(instance_dir(), ?FINAL_GRACE_MS, ?FINAL_TERM_WAIT_MS),
    nil.

%% Daemon or server start: reap the instance dirs of pharos processes
%% that died without stopping, in the background. A dir whose owner pid
%% is alive is skipped, even if that pid now belongs to something else:
%% conservative, and the dir is reaped once that process is gone.
boot_reap() ->
    Self = os_pid_self(),
    _ = spawn(fun() ->
        [reap_instance_dir(Dir, ?REAP_GRACE_MS, ?REAP_TERM_WAIT_MS)
         || {Owner, Dir} <- list_instance_dirs(),
            Owner =/= Self,
            not is_pid_alive(Owner)]
    end),
    nil.

%% Reap every LSP group an instance dir records (in parallel), then
%% remove the dir. Returns how many groups needed a signal. One `ps`
%% first sorts the records: a group with nothing left is just deleted.
%% So is a record without `lsp_start` (written before ADR-037): such a
%% record can be months old, its pid and group numbers reused since,
%% and nothing in it can tell its processes from somebody else's.
reap_instance_dir(Dir, GraceMs, TermWaitMs) when is_binary(Dir) ->
    Records = [{Pid, Path, read_pid_file(Path)} || {Pid, Path} <- list_pid_files(Dir)],
    Live = sets:from_list([G || {_, G, St} <- ps_pid_pgid(), St =/= $Z]),
    Self = self(),
    Jobs = [begin
                Start = proplists:get_value(<<"lsp_start">>, Meta, <<>>),
                Ref = make_ref(),
                spawn(fun() ->
                    Self ! {Ref, reap_group(Pid, Start, GraceMs, TermWaitMs)}
                end),
                Ref
            end || {Pid, _Path, Meta} <- Records,
                   sets:is_element(Pid, Live),
                   proplists:get_value(<<"lsp_start">>, Meta, <<>>) =/= <<>>],
    Signalled = length([1 || Ref <- Jobs,
                             receive {Ref, Sent} -> Sent =/= []
                             after GraceMs + TermWaitMs + 5000 -> false
                             end]),
    _ = del_dir_recursive(binary_to_list(Dir)),
    Signalled.

%% -- internals -------------------------------------------------------

os_pid_self() ->
    list_to_integer(os:getpid()).

iso8601_now() ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:universal_time(),
    iolist_to_binary(io_lib:format(
        "~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ",
        [Y, Mo, D, H, Mi, S])).

%% Remove directory and all contents. Returns ok on success or any
%% atom on best-effort failure — we never let cleanup propagate.
del_dir_recursive(Dir) ->
    case file:list_dir(Dir) of
        {ok, Entries} ->
            lists:foreach(
                fun(Entry) ->
                    Path = filename:join(Dir, Entry),
                    case filelib:is_dir(Path) of
                        true -> del_dir_recursive(Path);
                        false -> _ = file:delete(Path)
                    end
                end,
                Entries),
            _ = file:del_dir(Dir),
            ok;
        _ ->
            ok
    end.
