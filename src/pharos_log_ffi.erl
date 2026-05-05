%% Erlang FFI for the structured logger.
%%
%% Three small helpers grouped here:
%%
%%   * Ring buffer — an ETS table holding the last N log entries.
%%     `runtime_log_tail` (M9.5 Part C) reads the buffer; the writer
%%     actor (`pharos/log/writer`) is the only producer.
%%   * Correlation-id storage — a per-process value stashed in the
%%     process dictionary. MCP-request entry points set it before
%%     dispatching tool work; every `log.*` call on the same process
%%     reads it back to stamp `cid=<id>` on the line. Using the
%%     process dict avoids threading the id through 30+ tool
%%     signatures (ADR follow-up captures the trade-off).
%%   * ISO-8601 millisecond timestamp, formatted once per entry.
%%
%% Stdout is reserved for MCP. Every write here either goes to ETS,
%% the process dictionary, or — via the writer — stderr. Anything
%% else is a bug.

-module(pharos_log_ffi).
-export([
    ring_init/1,
    ring_insert/2,
    ring_tail/2,
    ring_clear/0,
    ring_size/0,
    cid_set/1,
    cid_clear/0,
    cid_get/0,
    iso_timestamp_ms/0,
    pid_to_text/1,
    self_pid_text/0,
    writer_register_subject/1,
    writer_subject/0,
    mailbox_len/1,
    direct_stderr/1,
    render_trace_body/1
]).

-define(RING_TABLE, pharos_log_ring).
-define(RING_META_TABLE, pharos_log_ring_meta).
-define(CID_KEY, pharos_log_cid).

%% Initialise the ring with a maximum of `Cap` entries. Idempotent —
%% calling more than once leaves the existing table untouched.
%%
%% Two ETS tables back the ring:
%%
%%   * pharos_log_ring — ordered_set keyed by a monotonic counter so
%%     `ets:select_reverse` returns most-recent entries first.
%%   * pharos_log_ring_meta — single-row counter for next-slot index
%%     and the configured capacity.
ring_init(Cap) ->
    case ets:info(?RING_TABLE) of
        undefined ->
            ets:new(?RING_TABLE, [named_table, public, ordered_set]),
            ets:new(?RING_META_TABLE, [named_table, public, set]),
            ets:insert(?RING_META_TABLE, {next, 0}),
            ets:insert(?RING_META_TABLE, {cap, Cap});
        _ ->
            ok
    end,
    nil.

%% Insert one already-formatted log line. Drops the oldest entry
%% when the ring is at capacity. Caller is the writer actor; this
%% module does no formatting.
ring_insert(Line, Level) when is_binary(Line), is_atom(Level) ->
    case ets:info(?RING_TABLE) of
        undefined -> nil;
        _ ->
            Idx = ets:update_counter(?RING_META_TABLE, next, 1),
            ets:insert(?RING_TABLE, {Idx, Level, Line}),
            [{cap, Cap}] = ets:lookup(?RING_META_TABLE, cap),
            evict_until(Cap),
            nil
    end.

evict_until(Cap) ->
    case ets:info(?RING_TABLE, size) of
        Size when Size > Cap ->
            case ets:first(?RING_TABLE) of
                '$end_of_table' -> ok;
                Oldest ->
                    ets:delete(?RING_TABLE, Oldest),
                    evict_until(Cap)
            end;
        _ -> ok
    end.

%% Read the last `N` entries, newest first. Returns a list of
%% `{level_atom, line_binary}` tuples; Gleam side rewraps as records
%% (Part C will).
ring_tail(N, FilterSubstr) when is_integer(N) ->
    case ets:info(?RING_TABLE) of
        undefined -> [];
        _ ->
            Keys = collect_recent_keys(ets:last(?RING_TABLE), N, []),
            Entries = [ets:lookup(?RING_TABLE, K) || K <- Keys],
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
    Prev = ets:prev(?RING_TABLE, Key),
    collect_recent_keys(Prev, N - 1, [Key | Acc]).

ring_clear() ->
    case ets:info(?RING_TABLE) of
        undefined -> nil;
        _ ->
            ets:delete_all_objects(?RING_TABLE),
            ets:insert(?RING_META_TABLE, {next, 0}),
            nil
    end.

ring_size() ->
    case ets:info(?RING_TABLE, size) of
        undefined -> 0;
        N -> N
    end.

%% Per-process correlation id. Stored in the process dictionary so
%% any log call on the same process picks it up without an explicit
%% argument. Cross-actor propagation is not automatic — the request
%% handler in `pharos/lsp/proc` re-sets the id before dispatching.
cid_set(Id) when is_binary(Id) ->
    erlang:put(?CID_KEY, Id),
    nil.

cid_clear() ->
    erlang:erase(?CID_KEY),
    nil.

%% Returns `{ok, Id}` when set; `{error, nil}` when cleared/never set.
%% The Gleam side maps to `Result(String, Nil)`.
cid_get() ->
    case erlang:get(?CID_KEY) of
        undefined -> {error, nil};
        Id when is_binary(Id) -> {ok, Id};
        _ -> {error, nil}
    end.

%% ISO-8601 with millisecond precision, UTC. Example:
%% `<<"2026-05-05T12:44:39.785Z">>`.
iso_timestamp_ms() ->
    Now = erlang:system_time(millisecond),
    Secs = Now div 1000,
    Ms = Now rem 1000,
    {{Y, Mo, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(Secs, second),
    list_to_binary(
        io_lib:format(
            "~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B.~3..0BZ",
            [Y, Mo, D, H, Mi, S, Ms]
        )
    ).

%% Render a pid as its standard text form (`<<"<0.143.0>">>`). Used
%% in log fields when an entry references another process.
pid_to_text(Pid) when is_pid(Pid) ->
    list_to_binary(pid_to_list(Pid)).

self_pid_text() ->
    pid_to_text(self()).

%% Writer subject is held in `persistent_term` so any process can
%% look it up at producer cost ~50ns without touching ETS or hopping
%% through the process registry. Subjects are records (tuple terms)
%% and persistent_term tolerates arbitrary terms — storing the whole
%% Subject keeps Gleam's typed `process.send` path intact.
writer_register_subject(Subject) ->
    persistent_term:put(pharos_log_writer_subject, Subject),
    nil.

writer_subject() ->
    try
        Subject = persistent_term:get(pharos_log_writer_subject),
        {ok, Subject}
    catch
        error:badarg -> {error, nil}
    end.

%% Producer-side overflow guard. Before sending an Emit cast the
%% caller checks mailbox depth; if it exceeds the cap the line is
%% dropped instead of growing the writer's mailbox unbounded. Pid
%% may be a raw pid or a registered name.
mailbox_len(Pid) when is_pid(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, N} -> N;
        undefined -> -1
    end.

%% Last-ditch fallback when the writer is not registered yet (early
%% boot) or has died: write directly to stderr. Single io:format call
%% per line so partial writes do not interleave with concurrent
%% callers in the kernel pipe buffer.
direct_stderr(Line) when is_binary(Line) ->
    io:format(standard_error, "~ts~n", [Line]),
    nil.

%% Convert raw LSP wire bytes into a single-line printable string
%% suitable for a `body=...` log field. Control characters and
%% non-ASCII bytes become escapes (`\\r`, `\\n`, `\\t`, `\\xNN`)
%% so the entry stays on one line and the JSON envelope reads
%% cleanly. Caller has already truncated to a safe length.
render_trace_body(Bytes) when is_binary(Bytes) ->
    << <<(escape_trace_byte(B))/binary>> || <<B>> <= Bytes >>.

escape_trace_byte($\r) -> <<"\\r">>;
escape_trace_byte($\n) -> <<"\\n">>;
escape_trace_byte($\t) -> <<"\\t">>;
escape_trace_byte($\\) -> <<"\\\\">>;
escape_trace_byte(B) when B < 32 ->
    list_to_binary(io_lib:format("\\x~2.16.0b", [B]));
escape_trace_byte(B) when B > 126 ->
    list_to_binary(io_lib:format("\\x~2.16.0b", [B]));
escape_trace_byte(B) -> <<B>>.
