%% Erlang-side helpers for runtime_ffi_test.gleam. Each function
%% exists solely so the gleam test can request a specific runtime
%% behaviour that isn't expressible from Gleam alone (raising,
%% exiting, building a mixed iolist). Lives in test/ so it ships
%% only with the test bundle.

-module(pharos_runtime_ffi_test_support).

-export([
    mixed_iolist/0,
    divide_by_zero/0,
    explicit_exit/0,
    string_to_codepoint_list/1
]).

%% Build a typical io_lib:format-style iolist: nested list mixing
%% binaries and codepoint integers. unicode:characters_to_binary
%% must absorb this without raising; iolist_to_binary_safe relies
%% on that.
mixed_iolist() ->
    [<<"prefix-">>, [<<"mid"/utf8>>, $-], [104, 105]].

%% Convert a Gleam-side UTF-8 binary into a list of Unicode
%% codepoints (each element an integer). Distinct from
%% `binary_to_list/1` which yields raw bytes — for multi-byte
%% UTF-8 sequences those bytes do NOT survive a subsequent
%% `unicode:characters_to_binary/1` call as the original
%% codepoint. The test relies on this distinction to round-trip
%% non-ASCII text without corruption.
string_to_codepoint_list(Bin) when is_binary(Bin) ->
    unicode:characters_to_list(Bin).

%% Trigger erlang:error(badarith) via division. Used to verify
%% safe_call_0 catches `error` class exceptions. Reads the
%% denominator from process dictionary so the compiler can't
%% pre-fold the expression and warn.
divide_by_zero() ->
    put(denom, 0),
    1 div get(denom).

%% Trigger erlang:exit/1 to verify safe_call_0 catches the `exit`
%% class.
explicit_exit() ->
    exit(intentional_test_exit).
