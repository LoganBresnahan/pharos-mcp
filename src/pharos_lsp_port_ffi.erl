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
-include_lib("kernel/include/file.hrl").
-export([spawn/3, send/2, receive_data/2, close/1, connect/2, decode_port_data/1, decode_port_exit/1]).

%% Decode a raw mailbox payload that gleam_otp's selector handed us
%% via `process.select_other`. Returns `{ok, Bytes}` if the payload
%% is `{Port, {data, Bytes}}`; `{error, nil}` for anything else
%% (exit_status, system messages, junk).
decode_port_data(Payload) when is_tuple(Payload), tuple_size(Payload) =:= 2 ->
    case Payload of
        {_Port, {data, Bytes}} when is_binary(Bytes) -> {ok, Bytes};
        _ -> {error, nil}
    end;
decode_port_data(_) ->
    {error, nil}.

%% ADR-030 I2: surface LSP subprocess exits so the proc actor can
%% log them instead of dropping the message as system noise. Returns
%% `{ok, ExitStatus}` for `{Port, {exit_status, Status}}` tuples,
%% `{error, nil}` for anything else.
decode_port_exit(Payload) when is_tuple(Payload), tuple_size(Payload) =:= 2 ->
    case Payload of
        {_Port, {exit_status, Status}} when is_integer(Status) -> {ok, Status};
        _ -> {error, nil}
    end;
decode_port_exit(_) ->
    {error, nil}.

%% Spawn a subprocess. `Command` is either an absolute path
%% (starts with `/`) or a bare name resolved against the current
%% PATH via `os:find_executable/1` (ADR-018). `Args` is a list of
%% binary arguments; `Cwd` is the working directory the subprocess
%% inherits.
%%
%% Returns:
%%   {ok, Port}                       — Port opened
%%   {error, {binary_not_found, Cmd}} — bare name not on PATH
%%   {error, {spawn_failed, R}}       — open_port raised
spawn(Command, Args, Cwd) ->
    case resolve_command(Command) of
        {error, not_found} ->
            {error, {binary_not_found, Command}};
        {ok, Resolved} ->
            try
                Port = erlang:open_port({spawn_executable, Resolved}, [
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
                        {spawn_failed,
                            list_to_binary(io_lib:format("~p", [Reason]))}}
            end
    end.

%% Resolve a command to an absolute filesystem path. Absolute
%% commands (starting with `/`) get a filesystem existence + executable
%% check so a non-existent override path surfaces as the typed
%% `BinaryNotFound` user-facing message instead of falling through to
%% open_port and crashing with `enoent` (which the upstream describer
%% formatted as "subprocess spawn failed: enoent" — a generic and
%% un-actionable wrapper). Bare names go through
%% `os:find_executable/1` which consults `$PATH` (already does the
%% executability check). Returns `{ok, StringPath}` (Erlang string,
%% not binary, since open_port's spawn_executable wants a string) or
%% `{error, not_found}` when no executable is reachable.
resolve_command(Command) when is_binary(Command) ->
    case Command of
        <<$/, _/binary>> ->
            CmdStr = binary_to_list(Command),
            case is_executable_file(CmdStr) of
                true -> {ok, CmdStr};
                false -> {error, not_found}
            end;
        _ ->
            case os:find_executable(binary_to_list(Command)) of
                false -> {error, not_found};
                Path -> {ok, Path}
            end
    end.

%% True when Path is a regular file (or a symlink that resolves to one)
%% and has at least one executable bit set. Mirrors the implicit
%% contract `os:find_executable/1` enforces for bare names.
is_executable_file(Path) ->
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, #file_info{type = regular, mode = Mode}} ->
            Mode band 8#111 =/= 0;
        _ ->
            false
    end.

%% Write raw bytes to the subprocess's stdin. The framing layer
%% (`lsp/framing.encode`) builds Content-Length-prefixed bodies; this
%% function does not add any framing. Tracing is handled in the
%% Gleam-side `pharos/lsp/trace` module so traces flow through the
%% structured logger.
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

