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
-export([init/0, mark_done/2, is_done/2, try_claim/2]).

-define(TABLE, pharos_post_didopen_drained).

init() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]);
        _ ->
            ?TABLE
    end,
    nil.

%% Atomic test-and-set so only ONE worker per {ServerId, Workspace}
%% drives the actual drain. Returns `true` to the worker that claimed
%% (it should run `proc.wait_for_ready` and then call `mark_done/2`);
%% returns `false` to every subsequent worker (they skip the drain and
%% fall through to the existing retry-on-content-modified path).
%%
%% Why first-claim-wins: `proc.wait_for_ready` is `actor.call` with a
%% 35s timeout. Two concurrent workers both calling it would queue
%% behind each other in the proc actor's mailbox; the second worker's
%% caller-side deadline expires while waiting for the first worker's
%% 30s drain to complete, the worker crashes silently (spawn_unlinked),
%% and the inflight counter leaks. With first-claim-wins, only one
%% worker per pair pays the wait_for_ready cost.
try_claim(ServerId, Workspace) when is_binary(ServerId), is_binary(Workspace) ->
    ets:insert_new(?TABLE, {{ServerId, Workspace, claim}, true}).

%% Called by the claiming worker after `proc.wait_for_ready` returned
%% Ok. Subsequent `is_done/2` checks return true so workers do not
%% bother claiming again.
mark_done(ServerId, Workspace) when is_binary(ServerId), is_binary(Workspace) ->
    true = ets:insert(?TABLE, {{ServerId, Workspace, done}, true}),
    nil.

is_done(ServerId, Workspace) when is_binary(ServerId), is_binary(Workspace) ->
    case ets:lookup(?TABLE, {ServerId, Workspace, done}) of
        [_] -> true;
        [] -> false
    end.
