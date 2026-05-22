%% ADR-030 I1: heartbeat FFI helpers.
%%
%% Two cheap lookups exposed for the heartbeat actor's per-tick log
%% line. Both are wrappers around standard Erlang runtime calls; the
%% layer exists only so the Gleam side can call them via `@external`
%% without pulling in a wider FFI surface.

-module(pharos_heartbeat_ffi).
-export([memory_total_bytes/0, beam_process_count/0]).

%% Total memory in bytes used by all BEAM allocators combined
%% (system + processes + ETS + binaries + code + atoms + ...).
%% Equivalent to the first row of `recon:memory/0` and the value
%% the Gleam side prints under `memory_bytes=`.
memory_total_bytes() ->
    erlang:memory(total).

%% Live BEAM process count. Maps to `process_count=` in the log line.
%% Includes pharos's own processes, the gleam_otp actor tree, every
%% LSP proc actor, every spawn worker, plus OTP/kernel internals.
beam_process_count() ->
    erlang:system_info(process_count).
