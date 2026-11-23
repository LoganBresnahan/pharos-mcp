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
         mark_batch/1, batch_status/2, stamp_status/4, close_status/4, expect/4,
         expect_closed/3, expect_batch/2, forget_proc/1, lookup/4,
         settle_left/2, progress/2, progress_quiet/5,
         progress_active/2, sync_age_ms/3, publish_age_ms/3,
         mark_opened/3, last_sync_was_open/3, first_publish_age_ms/3, first_open_age_ms/1,
         progress_ended_within/2]).

-define(TABLE, pharos_diagnostics_cache).
-define(SYNCED, pharos_diagnostics_synced).
-define(EXPECTED, pharos_diagnostics_expected).
%% #30: the `$/progress` a proc's server reports after readiness:
%%   {{Pid, Token}, BeginSeq, BeginMs}   one per running token
%%   {{sync, Pid, Uri, ServerId}, Ms}    when each document's sync was written
-define(PROGRESS, pharos_diagnostics_progress).

init() ->
    ensure_table(?TABLE),
    ensure_table(?SYNCED),
    ensure_table(?EXPECTED),
    ensure_table(?PROGRESS),
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
put(Uri0, ServerId, Term) when is_binary(Uri0), is_binary(ServerId) ->
    Uri = key(Uri0),
    true = ets:insert(?TABLE, {{Uri, ServerId, self()}, seq(), Term}),
    nil.

%% A publish carrying a `version` lower than the version this proc last
%% synced admits to describing text the server has already replaced:
%% drop it. `Version` is `{some, V}` or `none` (Gleam's Option).
put_publish(Uri0, ServerId, Version, Term) when is_binary(Uri0), is_binary(ServerId) ->
    Uri = key(Uri0),
    Stale = case {Version, ets:lookup(?SYNCED, {Uri, ServerId, self()})} of
        {{some, V}, [{_, _, Synced}]} when is_integer(V), is_integer(Synced) -> V < Synced;
        _ -> false
    end,
    case Version of
        {some, _} -> ets:insert(?PROGRESS, {{versioned, self()}, true});
        _ -> ok
    end,
    case Stale of
        true -> nil;
        false ->
            put(Uri, ServerId, Term),
            ets:insert(?PROGRESS, {{published, Uri, ServerId, self()}, now_ms()}),
            note_first_publish(Uri, ServerId),
            Key = {provisional, Uri, ServerId, self()},
            case provisional(Version, Term) of
                true ->
                    [{_, Seq, _}] = ets:lookup(?TABLE, {Uri, ServerId, self()}),
                    ets:insert(?PROGRESS, {Key, Seq});
                false -> ets:delete(?PROGRESS, Key)
            end,
            nil
    end.

%% #45: an empty publish without a version, from a server that versions
%% its publishes, is an interim one (jdtls between two checks, clangd on
%% a didClose just before the reopen's real set), not the settled answer.
provisional(none, Term) when is_map(Term) ->
    maps:get(<<"diagnostics">>, Term, undefined) =:= []
        andalso ets:member(?PROGRESS, {versioned, self()});
provisional(_, _) ->
    false.

%% Any proc's entry for (Uri, ServerId): for tests and introspection.
get(Uri0, ServerId) when is_binary(Uri0), is_binary(ServerId) ->
    Uri = key(Uri0),
    case ets:match_object(?TABLE, {{Uri, ServerId, '_'}, '_', '_'}) of
        [{_, _, Term} | _] -> {ok, Term};
        [] -> {error, nil}
    end.

%% Every cached entry for `Uri`, as `{ServerId, Term}`.
get_all_for_uri(Uri0) when is_binary(Uri0) ->
    Uri = key(Uri0),
    Rows = ets:match_object(?TABLE, {{Uri, '_', '_'}, '_', '_'}),
    [{ServerId, Term} || {{_, ServerId, _}, _, Term} <- Rows].

drop(Uri0, ServerId) when is_binary(Uri0), is_binary(ServerId) ->
    Uri = key(Uri0),
    ets:match_delete(?TABLE, {{Uri, ServerId, '_'}, '_', '_'}),
    nil.

%% Forget everything about a URI regardless of server or proc: its
%% entries, its synced stamps and its expectations.
drop_uri(Uri0) when is_binary(Uri0) ->
    Uri = key(Uri0),
    ets:match_delete(?TABLE, {{Uri, '_', '_'}, '_', '_'}),
    ets:match_delete(?SYNCED, {{Uri, '_', '_'}, '_', '_'}),
    ets:match_delete(?EXPECTED, {{Uri, '_', '_'}, '_'}),
    nil.

%% Called by the proc, right after writing a sync.
mark_synced(Uri0, ServerId, Version)
        when is_binary(Uri0), is_binary(ServerId), is_integer(Version) ->
    Uri = key(Uri0),
    true = ets:insert(?SYNCED, {{Uri, ServerId, self()}, seq(), Version}),
    true = ets:insert(?PROGRESS, {{sync, self(), Uri, ServerId}, now_ms()}),
    nil.

%% Called by the proc as it starts writing batch `N`, before any write:
%% the actor reads no frame in between, so every entry cached after
%% this was published after the batch reached the server. The time
%% starts the batch's settle window.
mark_batch(N) when is_integer(N) ->
    true = ets:insert(?SYNCED, {{batch, self()}, seq(), N, now_ms()}),
    nil.

%% reached | pending: has `Pid` started writing batch `N` (or a later
%% one)? The proc writes a whole batch in one handler, so anything sent
%% to it after this reads reached is handled after the batch.
batch_status(Pid, N) when is_integer(N) ->
    case ets:lookup(?SYNCED, {batch, Pid}) of
        [{_, _, M, _}] when M >= N -> reached;
        _ -> pending
    end.

%% Called by the pool when it sends proc `Pid` batch `N`.
expect_batch(Pid, N) when is_integer(N) ->
    true = ets:insert(?EXPECTED, {{batch, Pid}, N}),
    nil.

%% Called by the proc when a sync's write failed.
mark_failed(Uri0, ServerId) when is_binary(Uri0), is_binary(ServerId) ->
    Uri = key(Uri0),
    true = ets:insert(?SYNCED, {{Uri, ServerId, self()}, seq(), failed}),
    nil.

%% Called by the proc after a didClose: the server is back on the disk.
%% Kept as a stamp (not deleted) so a caller still waiting on an earlier
%% sync of the document, which another session's LRU just closed, stops
%% waiting.
mark_closed(Uri0, ServerId) when is_binary(Uri0), is_binary(ServerId) ->
    Uri = key(Uri0),
    true = ets:insert(?SYNCED, {{Uri, ServerId, self()}, seq(), closed}),
    %% #45: a reopen records its own open.
    ets:delete(?PROGRESS, {opened, Uri, ServerId, self()}),
    nil.

%% reached | pending | failed: has `Pid` written the document's sync at
%% `Version` (or later), or closed it since?
stamp_status(Uri0, ServerId, Version, Pid)
        when is_binary(Uri0), is_binary(ServerId), is_integer(Version) ->
    Uri = key(Uri0),
    case ets:lookup(?SYNCED, {Uri, ServerId, Pid}) of
        [{_, _, failed}] -> failed;
        [{_, _, closed}] -> reached;
        [{_, _, V}] when V >= Version -> reached;
        _ -> pending
    end.

%% reached | pending | failed: has `Pid` written the close of a document
%% last synced at `Version`, or reopened it since (at a later version,
%% which it writes after the close)?
close_status(Uri0, ServerId, Version, Pid)
        when is_binary(Uri0), is_binary(ServerId), is_integer(Version) ->
    Uri = key(Uri0),
    case ets:lookup(?SYNCED, {Uri, ServerId, Pid}) of
        [{_, _, failed}] -> failed;
        [{_, _, closed}] -> reached;
        [{_, _, V}] when is_integer(V), V > Version -> reached;
        _ -> pending
    end.

%% Called by the pool when it records a sync (before the proc writes it).
expect(Uri0, ServerId, Version, Pid)
        when is_binary(Uri0), is_binary(ServerId), is_integer(Version) ->
    Uri = key(Uri0),
    true = ets:insert(?EXPECTED, {{Uri, ServerId, Pid}, Version}),
    nil.

%% Called by the pool when it records a close (before the proc writes it).
expect_closed(Uri0, ServerId, Pid) when is_binary(Uri0), is_binary(ServerId) ->
    Uri = key(Uri0),
    true = ets:insert(?EXPECTED, {{Uri, ServerId, Pid}, closed}),
    nil.

%% A proc is gone: drop every row it owned.
%% #30. Called by the proc for each `$/progress` it reads after readiness
%% (`Kind` is begin, report or end). A begin is stamped with the same
%% sequence as syncs and publishes, so "began after this document's sync"
%% is a comparison.
progress(Token, Kind) when is_binary(Token), is_binary(Kind) ->
    Self = self(),
    case Kind of
        <<"begin">> ->
            true = ets:insert(?PROGRESS, {{Self, Token}, seq(), now_ms()});
        <<"end">> ->
            ets:delete(?PROGRESS, {Self, Token}),
            ets:insert(?PROGRESS, {{progress_end, Self}, now_ms()});
        _ ->
            ok
    end,
    nil.

%% #30. False while the server is still working on what this document's
%% latest sync changed, so an answer now could carry results from before
%% it (rust-analyzer republishes cargo check's old ones at the new
%% version until the check it reruns on save ends). That is, either:
%% - a progress that began after the sync is still running, and hasn't
%%   run longer than `StuckMs` (one that never ends doesn't hold every
%%   call);
%% - the sync is younger than `GraceMs`, the server's save_check_grace_ms
%%   (a check's begin can land just after the sync); 0 for a server that
%%   doesn't start a check on save.
%% True otherwise, and always for a document with no sync stamp.
progress_quiet(Uri0, ServerId, Pid, GraceMs, StuckMs)
        when is_binary(Uri0), is_binary(ServerId), is_integer(GraceMs), is_integer(StuckMs) ->
    Uri = key(Uri0),
    case ets:lookup(?SYNCED, {Uri, ServerId, Pid}) of
        [{_, SyncSeq, _}] when is_integer(SyncSeq) ->
            Now = now_ms(),
            Running = [T || {{_, T}, BeginSeq, BeginMs}
                                <- ets:match_object(?PROGRESS, {{Pid, '_'}, '_', '_'}),
                            BeginSeq > SyncSeq, Now - BeginMs < StuckMs],
            InGrace = GraceMs > 0 andalso
                case ets:lookup(?PROGRESS, {sync, Pid, Uri, ServerId}) of
                    [{_, SyncMs}] -> Now - SyncMs < GraceMs;
                    _ -> false
                end,
            Running =:= [] andalso not InGrace;
        _ ->
            true
    end.

%% #27. True while proc `Pid`'s server has a progress running (indexing,
%% loading packages) that began less than `StuckMs` ago.
progress_active(Pid, StuckMs) when is_integer(StuckMs) ->
    Now = now_ms(),
    lists:any(fun({_, _, BeginMs}) -> Now - BeginMs < StuckMs end,
              ets:match_object(?PROGRESS, {{Pid, '_'}, '_', '_'})).

forget_proc(Pid) ->
    ets:match_delete(?TABLE, {{'_', '_', Pid}, '_', '_'}),
    ets:match_delete(?SYNCED, {{'_', '_', Pid}, '_', '_'}),
    ets:match_delete(?EXPECTED, {{'_', '_', Pid}, '_'}),
    ets:delete(?SYNCED, {batch, Pid}),
    ets:delete(?EXPECTED, {batch, Pid}),
    ets:match_delete(?PROGRESS, {{Pid, '_'}, '_', '_'}),
    ets:match_delete(?PROGRESS, {{sync, Pid, '_', '_'}, '_'}),
    ets:match_delete(?PROGRESS, {{provisional, '_', '_', Pid}, '_'}),
    ets:match_delete(?PROGRESS, {{published, '_', '_', Pid}, '_'}),
    ets:match_delete(?PROGRESS, {{opened, '_', '_', Pid}, '_'}),
    ets:match_delete(?PROGRESS, {{first_pub, '_', '_', Pid}, '_'}),
    ets:delete(?PROGRESS, {versioned, Pid}),
    ets:delete(?PROGRESS, {first_open, Pid}),
    ets:delete(?PROGRESS, {progress_end, Pid}),
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
lookup(Uri0, ServerId, Pid, SettleMs)
        when is_binary(Uri0), is_binary(ServerId), is_integer(SettleMs) ->
    Uri = key(Uri0),
    Key = {Uri, ServerId, Pid},
    case ets:lookup(?TABLE, Key) of
        [] -> missing;
        [{_, Seq, Term}] ->
            case doc_state(Key, Seq) of
                gone -> missing;
                Doc ->
                    Fresh = Doc =:= fresh
                        andalso batch_settled(Seq, Pid, SettleMs)
                        andalso not provisional_pending(Key, Seq, Pid, SettleMs),
                    case Fresh of
                        true -> {fresh, Term};
                        false -> {carried_over, Term}
                    end
            end
    end.

%% #45: the entry at `Seq` is an interim empty publish, and the last
%% batch's settle window is still running: the server's settled set may
%% still come. Past the window it is taken as the answer.
provisional_pending({Uri, ServerId, Pid}, Seq, Pid, SettleMs) ->
    case ets:lookup(?PROGRESS, {provisional, Uri, ServerId, Pid}) of
        [{_, Seq}] ->
            case ets:lookup(?SYNCED, {batch, Pid}) of
                [{_, _, _, At}] -> now_ms() < At + SettleMs;
                [] -> false
            end;
        _ -> false
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

%% The URI part of every key: one spelling of a `file://` URI, however the
%% server that published it or the client that asks escaped it (#16).
%% Servers differ (vscode-uri escapes `@` and `+`, Rust's `url` doesn't),
%% so the publish's own string can't be the key.
key(Uri) -> 'pharos@workspace_root':canonical_uri(Uri).

%% #38. How long ago the latest sync of `Uri0` was written to proc `Pid`'s
%% server, in ms; -1 if pharos never synced it there.
sync_age_ms(Uri0, ServerId, Pid) when is_binary(Uri0), is_binary(ServerId) ->
    case ets:lookup(?PROGRESS, {sync, Pid, key(Uri0), ServerId}) of
        [{_, Ms}] -> now_ms() - Ms;
        [] -> -1
    end.

%% #45. How long ago proc `Pid` cached its latest publish about `Uri0`,
%% in ms; -1 if it never has.
publish_age_ms(Uri0, ServerId, Pid) when is_binary(Uri0), is_binary(ServerId) ->
    case ets:lookup(?PROGRESS, {published, key(Uri0), ServerId, Pid}) of
        [{_, Ms}] -> now_ms() - Ms;
        [] -> -1
    end.

%% #45. Called by the proc after it writes a didOpen at `Version`.
mark_opened(Uri0, ServerId, Version) when is_binary(Uri0), is_binary(ServerId) ->
    true = ets:insert(?PROGRESS, {{opened, key(Uri0), ServerId, self()}, Version}),
    %% #44: the session's first didOpen, which starts the cold grace.
    ets:insert_new(?PROGRESS, {{first_open, self()}, now_ms()}),
    nil.

%% #44. ms since proc `Pid` wrote its first didOpen; -1 if it hasn't.
first_open_age_ms(Pid) ->
    case ets:lookup(?PROGRESS, {first_open, Pid}) of
        [{_, Ms}] -> now_ms() - Ms;
        [] -> -1
    end.

%% #44. Did a progress of proc `Pid` end less than `Ms` ago? HLS leaves
%% about 1 s between its Indexing tokens, and lua-ls's results land just
%% after its progress ends.
progress_ended_within(Pid, Ms) when is_integer(Ms) ->
    case ets:lookup(?PROGRESS, {progress_end, Pid}) of
        [{_, At}] -> now_ms() - At < Ms;
        [] -> false
    end.

%% #45. Was the latest sync of `Uri0` written to proc `Pid` its didOpen?
last_sync_was_open(Uri0, ServerId, Pid) when is_binary(Uri0), is_binary(ServerId) ->
    Uri = key(Uri0),
    case {ets:lookup(?PROGRESS, {opened, Uri, ServerId, Pid}),
          ets:lookup(?SYNCED, {Uri, ServerId, Pid})} of
        {[{_, V}], [{_, _, V}]} -> true;
        _ -> false
    end.

%% #45. The latest sync's seq on the calling (or a given) proc; 0 if none.
sync_seq(Uri, ServerId, Pid) ->
    case ets:lookup(?SYNCED, {Uri, ServerId, Pid}) of
        [{_, S, _}] -> S;
        [] -> 0
    end.

%% #45. Records the first publish after the latest sync, and when.
note_first_publish(Uri, ServerId) ->
    Key = {first_pub, Uri, ServerId, self()},
    SyncSeq = sync_seq(Uri, ServerId, self()),
    case ets:lookup(?PROGRESS, Key) of
        [{_, {Seq, _}}] when Seq > SyncSeq -> ok;
        _ -> ets:insert(?PROGRESS, {Key, {seq(), now_ms()}})
    end.

%% #45. ms since the first publish after the latest sync of `Uri0` on proc
%% `Pid`; -1 if none has come since that sync.
first_publish_age_ms(Uri0, ServerId, Pid) when is_binary(Uri0), is_binary(ServerId) ->
    Uri = key(Uri0),
    SyncSeq = sync_seq(Uri, ServerId, Pid),
    case ets:lookup(?PROGRESS, {first_pub, Uri, ServerId, Pid}) of
        [{_, {Seq, Ms}}] when Seq > SyncSeq -> now_ms() - Ms;
        _ -> -1
    end.
