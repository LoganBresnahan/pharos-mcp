%% Erlang FFI: minimal filesystem helpers for path discovery and
%% reading file contents.
%%
%% Used by `llm_lsp_mcp/workspace_root` (ancestor walk looking for a
%% project root marker) and by tools that need on-disk file content
%% as a fallback when the optional VSCode bridge is not available
%% (Milestone 7).
%%
%% Returns Gleam-friendly tagged tuples shaped as Result(t, e).

-module(llm_lsp_mcp_fs_ffi).
-export([is_regular_file/1, dirname/1, read_file/1, shell/1]).

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
