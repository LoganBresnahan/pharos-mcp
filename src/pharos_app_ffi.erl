%% OTP application start callback.
%%
%% Mix release / Burrito boot the BEAM and start :pharos via the OTP
%% application controller, which calls this module's start/2. We
%% delegate to `pharos:boot/0` (Gleam) which is idempotent and
%% returns the root supervisor's pid. Returning that pid (instead of
%% the previous spawn_link'd plain process) makes the supervisor the
%% application's primary process, which is what
%% `runtime_supervision_tree` walks via application_controller —
%% fixes limitation 2a from the M9.5 dogfood.
%%
%% Test-time flag: gleeunit suites pass `auto_boot: false` via the
%% application env in mix.exs so each test can stand up its own
%% scoped writer / pool without racing the global root tree. In
%% that mode we revert to the prior idle-child behaviour so the
%% application still has a primary process to satisfy the OTP
%% protocol.
%%
%% Wired in mix.exs's application/0 via
%% `mod: {pharos_app_ffi, [auto_boot: ...]}`.

-module(pharos_app_ffi).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, Args) ->
    case proplists:get_value(auto_boot, Args, true) of
        false ->
            Pid = spawn_link(fun idle/0),
            {ok, Pid};
        true ->
            case 'pharos':boot() of
                {ok, Pid} -> {ok, Pid};
                {error, Reason} -> {error, Reason}
            end
    end.

idle() ->
    receive
        stop -> ok
    after infinity ->
        ok
    end.

stop(_State) ->
    ok.
