%% Erlang FFI helper: line-oriented stdin reader + unbuffered stdout
%% writer.
%%
%% Used by `pharos/mcp/stdio.gleam`. Returns Gleam-friendly tagged
%% tuples that match the StdinResult variant in Gleam.
%%
%% **Why `write_line/1` exists.** Under Erlang's `-noshell -mode
%% embedded` release runtime (Burrito ships with these flags), the
%% default `standard_io` group leader buffers writes and only flushes
%% on stdin EOF. MCP hosts hold stdin open and wait for the response
%% on stdout — the response sits in the buffer indefinitely and the
%% host's 30s connect timeout fires. Bypassing the I/O server with a
%% direct `file:write/2` to a `standard_io` opened in raw mode keeps
%% writes synchronous (each `\n`-terminated line hits the OS pipe
%% before the call returns) so MCP hosts see responses promptly.

-module(pharos_stdin_ffi).
-export([read_line/0, write_line/1, stdin_port/0, decode_port_event/1]).

%% Decode a raw Port-mailbox payload sent to a process that owns the
%% stdin port. Returns one of three Gleam-shaped tags:
%%   {port_line, BinaryWithoutNewline}
%%   port_eof
%%   port_other
%%
%% Lines that span more than the line buffer are returned as `port_line`
%% with the partial chunk; subsequent `noeol` chunks are dropped (MCP
%% lines are well below the 64KB buffer in practice).
decode_port_event({_Port, {data, {eol, Line}}}) ->
    {port_line, line_to_binary(Line)};
decode_port_event({_Port, {data, {noeol, Line}}}) ->
    {port_line, line_to_binary(Line)};
decode_port_event({_Port, eof}) ->
    port_eof;
decode_port_event({'EXIT', _Port, _}) ->
    port_eof;
decode_port_event(_) ->
    port_other.

%% Read one newline-terminated line from fd 0 directly, bypassing
%% Erlang's `:user` group leader.
%%
%% Why: under burrito's release runtime (`-noshell -mode embedded`),
%% the `:user` port-driver delivers stdin reads only when stdin
%% closes — it buffers waiting for a full chunk and never flushes
%% mid-stream. MCP hosts hold stdin open and write one line per
%% request, expecting per-line delivery. Bypassing `:user` with a
%% raw `{fd, 0, 0}` port in `{line, _}` mode gives us synchronous
%% per-line delivery. The port is cached in `persistent_term` after
%% first use; reads block on `receive` until the port driver
%% delivers the next line or EOF.
read_line() ->
    Port = stdin_port(),
    receive
        {Port, {data, {eol, Line}}} ->
            {stdin_line, line_to_binary(Line)};
        {Port, {data, {noeol, Line}}} ->
            %% Line exceeded line buffer — concat with any subsequent
            %% chunks until eol marker. Pathological for MCP (lines
            %% are <16KB), but handle for safety.
            {stdin_line, collect_overflow(Port, line_to_binary(Line))};
        {Port, eof} ->
            stdin_eof;
        {'EXIT', Port, _} ->
            stdin_eof
    end.

collect_overflow(Port, Acc) ->
    receive
        {Port, {data, {eol, Line}}} ->
            <<Acc/binary, (line_to_binary(Line))/binary>>;
        {Port, {data, {noeol, Line}}} ->
            collect_overflow(Port, <<Acc/binary, (line_to_binary(Line))/binary>>);
        {Port, eof} ->
            Acc
    end.

line_to_binary(L) when is_list(L) -> list_to_binary(L);
line_to_binary(B) when is_binary(B) -> B.

stdin_port() ->
    case persistent_term:get(pharos_stdin_port, undefined) of
        undefined ->
            %% Line mode: driver buffers up to 65535 bytes per line
            %% before delivering a `noeol` chunk. binary so we get
            %% binaries instead of charlists. eof so close is signalled.
            P = erlang:open_port({fd, 0, 0}, [in, binary, eof, {line, 65535}]),
            persistent_term:put(pharos_stdin_port, P),
            P;
        P -> P
    end.

%% Write `Body` followed by `\n` directly to fd 1 (stdout), bypassing
%% Erlang's `:user` group leader and its buffering. Returns `nil` so
%% the Gleam caller can keep the existing `Nil` shape.
%%
%% Mechanism: open a one-off port `{fd, 1, 1}`, port_command, then
%% port_close. The close synchronously flushes the driver's output
%% queue before the port shuts down, so each line hits fd 1 before
%% this function returns. A persistent cached port over many writes
%% turned out to leave bytes queued in the driver indefinitely under
%% burrito's release runtime — close-per-write is the fix.
write_line(Body) when is_binary(Body) ->
    Port = erlang:open_port({fd, 1, 1}, [out, binary]),
    true = erlang:port_command(Port, [Body, $\n]),
    erlang:port_close(Port),
    nil.
