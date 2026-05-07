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
%% Key shape: `{Uri, ServerId}`. Multi-LSP languages (e.g. python =
%% pyright + ruff) emit independently for the same URI; without a
%% per-server key the second emission overwrites the first and the
%% merge path loses one server's items entirely. `get_all_for_uri/1`
%% returns every cached `{ServerId, Params}` tuple for one URI so the
%% merge path can stitch them together.
%%
%% Owner: whichever process calls init/0 first. ETS tables outlive
%% the owner only if they were created with `heir` set; we do not,
%% so the table dies if the owner process dies. The supervisor root
%% is the owner; for now any of the application's primary callers
%% (pharos:main / app callback) is fine — they live for the whole
%% BEAM uptime.

-module(pharos_diagnostics_cache_ffi).
-export([init/0, put/3, get/2, get_all_for_uri/1, drop/2, drop_uri/1]).

-define(TABLE, pharos_diagnostics_cache).

init() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]);
        _ ->
            ?TABLE
    end,
    nil.

put(Uri, ServerId, Term) when is_binary(Uri), is_binary(ServerId) ->
    true = ets:insert(?TABLE, {{Uri, ServerId}, Term}),
    nil.

get(Uri, ServerId) when is_binary(Uri), is_binary(ServerId) ->
    case ets:lookup(?TABLE, {Uri, ServerId}) of
        [{_, Term}] -> {ok, Term};
        [] -> {error, nil}
    end.

%% Match every cached entry whose key starts with `Uri`. Returns a
%% list of `{ServerId, Term}` tuples; empty when no entries exist.
get_all_for_uri(Uri) when is_binary(Uri) ->
    %% match_object returns rows shaped {{Uri, ServerId}, Term};
    %% reshape to {ServerId, Term} for the Gleam side.
    Rows = ets:match_object(?TABLE, {{Uri, '_'}, '_'}),
    [{ServerId, Term} || {{_, ServerId}, Term} <- Rows].

drop(Uri, ServerId) when is_binary(Uri), is_binary(ServerId) ->
    ets:delete(?TABLE, {Uri, ServerId}),
    nil.

%% Drop every cached entry for a URI regardless of server_id. Called
%% when callers know the file content has changed and any cached
%% entry would mislead.
drop_uri(Uri) when is_binary(Uri) ->
    ets:match_delete(?TABLE, {{Uri, '_'}, '_'}),
    nil.
