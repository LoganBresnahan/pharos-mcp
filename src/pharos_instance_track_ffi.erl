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
%%   - `deregister_lsp/1`: called from `client.close/1`. Removes the
%%     `<lsp-pid>.pid` file. Idempotent (silent on missing file).
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
    remove_dir_recursive/1,
    sleep_ms/1
]).

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
                Body = iolist_to_binary([
                    <<"pharos_pid=">>, integer_to_binary(os_pid_self()), $\n,
                    <<"lsp_pid=">>, integer_to_binary(OsPid), $\n,
                    <<"lsp_binary=">>, ResolvedBinary, $\n,
                    <<"server_id=">>, ServerId, $\n,
                    <<"workspace=">>, Workspace, $\n,
                    <<"started_at=">>, iso8601_now(), $\n
                ]),
                ok = file:write_file(Path, Body)
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
    try
        Dir = instance_dir_path(),
        Path = filename:join(Dir, integer_to_list(LspPid) ++ ".pid"),
        _ = file:delete(Path)
    catch
        _:_ -> ok
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
signal_pid(Pid, Signal)
        when is_integer(Pid), Pid > 0,
             is_binary(Signal) ->
    Cmd = io_lib:format("kill -~s ~B 2>/dev/null; echo $?",
                        [Signal, Pid]),
    case os:cmd(lists:flatten(Cmd)) of
        "0\n" -> ok;
        _ -> error
    end;
signal_pid(_, _) ->
    error.

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
