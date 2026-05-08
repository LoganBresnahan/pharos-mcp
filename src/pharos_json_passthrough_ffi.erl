%% Treat an already-encoded JSON binary as a `gleam_json` `Json` value.
%%
%% `gleam_json`'s internal representation IS the JSON byte sequence
%% (see deps/gleam_json/src/gleam_json_ffi.erl — every constructor
%% returns iodata, `to_string` just flattens it). So a binary that is
%% already valid JSON can be returned as-is and threads through every
%% downstream `json.object`/`json.preprocessed_array` composition
%% verbatim.
%%
%% This is the escape hatch behind `[languages.<id>] *_json` overrides:
%% the user supplies a JSON string in pharos.toml, pharos validates
%% well-formedness with `json:decode/1` first, then passes the original
%% bytes through here as a `Json` value to splice into the
%% `initialize.params.initializationOptions` envelope.
%%
%% Callers MUST validate the binary is well-formed JSON (via
%% `gleam/json.parse`) BEFORE calling this — we do no checking, and a
%% malformed payload would break the LSP wire frame.

-module(pharos_json_passthrough_ffi).
-export([raw/1, parse_object_to_raw_pairs/1]).

raw(Bin) when is_binary(Bin) -> Bin.

%% Validate that Bin is a JSON OBJECT and split it into a list of
%% `{KeyBinary, ValueRawJsonBinary}` pairs. The Gleam side wraps the
%% raw value bytes via `raw/1` and assembles a `Dict(String, Json)`.
%%
%% Used by `workspace_configuration_json` overrides — `workspace/
%% configuration` is a section→settings map, so the override must be a
%% top-level JSON object. Other shapes return `{error, ...}`.
parse_object_to_raw_pairs(Bin) when is_binary(Bin) ->
    try json:decode(Bin) of
        Map when is_map(Map) ->
            Pairs = maps:fold(fun(K, V, Acc) ->
                [{K, iolist_to_binary(json:encode(V))} | Acc]
            end, [], Map),
            {ok, Pairs};
        _ ->
            {error, not_an_object}
    catch
        _:_ -> {error, parse_failed}
    end.
