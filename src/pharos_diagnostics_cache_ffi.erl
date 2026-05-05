%% ETS-backed diagnostics cache.
%%
%% LSP servers emit `textDocument/publishDiagnostics` once per file
%% per didOpen and on file/version changes. Pharos's pool is
%% didOpen-once (to avoid rust-analyzer's content-modified
%% cancellations), so subsequent get_diagnostics calls miss the
%% notification and time out.
%%
%% This module owns a public ETS table that any process can write
%% to and read from. The lifecycle classifier writes whenever it
%% sees a publishDiagnostics notification; the get_diagnostics tool
%% reads first and only falls back to the wait loop on miss.
%%
%% Owner: whichever process calls init/0 first. ETS tables outlive
%% the owner only if they were created with `heir` set; we do not,
%% so the table dies if the owner process dies. In M9 the supervisor
%% root will be the owner; for now any of the application's primary
%% callers (pharos:main / app callback) is fine — they live for the
%% whole BEAM uptime.

-module(pharos_diagnostics_cache_ffi).
-export([init/0, put/2, get/1, drop/1]).

-define(TABLE, pharos_diagnostics_cache).

init() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]);
        _ ->
            ?TABLE
    end,
    nil.

put(Uri, Term) ->
    true = ets:insert(?TABLE, {Uri, Term}),
    nil.

get(Uri) ->
    case ets:lookup(?TABLE, Uri) of
        [{Uri, Term}] -> {ok, Term};
        [] -> {error, nil}
    end.

drop(Uri) ->
    ets:delete(?TABLE, Uri),
    nil.
