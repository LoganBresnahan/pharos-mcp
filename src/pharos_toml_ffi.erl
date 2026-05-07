%% Erlang FFI for the `tomerl` TOML 1.0 parser.
%%
%% Returns parsed values as Erlang maps with binary keys + binary
%% string values. Gleam side decodes the resulting `Dynamic` shape
%% via `gleam/dynamic/decode`. We do not pre-flatten or coerce —
%% that work happens once on the Gleam side where the typed Config
%% record is the destination.

-module(pharos_toml_ffi).
-export([parse/1, format_error/1]).

%% Parse a TOML document. Returns:
%%   {ok, Map}    — successfully parsed document
%%   {error, Bin} — human-readable error binary
parse(Binary) when is_binary(Binary) ->
    case tomerl:parse(Binary) of
        {ok, Map} -> {ok, Map};
        {error, Reason} -> {error, format_error(Reason)}
    end.

format_error(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).
