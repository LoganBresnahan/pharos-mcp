%% ETS-backed diagnostics cache.
%%
%% LSP servers push `textDocument/publishDiagnostics` when they have
%% something to say, not when asked, and some (rust-analyzer) skip a
%% publish when a file's diagnostics did not change. So the last
%% publish has to be kept for get_diagnostics to read.
%%
%% ADR-038: three public tables, every row keyed by {Uri, ServerId,
%% ProcPid}. One URI can be open under the same server id in two procs
%% of a shared daemon (a dependency file routed to whichever workspace
%% asks, ADR-032; or two ADR-034 spawn variants), so the proc is part
%% of every key and readers ask about the proc they prepared.
%% - entries:  {Key, Seq, Params}, one per publish, written by the proc
%%   that read it, stamped with a node-wide monotonic sequence number.
%% - synced:   {Key, Seq, Version | failed | closed}, written by the proc right
%%   after it writes a didOpen / re-sync, so it orders exactly against
%%   the publishes the same actor caches. It is also the sync's
%%   acknowledgement: a caller waits for it to reach the version the
%%   pool recorded. `failed` marks a write that did not go through;
%%   `closed` a document the proc has handed back to the disk.
%% - expected: {Key, Version | closed}, written by the pool when it
%%   records a sync or a close, before the proc has written it.
%% Plus one row per proc in each of synced / expected, keyed {batch,
%% Pid}: the pool numbers every batch of syncs it sends a proc
%% (`expect_batch/2`), and the proc stamps the batch, and when, as it
%% starts writing it (`mark_batch/1`). A file's diagnostics depend on
%% the other files the server has, so a batch makes every earlier entry
%% on that proc carried over, not just the changed files'. For a
%% document the batch did not change, that lasts the batch's settle
%% window: a server that has not republished a file by then is taken to
%% have left its diagnostics as they were (servers such as gopls and
%% rust-analyzer never republish an unchanged set).
%% An entry is fresh when the stamps show the expected version written
%% and the entry came after it, and the expected batch written and the
%% entry came after it or its window has passed; any other entry is
%% carried over (it describes an older text, or the server held back an
%% unchanged set). An entry from before the document was
%% closed is not served at all: it describes text pharos no longer
%% holds open, possibly a file that is gone. Nothing is dropped on a
%% sync, so a server that answers fast is never wiped. A proc's rows go
%% when it does (`forget_proc/1`).
%%
%% Owner: whichever process calls init/0 first. ETS tables outlive
%% the owner only if they were created with `heir` set; we do not,
%% so the tables die if the owner process dies. The supervisor root
%% is the owner; for now any of the application's primary callers
%% (pharos:main / app callback) is fine — they live for the whole
%% BEAM uptime.

-module(pharos_diagnostics_cache_ffi).
-export([init/0, put/3, put_publish/4, get/2, get_all_for_uri/1, drop/2,
         drop_uri/1, mark_synced/3, mark_failed/2, mark_closed/2,
         mark_batch/1, stamp_status/4, close_status/4, expect/4,
         expect_closed/3, expect_batch/2, forget_proc/1, lookup/4,
         settle_left/2]).

-define(TABLE, pharos_diagnostics_cache).
-define(SYNCED, pharos_diagnostics_synced).
-define(EXPECTED, pharos_diagnostics_expected).

init() ->
    ensure_table(?TABLE),
    ensure_table(?SYNCED),
    ensure_table(?EXPECTED),
    nil.

ensure_table(Name) ->
    case ets:info(Name) of
        undefined ->
            ets:new(Name, [named_table, public, set, {read_concurrency, true}]);
        _ ->
            Name
    end.

seq() ->
    erlang:unique_integer([monotonic]).

%% The same clock get_diagnostics measures its deadline with.
now_ms() ->
    erlang:monotonic_time(millisecond).

%% Record a publish read by the calling proc.
put(Uri, ServerId, Term) when is_binary(Uri), is_binary(ServerId) ->
    true = ets:insert(?TABLE, {{Uri, ServerId, self()}, seq(), Term}),
    nil.

%% A publish carrying a `version` lower than the version this proc last
%% synced admits to describing text the server has already replaced:
%% drop it. `Version` is `{some, V}` or `none` (Gleam's Option).
put_publish(Uri, ServerId, Version, Term) when is_binary(Uri), is_binary(ServerId) ->
    Stale = case {Version, ets:lookup(?SYNCED, {Uri, ServerId, self()})} of
        {{some, V}, [{_, _, Synced}]} when is_integer(V), is_integer(Synced) -> V < Synced;
        _ -> false
    end,
    case Stale of
        true -> nil;
        false -> put(Uri, ServerId, Term)
    end.

%% Any proc's entry for (Uri, ServerId): for tests and introspection.
get(Uri, ServerId) when is_binary(Uri), is_binary(ServerId) ->
    case ets:match_object(?TABLE, {{Uri, ServerId, '_'}, '_', '_'}) of
        [{_, _, Term} | _] -> {ok, Term};
        [] -> {error, nil}
    end.

%% Every cached entry for `Uri`, as `{ServerId, Term}`.
get_all_for_uri(Uri) when is_binary(Uri) ->
    Rows = ets:match_object(?TABLE, {{Uri, '_', '_'}, '_', '_'}),
    [{ServerId, Term} || {{_, ServerId, _}, _, Term} <- Rows].

drop(Uri, ServerId) when is_binary(Uri), is_binary(ServerId) ->
    ets:match_delete(?TABLE, {{Uri, ServerId, '_'}, '_', '_'}),
    nil.

%% Forget everything about a URI regardless of server or proc: its
%% entries, its synced stamps and its expectations.
drop_uri(Uri) when is_binary(Uri) ->
    ets:match_delete(?TABLE, {{Uri, '_', '_'}, '_', '_'}),
    ets:match_delete(?SYNCED, {{Uri, '_', '_'}, '_', '_'}),
    ets:match_delete(?EXPECTED, {{Uri, '_', '_'}, '_'}),
    nil.

%% Called by the proc, right after writing a sync.
mark_synced(Uri, ServerId, Version)
        when is_binary(Uri), is_binary(ServerId), is_integer(Version) ->
    true = ets:insert(?SYNCED, {{Uri, ServerId, self()}, seq(), Version}),
    nil.

%% Called by the proc as it starts writing batch `N`, before any write:
%% the actor reads no frame in between, so every entry cached after
%% this was published after the batch reached the server. The time
%% starts the batch's settle window.
mark_batch(N) when is_integer(N) ->
    true = ets:insert(?SYNCED, {{batch, self()}, seq(), N, now_ms()}),
    nil.

%% Called by the pool when it sends proc `Pid` batch `N`.
expect_batch(Pid, N) when is_integer(N) ->
    true = ets:insert(?EXPECTED, {{batch, Pid}, N}),
    nil.

%% Called by the proc when a sync's write failed.
mark_failed(Uri, ServerId) when is_binary(Uri), is_binary(ServerId) ->
    true = ets:insert(?SYNCED, {{Uri, ServerId, self()}, seq(), failed}),
    nil.

%% Called by the proc after a didClose: the server is back on the disk.
%% Kept as a stamp (not deleted) so a caller still waiting on an earlier
%% sync of the document, which another session's LRU just closed, stops
%% waiting.
mark_closed(Uri, ServerId) when is_binary(Uri), is_binary(ServerId) ->
    true = ets:insert(?SYNCED, {{Uri, ServerId, self()}, seq(), closed}),
    nil.

%% reached | pending | failed: has `Pid` written the document's sync at
%% `Version` (or later), or closed it since?
stamp_status(Uri, ServerId, Version, Pid)
        when is_binary(Uri), is_binary(ServerId), is_integer(Version) ->
    case ets:lookup(?SYNCED, {Uri, ServerId, Pid}) of
        [{_, _, failed}] -> failed;
        [{_, _, closed}] -> reached;
        [{_, _, V}] when V >= Version -> reached;
        _ -> pending
    end.

%% reached | pending | failed: has `Pid` written the close of a document
%% last synced at `Version`, or reopened it since (at a later version,
%% which it writes after the close)?
close_status(Uri, ServerId, Version, Pid)
        when is_binary(Uri), is_binary(ServerId), is_integer(Version) ->
    case ets:lookup(?SYNCED, {Uri, ServerId, Pid}) of
        [{_, _, failed}] -> failed;
        [{_, _, closed}] -> reached;
        [{_, _, V}] when is_integer(V), V > Version -> reached;
        _ -> pending
    end.

%% Called by the pool when it records a sync (before the proc writes it).
expect(Uri, ServerId, Version, Pid)
        when is_binary(Uri), is_binary(ServerId), is_integer(Version) ->
    true = ets:insert(?EXPECTED, {{Uri, ServerId, Pid}, Version}),
    nil.

%% Called by the pool when it records a close (before the proc writes it).
expect_closed(Uri, ServerId, Pid) when is_binary(Uri), is_binary(ServerId) ->
    true = ets:insert(?EXPECTED, {{Uri, ServerId, Pid}, closed}),
    nil.

%% A proc is gone: drop every row it owned.
forget_proc(Pid) ->
    ets:match_delete(?TABLE, {{'_', '_', Pid}, '_', '_'}),
    ets:match_delete(?SYNCED, {{'_', '_', Pid}, '_', '_'}),
    ets:match_delete(?EXPECTED, {{'_', '_', Pid}, '_'}),
    ets:delete(?SYNCED, {batch, Pid}),
    ets:delete(?EXPECTED, {batch, Pid}),
    nil.

%% fresh | carried_over | missing for the entry proc `Pid` cached, as
%% Gleam's `Lookup`. Fresh needs:
%% - the document: with an expected row, the stamp shows the expected
%%   version written and the entry came after it (a stamp behind the
%%   expectation means the sync is not written yet); without one (a URI
%%   pharos does not hold open on that proc, such as a file the server
%%   reports on its own), no stamp newer than the entry;
%% - the proc: the expected batch written, and the entry after it or
%%   the batch's settle window (`SettleMs` from when the proc wrote it)
%%   passed.
%% An entry from before a close, or with a close expected and not yet
%% written, is missing. The entry is read before the stamps, so a race
%% can only make an answer carried over or missing, never falsely fresh.
lookup(Uri, ServerId, Pid, SettleMs)
        when is_binary(Uri), is_binary(ServerId), is_integer(SettleMs) ->
    Key = {Uri, ServerId, Pid},
    case ets:lookup(?TABLE, Key) of
        [] -> missing;
        [{_, Seq, Term}] ->
            case doc_state(Key, Seq) of
                gone -> missing;
                Doc ->
                    Fresh = Doc =:= fresh
                        andalso batch_settled(Seq, Pid, SettleMs),
                    case Fresh of
                        true -> {fresh, Term};
                        false -> {carried_over, Term}
                    end
            end
    end.

%% fresh | stale | gone: the entry at `Seq` against its document's rows.
doc_state(Key, Seq) ->
    case {ets:lookup(?EXPECTED, Key), ets:lookup(?SYNCED, Key)} of
        {[{_, closed}], [{_, Closed, closed}]} -> after_close(Seq, Closed);
        {[{_, closed}], _} -> gone;
        {[{_, V}], [{_, Synced, V}]} -> after_sync(Seq, Synced);
        {[_], _} -> stale;
        {[], [{_, Closed, closed}]} -> after_close(Seq, Closed);
        {[], [{_, Synced, _}]} -> after_sync(Seq, Synced);
        {[], []} -> fresh
    end.

after_close(Seq, Closed) when Seq > Closed -> fresh;
after_close(_, _) -> gone.

after_sync(Seq, Synced) when Seq > Synced -> fresh;
after_sync(_, _) -> stale.

%% Is the entry at `Seq` settled against the last batch on `Pid`: that
%% batch written, and the entry after it or its settle window passed?
batch_settled(Seq, Pid, SettleMs) ->
    Key = {batch, Pid},
    case {ets:lookup(?EXPECTED, Key), ets:lookup(?SYNCED, Key)} of
        {[{_, N}], [{_, BSeq, M, At}]} when M >= N ->
            Seq > BSeq orelse now_ms() >= At + SettleMs;
        {[_], _} -> false;
        {[], [{_, BSeq, _, At}]} -> Seq > BSeq orelse now_ms() >= At + SettleMs;
        {[], []} -> true
    end.

%% Milliseconds left in the settle window of the last batch on proc
%% `Pid`: from when the proc wrote it, a full window if it has not yet,
%% 0 once it has passed or with no batch. A carried-over entry waits
%% this long at most for a fresh one: the window runs from the sync,
%% not from the question, so asking again later does not wait again.
settle_left(Pid, SettleMs) when is_integer(SettleMs) ->
    Key = {batch, Pid},
    case {ets:lookup(?EXPECTED, Key), ets:lookup(?SYNCED, Key)} of
        {[{_, N}], [{_, _, M, At}]} when M >= N -> max(0, At + SettleMs - now_ms());
        {[_], _} -> SettleMs;
        {[], [{_, _, _, At}]} -> max(0, At + SettleMs - now_ms());
        {[], []} -> 0
    end.
