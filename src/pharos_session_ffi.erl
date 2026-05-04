%% Erlang FFI helper: cryptographically-random session id generator.
%%
%% Used by `pharos/mcp/sessions.gleam`. Returns a 32-character
%% lowercase hex string (16 bytes of randomness; UUID-strength).
%% Format choice keeps the value safe for HTTP headers and URL
%% components without escaping.

-module(pharos_session_ffi).
-export([generate_session_id/0]).

generate_session_id() ->
    Bytes = crypto:strong_rand_bytes(16),
    Hex = binary:list_to_bin([io_lib:format("~2.16.0b", [B]) || <<B:8>> <= Bytes]),
    Hex.
