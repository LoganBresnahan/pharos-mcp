%% Unix-socket plumbing for the shared daemon (ADR-034).
%%
%% Gleam has no binding for gen_tcp's `{local, Path}` addresses, the
%% active-once socket messages, or the pid-file bookkeeping the shim
%% relies on, hence the shim. Framing (newline-delimited JSON-RPC) is
%% done here too: gen_tcp's `{packet, line}` truncates lines longer
%% than the receive buffer, and MCP lines carry whole files.

-module(pharos_daemon_ffi).
-include_lib("kernel/include/file.hrl").
-export([listen/1, accept/1, hand_over/2, activate/1, send_line/2,
         close/1, split_lines/2, decode_socket_event/1,
         write_pid_file/1, register_cleanup/2, cleanup/0, os_pid/0,
         now_ms/0, sessions_init/0, session_register/2,
         session_unregister/1, sessions_live/0, sessions_touch/0,
         sessions_last_active/0, sessions_started/0,
         transient_accept_error/1, test_ops_enabled/0,
         register_daemon_actor/0, kill_daemon_actor/0]).

-define(CLEANUP_KEY, pharos_daemon_cleanup).

%% Session registry (ADR-034). A named public ETS table created at
%% boot, so it is owned by the application's start process and
%% outlives the daemon actor: a supervisor restart of the daemon must
%% not forget the sessions whose connections are still serving.
%% Connections write their own rows; the daemon only reads, prunes
%% rows whose connection process died, and idle-exits on an empty
%% table.
%%
%%   {Id, Cwd, ClientPid, SinceMs, ConnPid}   one per session
%%   {'$next_id', N}                          session id counter
%%   {'$last_active', Ms}                     last time a session was live
-define(SESSIONS, pharos_daemon_sessions).

%% Listen on `Path`. A socket file already there is either a live
%% daemon (connect succeeds: refuse, so two daemons never share a
%% key) or a stale one (connect refused: remove it and bind).
listen(Path) when is_binary(Path) ->
    P = binary_to_list(Path),
    _ = filelib:ensure_dir(P),
    %% Not filelib:is_file/1: it is false for a socket, which is neither
    %% a regular file nor a directory.
    case file:read_link_info(P) of
        {ok, _} ->
            case gen_tcp:connect({local, P}, 0, [binary, {active, false}],
                                 1000) of
                {ok, S} ->
                    gen_tcp:close(S),
                    {error, <<"another daemon is listening on this socket">>};
                {error, _} ->
                    _ = file:delete(P),
                    bind(P)
            end;
        {error, _} ->
            bind(P)
    end.

bind(P) ->
    case gen_tcp:listen(0, [binary, {ifaddr, {local, P}}, {active, false},
                            {packet, raw}, {backlog, 128}]) of
        {ok, L} ->
            _ = file:change_mode(P, 8#600),
            {ok, L};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Block until a client connects. `exit_on_close` is off so a shim
%% that half-closes (stdin EOF) still receives the responses still in
%% flight for it.
accept(L) ->
    case gen_tcp:accept(L) of
        {ok, S} ->
            _ = inet:setopts(S, [{exit_on_close, false}]),
            {ok, S};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

hand_over(S, Pid) ->
    _ = gen_tcp:controlling_process(S, Pid),
    nil.

activate(S) ->
    _ = inet:setopts(S, [{active, once}]),
    nil.

send_line(S, Body) ->
    case gen_tcp:send(S, [Body, $\n]) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.

close(S) ->
    _ = gen_tcp:close(S),
    nil.

%% Cut every complete line out of `Data`, given the chunks of an
%% unterminated line still pending from earlier reads (`Pending`, newest
%% first, `{Chunks, Bytes}`). Returns `{Lines, Pending'}`. Only the new
%% chunk is scanned, and pending chunks are joined once, when their line
%% ends, so a large line arriving in small reads costs O(n), not O(n²).
%% A trailing `\r` is dropped so CRLF clients work.
split_lines({Chunks, Bytes}, Data) ->
    case binary:split(Data, <<"\n">>, [global]) of
        [_NoNewline] ->
            {[], {[Data | Chunks], Bytes + byte_size(Data)}};
        [First | Rest] ->
            Head = iolist_to_binary(lists:reverse([First | Chunks])),
            {Complete, [Tail]} = lists:split(length(Rest) - 1, Rest),
            Lines = [strip_cr(L) || L <- [Head | Complete]],
            case Tail of
                <<>> -> {Lines, {[], 0}};
                _ -> {Lines, {[Tail], byte_size(Tail)}}
            end
    end.

strip_cr(L) ->
    case byte_size(L) of
        0 -> L;
        N ->
            case binary:at(L, N - 1) of
                $\r -> binary:part(L, 0, N - 1);
                _ -> L
            end
    end.

%% Project an active-once socket message into the Gleam
%% `SocketEvent` shape: `{socket_data, Bin}`, `socket_closed`, or
%% `socket_other`.
decode_socket_event({tcp, _S, Data}) when is_binary(Data) -> {socket_data, Data};
decode_socket_event({tcp_closed, _S}) -> socket_closed;
decode_socket_event({tcp_error, _S, _}) -> socket_closed;
decode_socket_event(_) -> socket_other.

%% Write this OS pid to `Path` (beside the socket). The shim reads it
%% to tell a live but slow daemon from a stale socket.
write_pid_file(Path) ->
    _ = file:write_file(Path, [os:getpid(), $\n]),
    _ = file:change_mode(Path, 8#600),
    nil.

%% Remember what `cleanup/0` removes when the application stops.
register_cleanup(SocketPath, PidPath) ->
    persistent_term:put(?CLEANUP_KEY, {SocketPath, PidPath}),
    nil.

%% Remove the socket and the pid file, but only while the pid file
%% still names this process: a newer daemon may already own the key.
cleanup() ->
    try persistent_term:get(?CLEANUP_KEY) of
        {SocketPath, PidPath} ->
            Mine = list_to_binary([os:getpid(), $\n]),
            case file:read_file(PidPath) of
                {ok, Mine} ->
                    _ = file:delete(SocketPath),
                    _ = file:delete(PidPath);
                _ ->
                    ok
            end,
            nil
    catch
        error:badarg -> nil
    end.

os_pid() ->
    list_to_integer(os:getpid()).

%% Accept errors worth retrying rather than tearing the listener down:
%% fd exhaustion (LSPs hold many) and a client that gave up mid-accept.
transient_accept_error(Reason) ->
    lists:member(Reason, [<<"emfile">>, <<"enfile">>, <<"econnaborted">>,
                          <<"eagain">>, <<"eintr">>, <<"enobufs">>,
                          <<"enomem">>]).

sessions_init() ->
    case ets:info(?SESSIONS) of
        undefined ->
            ets:new(?SESSIONS, [named_table, public, set,
                                {write_concurrency, true}]),
            ets:insert(?SESSIONS, [{'$next_id', 0},
                                   {'$last_active', now_ms()},
                                   {'$started', now_ms()}]);
        _ -> ok
    end,
    nil.

%% Register the calling connection process as a session; returns its
%% id (`s1`, `s2`, ...).
session_register(Cwd, ClientPid) ->
    N = ets:update_counter(?SESSIONS, '$next_id', 1),
    Id = <<"s", (integer_to_binary(N))/binary>>,
    ets:insert(?SESSIONS, {Id, Cwd, ClientPid, now_ms(), self()}),
    sessions_touch(),
    Id.

session_unregister(Id) ->
    ets:delete(?SESSIONS, Id),
    sessions_touch(),
    nil.

%% Live sessions as `{Id, Cwd, ClientPid, SinceMs}`, sorted by id.
%% Rows whose connection process is gone (it crashed before it could
%% unregister) are deleted on the way.
sessions_live() ->
    Rows = ets:select(?SESSIONS, [{{'$1', '$2', '$3', '$4', '$5'}, [], ['$_']}]),
    Live = lists:filter(
        fun({Id, _, _, _, Conn}) ->
            case is_process_alive(Conn) of
                true -> true;
                false -> ets:delete(?SESSIONS, Id), false
            end
        end, Rows),
    lists:sort([{Id, Cwd, Client, Since} || {Id, Cwd, Client, Since, _} <- Live]).

sessions_touch() ->
    ets:insert(?SESSIONS, {'$last_active', now_ms()}),
    nil.

sessions_started() ->
    case ets:lookup(?SESSIONS, '$started') of
        [{_, Ms}] -> Ms;
        [] -> now_ms()
    end.

%% Test-only hello ops (`test_crash_daemon`) are honoured only when the
%% daemon was started with PHAROS_DAEMON_TEST_OPS=1.
test_ops_enabled() ->
    os:getenv("PHAROS_DAEMON_TEST_OPS") =:= "1".

%% The daemon actor registers a local name so the test op can find it.
%% A restarted actor re-registers.
register_daemon_actor() ->
    catch unregister(pharos_daemon),
    true = register(pharos_daemon, self()),
    nil.

kill_daemon_actor() ->
    case whereis(pharos_daemon) of
        undefined -> nil;
        Pid -> exit(Pid, kill), nil
    end.

sessions_last_active() ->
    case ets:lookup(?SESSIONS, '$last_active') of
        [{_, Ms}] -> Ms;
        [] -> now_ms()
    end.

now_ms() ->
    erlang:system_time(millisecond).
