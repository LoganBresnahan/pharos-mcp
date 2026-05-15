%% Erlang FFI helper: environment variable lookup.
%%
%% Returns Gleam Option(String): {none} when unset, {some, Binary} when set.

-module(pharos_env_ffi).
-export([get/1]).

get(Name) when is_binary(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false ->
            none;
        Value ->
            %% unicode:characters_to_binary can return {error,Bin,Rest} or
            %% {incomplete,Bin,Rest} on invalid byte sequences; protect the
            %% Option(String) shape contract so callers don't crash on
            %% pattern match of {some, Tuple}.
            case unicode:characters_to_binary(Value) of
                Bin when is_binary(Bin) -> {some, Bin};
                {error, Partial, _Rest} when is_binary(Partial) -> {some, Partial};
                {incomplete, Partial, _Rest} when is_binary(Partial) -> {some, Partial};
                _ -> {some, unicode:characters_to_binary(Value, latin1)}
            end
    end.
