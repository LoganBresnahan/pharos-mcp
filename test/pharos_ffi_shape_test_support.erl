%% Erlang-side helpers for ffi_shape_test.gleam. Same role as
%% pharos_runtime_ffi_test_support: expose runtime behaviour that
%% isn't expressible from Gleam alone — here, mutating process env
%% (including raw non-UTF8 bytes for the defensive-wrap test).

-module(pharos_ffi_shape_test_support).

-export([
    set_env/2,
    unset_env/1,
    set_env_raw_bytes/2
]).

%% Set an env var from a Gleam-side String (UTF-8 binary).
set_env(Name, Value) when is_binary(Name), is_binary(Value) ->
    os:putenv(binary_to_list(Name), binary_to_list(Value)),
    nil.

unset_env(Name) when is_binary(Name) ->
    os:unsetenv(binary_to_list(Name)),
    nil.

%% Set an env var with raw bytes that may include invalid UTF-8 starts.
%% binary_to_list yields the bytes verbatim — os:putenv accepts them.
%% This exercises the defensive-wrap path in pharos_env_ffi:get/1 where
%% unicode:characters_to_binary returns {error, _, _} rather than a
%% raw binary, and we want the FFI to still produce a well-typed
%% Option(String) value rather than leak the error tuple.
set_env_raw_bytes(Name, Value) when is_binary(Name), is_binary(Value) ->
    os:putenv(binary_to_list(Name), binary_to_list(Value)),
    nil.
