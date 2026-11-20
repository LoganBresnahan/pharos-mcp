%% Erlang FFI for the `tomerl` TOML 1.0 parser.
%%
%% Returns parsed values as Erlang maps with binary keys + binary
%% string values. Gleam side decodes the resulting `Dynamic` shape
%% via `gleam/dynamic/decode`. We do not pre-flatten or coerce —
%% that work happens once on the Gleam side where the typed Config
%% record is the destination.

-module(pharos_toml_ffi).
-export([parse/1, format_error/1, value_kind/1]).

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

%% What a parsed value is, for pharos.toml's checks (#32). tomerl gives
%% tables as maps, arrays as lists, strings as binaries, and dates and
%% times as tuples, which Gleam's list decoder would otherwise take.
value_kind(V) when is_map(V) -> <<"table">>;
value_kind(V) when is_list(V) -> <<"array">>;
value_kind(V) when is_binary(V) -> <<"string">>;
value_kind(V) when is_boolean(V) -> <<"bool">>;
value_kind(V) when is_integer(V) -> <<"integer">>;
value_kind(V) when is_float(V) -> <<"float">>;
value_kind(_) -> <<"datetime">>.
