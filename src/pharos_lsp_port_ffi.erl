%% Erlang FFI: subprocess management for LSP servers via Erlang Port.
%%
%% The LSP client owns one Port per running language server. The Port
%% wraps the LSP's stdio so we can read its stdout in raw binary mode
%% (no line buffering — we feed bytes to the Content-Length parser in
%% `lsp/framing`) and write to its stdin.
%%
%% All return values are tagged tuples shaped so Gleam can pattern-match
%% them as the variants declared in `lsp/port.gleam`.

-module(pharos_lsp_port_ffi).
-export([spawn/3, send/2, receive_data/2, close/1, connect/2]).

%% Spawn a subprocess. `Command` is the absolute path or PATH-resolved
%% binary name; `Args` is a list of binary arguments; `Cwd` is the
%% working directory the subprocess inherits.
%%
%% Returns:
%%   {ok, Port}                  — Port opened
%%   {error, {spawn_failed, R}}  — open_port raised
spawn(Command, Args, Cwd) ->
    try
        Port = erlang:open_port({spawn_executable, binary_to_list(Command)}, [
            {args, [binary_to_list(A) || A <- Args]},
            binary,
            use_stdio,
            exit_status,
            stream,
            hide,
            {cd, binary_to_list(Cwd)}
        ]),
        {ok, Port}
    catch
        error:Reason ->
            {error,
                {spawn_failed, list_to_binary(io_lib:format("~p", [Reason]))}}
    end.

%% Write raw bytes to the subprocess's stdin. The framing layer
%% (`lsp/framing.encode`) builds Content-Length-prefixed bodies; this
%% function does not add any framing.
%%
%% Returns:
%%   {ok, nil}        — bytes accepted by the port
%%   {error, closed}  — port already closed
send(Port, Bytes) ->
    try
        true = erlang:port_command(Port, Bytes),
        {ok, nil}
    catch
        _:_ -> {error, closed}
    end.

%% Wait up to TimeoutMs for one chunk of stdout from the subprocess.
%% Returned bytes are whatever the kernel hands us — the framing parser
%% buffers across calls.
%%
%% Returns:
%%   {ok, Bytes}                    — got a chunk
%%   {error, timeout}               — no data within TimeoutMs
%%   {error, {port_closed, Status}} — subprocess exited (exit code Status)
receive_data(Port, TimeoutMs) ->
    receive
        {Port, {data, Bytes}} ->
            {ok, Bytes};
        {Port, {exit_status, Status}} ->
            {error, {port_closed, Status}}
    after TimeoutMs ->
        {error, timeout}
    end.

%% Close the Port. Idempotent — closing a closed port is a no-op rather
%% than a crash.
close(Port) ->
    try
        true = erlang:port_close(Port),
        nil
    catch
        _:_ -> nil
    end.

%% Transfer Port ownership to a different Pid. Erlang delivers Port
%% messages ({Port, {data, _}} and {Port, {exit_status, _}}) to the
%% process recorded as the Port's owner. The pool actor spawns the
%% LSP (so it is initial owner) and runs the initialize handshake;
%% before returning the Client to a tool, the pool calls connect/2
%% to hand ownership over to the tool's process so subsequent
%% receive_data/2 calls drain the tool's own mailbox, not the pool's.
%%
%% port_connect/2 must be called by the current owner — that is why
%% this lives on the pool's path, not the consumer's.
connect(Port, Pid) ->
    try
        true = erlang:port_connect(Port, Pid),
        %% After connect, the original owner stops receiving messages
        %% but is still linked. Unlink so the pool process is not
        %% killed if the LSP exits.
        true = unlink(Port),
        {ok, nil}
    catch
        _:_ -> {error, nil}
    end.
