%% File-system reads for the watched-files scan (ADR-043).
%%
%% Gleam has no binding for `file:read_link_info/2`, whose `file_info`
%% record carries the ctime and inode the scan compares (a restore that
%% keeps the old mtime still moves ctime; a file replaced by rename gets a
%% new inode), nor for listing a directory without following symlinks.
%% Hashing a file's contents is here too, so the scan reads it once.

-module(pharos_watch_ffi).
-export([list_dir/1, stat/1, hash_file/2, now_seconds/0,
         watchers_init/0, watchers_put/2, watchers_delete/1, watchers_for/1, watchers_forget/1,
         scanners_init/0, scanner_lookup/1, scanner_claim/2, scanner_drop/1,
         spawned_store/0, spawned_second/1, now_ms/0, safe_call/1,
         notes_add/1, notes_take/0, deadline_set/1, deadline_get/0,
         new_alias/0, drop_alias/1]).

%% The names in `Dir`, or an error when it can't be listed (gone, not a
%% directory, no permission): the scan then treats it as empty.
list_dir(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} -> {ok, [name(N) || N <- Names]};
        {error, _} -> {error, nil}
    end.

%% `{Kind, Mtime, Ctime, Size, Inode}` for `Path`, not following a final
%% symlink (a symlinked directory isn't walked into, so a link loop can't
%% trap the scan). Kind is <<"dir">>, <<"file">> or <<"other">>; times are
%% whole POSIX seconds, as file_info gives them.
stat(Path) ->
    case file:read_link_info(Path, [{time, posix}]) of
        {ok, FI} ->
            Kind = case element(3, FI) of
                directory -> <<"dir">>;
                regular -> <<"file">>;
                _ -> <<"other">>
            end,
            {ok, {Kind, element(6, FI), element(7, FI), element(2, FI), element(12, FI)}};
        {error, _} -> {error, nil}
    end.

%% SHA-256 of the file's contents, or an error when it's over `MaxBytes`
%% or can't be read.
hash_file(Path, MaxBytes) ->
    case filelib:file_size(Path) of
        Size when Size > MaxBytes -> {error, nil};
        _ ->
            case file:read_file(Path) of
                {ok, Bytes} -> {ok, crypto:hash(sha256, Bytes)};
                {error, _} -> {error, nil}
            end
    end.

now_seconds() ->
    os:system_time(second).

%% A name as UTF-8 (#20: names arrive as the file system's bytes or
%% characters depending on the VM's file name encoding).
name(N) when is_binary(N) -> N;
name(N) -> pharos_fs_ffi:name_to_binary(N).

%% The watchers each LSP proc's server registered for
%% workspace/didChangeWatchedFiles, keyed {ProcPid, RegistrationId}. The
%% register handler runs inside the proc, so it keys by self().
-define(WATCHERS, pharos_lsp_watchers).

watchers_init() ->
    case ets:info(?WATCHERS) of
        undefined -> ets:new(?WATCHERS, [named_table, public, set, {read_concurrency, true}]), nil;
        _ -> nil
    end.

watchers_put(RegId, Watchers) ->
    catch ets:insert(?WATCHERS, {{self(), RegId}, Watchers}),
    nil.

watchers_delete(RegId) ->
    catch ets:delete(?WATCHERS, {self(), RegId}),
    nil.

%% Every watcher `Pid`'s server has registered, in no particular order.
watchers_for(Pid) ->
    try lists:append(ets:select(?WATCHERS, [{{{Pid, '_'}, '$1'}, [], ['$1']}]))
    catch error:badarg -> []
    end.

%% Forgets a proc's registrations (its server is gone).
watchers_forget(Pid) ->
    catch ets:match_delete(?WATCHERS, {{Pid, '_'}, '_'}),
    catch ets:delete(?WATCHERS, {spawned, Pid}),
    nil.

%% The scanner actor for each LSP proc, keyed by the proc's pid.
-define(SCANNERS, pharos_watch_scanners).

scanners_init() ->
    case ets:info(?SCANNERS) of
        undefined -> ets:new(?SCANNERS, [named_table, public, set, {read_concurrency, true}]), nil;
        _ -> nil
    end.

scanner_lookup(Pid) ->
    try ets:lookup(?SCANNERS, Pid) of
        [{_, Subject}] -> {ok, Subject};
        [] -> {error, nil}
    catch error:badarg -> {error, nil}
    end.

%% Claims `Pid`'s slot for `Subject`; false when another scanner has it.
scanner_claim(Pid, Subject) ->
    try ets:insert_new(?SCANNERS, {Pid, Subject})
    catch error:badarg -> false
    end.

scanner_drop(Pid) ->
    catch ets:delete(?SCANNERS, Pid),
    nil.

%% The second each proc spawned its server, in the watchers table under
%% {spawned, Pid} (stored by the proc itself, so keyed by self()).
spawned_store() ->
    catch ets:insert(?WATCHERS, {{spawned, self()}, os:system_time(second)}),
    nil.

spawned_second(Pid) ->
    try ets:lookup(?WATCHERS, {spawned, Pid}) of
        [{_, Second}] -> Second;
        [] -> 0
    catch error:badarg -> 0
    end.

now_ms() ->
    erlang:monotonic_time(millisecond).

%% Runs `F`, turning any exception (an exit, a failed assertion, a throw)
%% into an error, so a question never fails because its scan did.
safe_call(F) ->
    try {ok, F()}
    catch _:_ -> {error, nil}
    end.

%% Notes for the answer the calling process is building (ADR-043): the
%% scan runs in the request's process, which then builds the reply, so
%% the process dictionary carries the note from one to the other. Each
%% note once, in the order added.
notes_add(Note) ->
    Notes = case get(pharos_answer_notes) of undefined -> []; L -> L end,
    case lists:member(Note, Notes) of
        true -> ok;
        false -> put(pharos_answer_notes, Notes ++ [Note])
    end,
    nil.

notes_take() ->
    erase(pharos_question_deadline),
    case erase(pharos_answer_notes) of
        undefined -> [];
        Notes -> Notes
    end.

%% The question's deadline (monotonic ms), in the request process's
%% dictionary beside its notes, and cleared with them.
deadline_set(At) when is_integer(At) ->
    put(pharos_question_deadline, At),
    nil.

deadline_get() ->
    case get(pharos_question_deadline) of
        undefined -> {error, nil};
        At -> {ok, At}
    end.

%% A reply address for one scanner request: an alias of the calling
%% process, typed as a pid for Gleam's Subject. After drop_alias, a reply
%% that comes too late is discarded by the runtime instead of piling up
%% in the caller's mailbox.
new_alias() ->
    erlang:alias().

drop_alias(Alias) ->
    erlang:unalias(Alias),
    nil.
