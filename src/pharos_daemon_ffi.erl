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
         now_ms/0]).

-define(CLEANUP_KEY, pharos_daemon_cleanup).

%% Listen on `Path`. A socket file already there is either a live
%% daemon (connect succeeds: refuse, so two daemons never share a
%% key) or a stale one (connect refused: remove it and bind).
listen(Path) when is_binary(Path) ->
    P = binary_to_list(Path),
    _ = filelib:ensure_dir(P),
    case filelib:is_file(P) of
        true ->
            case gen_tcp:connect({local, P}, 0, [binary, {active, false}],
                                 1000) of
                {ok, S} ->
                    gen_tcp:close(S),
                    {error, <<"another daemon is listening on this socket">>};
                {error, _} ->
                    _ = file:delete(P),
                    bind(P)
            end;
        false ->
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

%% Append `Data` to `Buffer` and cut off every complete line. Returns
%% `{Lines, Rest}`, `Rest` being the unterminated tail. A trailing `\r`
%% is dropped so CRLF clients work.
split_lines(Buffer, Data) ->
    Parts = binary:split(<<Buffer/binary, Data/binary>>, <<"\n">>, [global]),
    {Complete, [Rest]} = lists:split(length(Parts) - 1, Parts),
    {[strip_cr(L) || L <- Complete], Rest}.

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

now_ms() ->
    erlang:system_time(millisecond).
