%% Erlang FFI: minimal filesystem helpers for path discovery and
%% reading file contents.
%%
%% Used by `pharos/workspace_root` (ancestor walk looking for a
%% project root marker) and by tools that need on-disk file content
%% as a fallback when the optional VSCode bridge is not available
%% (Milestone 7).
%%
%% Returns Gleam-friendly tagged tuples shaped as Result(t, e).

-module(pharos_fs_ffi).
-export([is_regular_file/1, dirname/1, read_file/1, shell/1, encode_json/1]).

is_regular_file(Path) ->
    filelib:is_regular(binary_to_list(Path)).

dirname(Path) ->
    list_to_binary(filename:dirname(binary_to_list(Path))).

read_file(Path) ->
    case file:read_file(binary_to_list(Path)) of
        {ok, Bytes} ->
            {ok, Bytes};
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Run a shell command. Accepts a binary (Gleam String). Returns a
%% binary holding the command's combined stdout+stderr. Used by tests
%% to set up temp directories without dragging in a filesystem dep.
shell(Cmd) ->
    list_to_binary(os:cmd(binary_to_list(Cmd))).

%% Re-encode a JSON-derived term back to a JSON binary. OTP 27's
%% json:encode/1 returns iodata (a deeply nested iolist of binaries
%% and small integers); flatten to a single binary so Gleam can use
%% it as a String. Used by tools/tier1/diagnostics to round-trip the
%% LSP's response back through MCP without a Json type detour.
encode_json(Term) ->
    iolist_to_binary(json:encode(Term)).
