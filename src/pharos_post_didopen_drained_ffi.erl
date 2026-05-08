%% Track which {ServerId, Workspace} pairs have already completed the
%% post-didOpen indexing drain (the post-handshake `wait_for_ready/3`
%% that lives in `pharos/lsp/lifecycle` runs before any didOpen, but
%% rust-analyzer's indexing burst only kicks in AFTER the first
%% `textDocument/didOpen`. Without a second drain at that point the
%% first hover/goto against a freshly-spawned analyzer races against
%% indexing and returns `null` or `-32801 content modified`.)
%%
%% Drain happens once per {ServerId, Workspace}: subsequent didOpens
%% for additional files in the same workspace see indexing already
%% settled and do not need to re-drain.
%%
%% Sibling of `pharos_diagnostics_cache_ffi`. Same lifecycle (idempotent
%% init, public ETS table named after the module without the _ffi
%% suffix, dies with the owner process — `pharos:boot/0` is the owner
%% and lives for BEAM uptime).

-module(pharos_post_didopen_drained_ffi).
-export([init/0, mark/2, is_marked/2]).

-define(TABLE, pharos_post_didopen_drained).

init() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]);
        _ ->
            ?TABLE
    end,
    nil.

mark(ServerId, Workspace) when is_binary(ServerId), is_binary(Workspace) ->
    true = ets:insert(?TABLE, {{ServerId, Workspace}, true}),
    nil.

is_marked(ServerId, Workspace) when is_binary(ServerId), is_binary(Workspace) ->
    case ets:lookup(?TABLE, {ServerId, Workspace}) of
        [_] -> true;
        [] -> false
    end.
