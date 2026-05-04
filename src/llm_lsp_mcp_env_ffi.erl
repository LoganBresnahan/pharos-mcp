%% Erlang FFI helper: environment variable lookup.
%%
%% Returns Gleam Option(String): {none} when unset, {some, Binary} when set.

-module(llm_lsp_mcp_env_ffi).
-export([get/1]).

get(Name) when is_binary(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false ->
            none;
        Value ->
            {some, unicode:characters_to_binary(Value)}
    end.
