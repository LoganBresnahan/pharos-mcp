%% Erlang FFI: minimal filesystem helpers for path discovery and
%% reading file contents.
%%
%% Used by `pharos/workspace_root` (ancestor walk looking for a
%% project root marker) and by tools that need on-disk file content
%% as a fallback when the optional VSCode bridge is not available
%% (Milestone 7).
%%
%% Returns Gleam-friendly tagged tuples shaped as Result(t, e).

-module(pharos_fs_ffi).
-export([is_regular_file/1, is_directory/1, dirname/1, read_file/1, shell/1, encode_json/1, cwd/0, atomic_write_text/2, rm_rf/1, dir_size_bytes/1, which_executable/1, mkdir_p/1, list_dir/1, delete_file/1, write_excl/2, home_dir/0, now_iso8601/0]).

is_regular_file(Path) ->
    filelib:is_regular(binary_to_list(Path)).

is_directory(Path) ->
    filelib:is_dir(binary_to_list(Path)).

dirname(Path) ->
    list_to_binary(filename:dirname(binary_to_list(Path))).

read_file(Path) ->
    case file:read_file(binary_to_list(Path)) of
        {ok, Bytes} ->
            {ok, Bytes};
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Run a shell command. Accepts a binary (Gleam String). Returns a
%% binary holding the command's combined stdout+stderr. Used by tests
%% to set up temp directories without dragging in a filesystem dep.
shell(Cmd) ->
    list_to_binary(os:cmd(binary_to_list(Cmd))).

%% Re-encode a JSON-derived term back to a JSON binary. OTP 27's
%% json:encode/1 returns iodata (a deeply nested iolist of binaries
%% and small integers); flatten to a single binary so Gleam can use
%% it as a String. Used by tools/tier1/diagnostics to round-trip the
%% LSP's response back through MCP without a Json type detour.
encode_json(Term) ->
    iolist_to_binary(json:encode(Term)).

%% Current working directory as a binary. Used by config loader to
%% start the .pharos.toml ascent from the invocation directory. Falls
%% back to the empty binary if the underlying syscall fails (vanishingly
%% rare, but file:get_cwd/0 can return {error, _} on permission issues).
cwd() ->
    case file:get_cwd() of
        {ok, Path} -> list_to_binary(Path);
        {error, _} -> <<>>
    end.

%% Atomic write+rename: serialise `Text` to `Path.tmp`, then rename
%% over `Path`. POSIX rename is atomic on the same filesystem, so a
%% concurrent reader sees either the prior contents or the new ones —
%% never a half-written file. Used by `mcp/http`'s port_file feature.
%% Parent directory must exist; we do not mkdir.
%%
%% Returns:
%%   {ok, nil}    — success
%%   {error, Bin} — human-readable error binary
atomic_write_text(Path, Text) when is_binary(Path), is_binary(Text) ->
    PathStr = binary_to_list(Path),
    Tmp = PathStr ++ ".tmp",
    case file:write_file(Tmp, Text) of
        ok ->
            case file:rename(Tmp, PathStr) of
                ok -> {ok, nil};
                {error, Reason} ->
                    file:delete(Tmp),
                    {error, format_reason(Reason)}
            end;
        {error, Reason} ->
            {error, format_reason(Reason)}
    end.

format_reason(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).

%% Recursively remove a directory (rm -rf semantics). Returns:
%%   {ok, nil}   — directory gone (or never existed)
%%   {error, Bin} — error binary
%%
%% Safe on a path that does not exist (returns ok). Used by
%% `pharos --purge-cache` to nuke the Burrito extract dir.
rm_rf(Path) when is_binary(Path) ->
    PathStr = binary_to_list(Path),
    case filelib:is_dir(PathStr) orelse filelib:is_regular(PathStr) of
        false -> {ok, nil};
        true ->
            case file:del_dir_r(PathStr) of
                ok -> {ok, nil};
                {error, enoent} -> {ok, nil};
                {error, Reason} -> {error, format_reason(Reason)}
            end
    end.

%% Recursive directory size in bytes. Returns 0 for missing paths.
%% Used by `pharos --doctor` + `--purge-cache` so output reports
%% how many MB the cache holds before/after.
dir_size_bytes(Path) when is_binary(Path) ->
    PathStr = binary_to_list(Path),
    case filelib:is_dir(PathStr) of
        false -> 0;
        true ->
            Files = filelib:wildcard(filename:join(PathStr, "**/*")),
            lists:foldl(fun(F, Acc) ->
                case filelib:is_regular(F) of
                    true ->
                        case file:read_file_info(F) of
                            {ok, Info} -> Acc + element(2, Info); %% size
                            _ -> Acc
                        end;
                    false -> Acc
                end
            end, 0, Files)
    end.

%% Resolve a bare command name through PATH. Mirrors `which`. Returns:
%%   {ok, AbsPath} — absolute path to the executable
%%   {error, nil}  — not found
%%
%% Honours absolute paths (returned verbatim if they exist + are
%% executable).
which_executable(Cmd) when is_binary(Cmd) ->
    CmdStr = binary_to_list(Cmd),
    case filename:pathtype(CmdStr) of
        absolute ->
            case filelib:is_regular(CmdStr) of
                true -> {ok, list_to_binary(CmdStr)};
                false -> {error, nil}
            end;
        _ ->
            case os:find_executable(CmdStr) of
                false -> {error, nil};
                Path -> {ok, list_to_binary(Path)}
            end
    end.

%% Memory-system filesystem helpers (ADR-027). All accept and return
%% binaries to match the Gleam String calling convention.

%% Create `Path` and all missing parent directories. Returns
%% {ok, nil} or {error, BinaryReason}.
mkdir_p(Path) when is_binary(Path) ->
    case filelib:ensure_dir(binary_to_list(Path) ++ "/.placeholder") of
        ok -> {ok, nil};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

%% List the immediate (non-recursive) regular-file entries under
%% `Path`. Returns {ok, [Binary]} or {error, BinaryReason}. Entries
%% are the basename only (not full paths).
list_dir(Path) when is_binary(Path) ->
    case file:list_dir(binary_to_list(Path)) of
        {ok, Names} ->
            Filtered = [list_to_binary(N) || N <- Names],
            {ok, Filtered};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

%% Delete a regular file at `Path`. Returns {ok, nil} on success,
%% {error, BinaryReason} otherwise. {error, enoent} (file already
%% gone) collapses into {ok, nil} — idempotent prune.
delete_file(Path) when is_binary(Path) ->
    case file:delete(binary_to_list(Path)) of
        ok -> {ok, nil};
        {error, enoent} -> {ok, nil};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

%% Atomic create-or-fail write. Uses {exclusive, write} so a concurrent
%% second call to the same path returns {error, eexist} rather than
%% silently overwriting. ADR-027 §6.a relies on this for no-overwrite
%% save semantics.
write_excl(Path, Text) when is_binary(Path), is_binary(Text) ->
    PathStr = binary_to_list(Path),
    case file:open(PathStr, [exclusive, write, binary]) of
        {ok, Fd} ->
            case file:write(Fd, Text) of
                ok ->
                    file:close(Fd),
                    {ok, nil};
                {error, Reason} ->
                    file:close(Fd),
                    file:delete(PathStr),
                    {error, format_reason(Reason)}
            end;
        {error, eexist} -> {error, <<"eexist">>};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

%% Resolve the current user's home directory. Returns the path as a
%% binary; falls back to "/" if HOME is unset (rare in practice).
home_dir() ->
    case os:getenv("HOME") of
        false -> <<"/">>;
        Path -> list_to_binary(Path)
    end.

%% Wall-clock time as an ISO-8601 / RFC-3339 binary in UTC. Format:
%% `2026-05-16T07:30:00Z`. Used by memory_save to stamp `created` and
%% `last_accessed`. Second precision is enough — the value is read
%% by humans and used for ordering (lex == chrono); sub-second
%% precision would add noise without helping.
now_iso8601() ->
    Now = erlang:system_time(second),
    Iso = calendar:system_time_to_rfc3339(Now, [{offset, "Z"}]),
    list_to_binary(Iso).
