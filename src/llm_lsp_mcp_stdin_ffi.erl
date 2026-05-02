%% Erlang FFI helper: line-oriented stdin reader.
%%
%% Used by `llm_lsp_mcp/mcp/stdio.gleam`. Returns Gleam-friendly tagged
%% tuples that match the StdinResult variant in Gleam.

-module(llm_lsp_mcp_stdin_ffi).
-export([read_line/0]).

read_line() ->
    case io:get_line("") of
        eof ->
            stdin_eof;
        {error, Reason} ->
            {stdin_error, Reason};
        Line when is_list(Line) ->
            {stdin_line, unicode:characters_to_binary(Line)};
        Line when is_binary(Line) ->
            {stdin_line, Line}
    end.
