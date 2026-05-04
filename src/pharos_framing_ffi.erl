%% Erlang FFI helpers for `pharos/lsp/framing.gleam`.
%%
%% The Gleam stdlib does not expose a fast substring search over
%% BitArray (binaries). The framing parser needs to find the
%% `\r\n\r\n` header/body delimiter inside an arbitrary read buffer
%% on every parse step, so a hand-rolled byte-by-byte scan in Gleam
%% would be O(n) per byte and not great. `binary:match/2` is BIF and
%% near-optimal.
%%
%% Returns a Gleam-friendly tagged-tuple `Result(Int, Nil)`:
%%   - `{ok, Pos}` — needle found at byte offset Pos
%%   - `{error, nil}` — needle not present in haystack

-module(pharos_framing_ffi).
-export([find/2]).

find(Haystack, Needle) ->
    case binary:match(Haystack, Needle) of
        nomatch ->
            {error, nil};
        {Pos, _Len} ->
            {ok, Pos}
    end.
