%% ADR-030 C2: session-log default path + LRU rotation.
%%
%% Three pieces:
%%
%% 1. `default_session_log_path/0` — compute a per-PID per-timestamp
%%    path under the log dir (`log_dir/0`). Returned to the Gleam
%%    config layer when the user has not set `PHAROS_LOG_FILE`
%%    explicitly and the on-disk default is not configured. Each
%%    pharos instance ends up with its own readable log file so
%%    five-pharos benchmarks (Phase 5 was the trigger) no longer
%%    clobber each other.
%%
%% 2. `rotate_lru/2` — keep the N most recent files matching a
%%    `Prefix*` glob under the log cache dir; delete older. Called
%%    once at boot for `session-*.log` (keep 10) and
%%    `erl_crash-*.dump` (keep 5).
%%
%% 3. `migrate_cwd_crash_dump/0` — if a legacy `erl_crash.dump`
%%    exists in the current working directory, move it into the
%%    cache dir with an mtime-stamped name. Handles pre-ADR-030
%%    crash dumps left behind by users who upgraded mid-incident.
%%
%% All operations are best-effort: ENOENT, ENOSPC, EACCES, and
%% missing $HOME all degrade silently. Pharos's hot path never
%% depends on rotation succeeding.

-module(pharos_log_rotate_ffi).
-include_lib("kernel/include/file.hrl").
-export([
    default_session_log_path/0,
    log_dir/0,
    log_cache_dir/0,
    rotate_lru/2,
    migrate_cwd_crash_dump/0,
    secure_crash_files/0
]).

%% Returns the per-PID per-timestamp session log path as a binary,
%% or `nil` if $HOME cannot be resolved (very rare; do not block
%% pharos boot on it).
%%
%% Path: `<log dir>/session-<pid>-<YYYY-MM-DD-HHMMSS>.log`
default_session_log_path() ->
    case log_dir() of
        none -> none;
        {ok, Dir} ->
            try
                ok = filelib:ensure_dir(filename:join(Dir, "x")),
                Pid = os:getpid(),
                Stamp = timestamp_filename(),
                Name = lists:flatten(
                    io_lib:format("session-~s-~s.log", [Pid, Stamp])),
                {some, list_to_binary(filename:join(Dir, Name))}
            catch
                _:_ -> none
            end
    end.

%% pharos's log dir, `${XDG_STATE_HOME:-$HOME/.local/state}/pharos/log`
%% (ADR-034: logs are state, not cache), created `0700` because crash
%% dumps written there hold the daemon's process state, sessions' env
%% included. Every log, crash log and crash dump path derives from it.
%% `none` when neither XDG_STATE_HOME (absolute) nor HOME is set.
log_dir() ->
    case log_cache_dir_internal() of
        none -> none;
        {ok, Dir} ->
            try
                ok = filelib:ensure_dir(filename:join(Dir, "x")),
                _ = file:change_mode(Dir, 8#700),
                {ok, Dir}
            catch
                _:_ -> none
            end
    end.

%% Return the log dir as a binary so the Gleam side can pass it to
%% `rotate_lru/2` without recomputing.
log_cache_dir() ->
    case log_cache_dir_internal() of
        none -> <<>>;
        {ok, Dir} -> list_to_binary(Dir)
    end.

%% LRU-trim files matching `Prefix*` under the log cache dir down
%% to `Keep` files (the newest by mtime). Older files are deleted.
%% Returns the number of deletions on success, 0 on any failure.
rotate_lru(Prefix, Keep)
        when is_binary(Prefix), is_integer(Keep), Keep >= 0 ->
    case log_cache_dir_internal() of
        none -> 0;
        {ok, Dir} ->
            try
                {ok, Entries} = file:list_dir(Dir),
                PrefixStr = binary_to_list(Prefix),
                Matching =
                    [filename:join(Dir, E) || E <- Entries,
                                              lists:prefix(PrefixStr, E)],
                %% Pair each path with its mtime, sort descending so
                %% newest comes first, drop the head `Keep` entries,
                %% delete what's left.
                Annotated = [{mtime_of(P), P} || P <- Matching],
                Sorted = lists:sort(fun({A, _}, {B, _}) -> A > B end,
                                    Annotated),
                ToDelete = lists:nthtail(min(Keep, length(Sorted)), Sorted),
                lists:foldl(
                    fun({_, Path}, Acc) ->
                        case file:delete(Path) of
                            ok -> Acc + 1;
                            _ -> Acc
                        end
                    end,
                    0,
                    ToDelete)
            catch
                _:_ -> 0
            end
    end.

%% If `erl_crash.dump` exists in the current working directory,
%% move it under the cache dir renamed to `erl_crash-<mtime>.dump`
%% so it participates in LRU rotation. Best-effort.
migrate_cwd_crash_dump() ->
    try
        case file:read_file_info("erl_crash.dump") of
            {ok, #file_info{mtime = MTime}} ->
                case log_dir() of
                    none -> nil;
                    {ok, Dir} ->
                        ok = filelib:ensure_dir(filename:join(Dir, "x")),
                        Stamp = mtime_to_stamp(MTime),
                        NewName = lists:flatten(
                            io_lib:format("erl_crash-~s.dump", [Stamp])),
                        NewPath = filename:join(Dir, NewName),
                        _ = file:rename("erl_crash.dump", NewPath),
                        nil
                end;
            _ -> nil
        end
    catch
        _:_ -> nil
    end,
    nil.

%% Tighten every crash dump and crash log in the log dir to `0600`.
%% The BEAM writes a dump with the default umask, and the dump holds
%% process state (a daemon's includes sessions' env, ADR-034); the
%% `0700` dir already keeps other users out, this closes the file too.
%% Best-effort.
secure_crash_files() ->
    try
        {ok, Dir} = log_dir(),
        {ok, Entries} = file:list_dir(Dir),
        [file:change_mode(filename:join(Dir, E), 8#600)
         || E <- Entries,
            lists:prefix("erl_crash-", E) orelse lists:prefix("crash-", E)
                orelse E =:= "last-crash.log"],
        nil
    catch
        _:_ -> nil
    end.

%% -- internals -------------------------------------------------------

log_cache_dir_internal() ->
    case os:getenv("XDG_STATE_HOME") of
        [$/ | _] = State -> {ok, filename:join([State, "pharos", "log"])};
        _ ->
            case os:getenv("HOME") of
                false -> none;
                Home ->
                    {ok, filename:join([Home, ".local", "state", "pharos", "log"])}
            end
    end.

mtime_of(Path) ->
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, #file_info{mtime = MTime}} -> MTime;
        _ -> 0
    end.

timestamp_filename() ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:universal_time(),
    lists:flatten(
        io_lib:format("~4..0B-~2..0B-~2..0B-~2..0B~2..0B~2..0B",
                      [Y, Mo, D, H, Mi, S])).

mtime_to_stamp({{Y, Mo, D}, {H, Mi, S}}) ->
    lists:flatten(
        io_lib:format("~4..0B-~2..0B-~2..0B-~2..0B~2..0B~2..0B",
                      [Y, Mo, D, H, Mi, S])).
