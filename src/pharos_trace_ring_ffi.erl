%% Always-on dedicated ring buffer for LSP wire-trace events.
%%
%% Sibling of `pharos_log_ffi` (the main log ring) but reserved for
%% `pharos/lsp/trace` events. The split exists so that `runtime_trace_lsp`
%% can read wire events that fired BEFORE the tool toggled the trace
%% filter — the M11 race where parallel-issued runtime_trace_lsp + a
%% producer (e.g. concurrent hover) miss the producer's first emit
%% because the persistent_term cache update has not yet reached the
%% producer's worker process. With an always-on ring, the producer
%% always writes; the consumer (`runtime_trace_lsp`) just reads.
%%
%% Capacity is small (default 100) so the per-emit ETS write cost is
%% bounded and memory stays predictable even under heavy LSP traffic.
%% Compare with the 1000-entry general log ring backing
%% `runtime_log_tail`.
%%
%% Same lifecycle pattern as the log ring: ordered_set keyed by a
%% monotonic counter, evict-on-overflow, single-row meta table for
%% next-index and capacity. Owner: pharos:boot/0.

-module(pharos_trace_ring_ffi).
-export([init/1, insert/2, tail/2, clear/0, size/0]).

-define(TABLE, pharos_trace_ring).
-define(META_TABLE, pharos_trace_ring_meta).

init(Cap) when is_integer(Cap), Cap > 0 ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, ordered_set]),
            ets:new(?META_TABLE, [named_table, public, set]),
            ets:insert(?META_TABLE, {next, 0}),
            ets:insert(?META_TABLE, {cap, Cap});
        _ ->
            ok
    end,
    nil.

insert(Line, Level) when is_binary(Line), is_atom(Level) ->
    case ets:info(?TABLE) of
        undefined -> nil;
        _ ->
            Idx = ets:update_counter(?META_TABLE, next, 1),
            ets:insert(?TABLE, {Idx, Level, Line}),
            [{cap, Cap}] = ets:lookup(?META_TABLE, cap),
            evict_until(Cap),
            nil
    end.

evict_until(Cap) ->
    case ets:info(?TABLE, size) of
        Size when Size > Cap ->
            case ets:first(?TABLE) of
                '$end_of_table' -> ok;
                Oldest ->
                    ets:delete(?TABLE, Oldest),
                    evict_until(Cap)
            end;
        _ -> ok
    end.

tail(N, FilterSubstr) when is_integer(N) ->
    case ets:info(?TABLE) of
        undefined -> [];
        _ ->
            Keys = collect_recent_keys(ets:last(?TABLE), N, []),
            Entries = [ets:lookup(?TABLE, K) || K <- Keys],
            Flat = lists:append(Entries),
            Filtered = case FilterSubstr of
                <<>> -> Flat;
                Sub -> [E || E = {_, _, Line} <- Flat,
                             binary:match(Line, Sub) =/= nomatch]
            end,
            [{Level, Line} || {_Idx, Level, Line} <- Filtered]
    end.

collect_recent_keys('$end_of_table', _, Acc) -> Acc;
collect_recent_keys(_, 0, Acc) -> Acc;
collect_recent_keys(Key, N, Acc) ->
    Prev = ets:prev(?TABLE, Key),
    collect_recent_keys(Prev, N - 1, [Key | Acc]).

clear() ->
    case ets:info(?TABLE) of
        undefined -> nil;
        _ ->
            ets:delete_all_objects(?TABLE),
            ets:insert(?META_TABLE, {next, 0}),
            nil
    end.

size() ->
    case ets:info(?TABLE, size) of
        undefined -> 0;
        N -> N
    end.
