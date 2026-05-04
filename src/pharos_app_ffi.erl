%% OTP application start callback.
%%
%% Mix release / Burrito boot the BEAM and start :pharos via the OTP
%% application controller, which calls this module's start/2. Without
%% it, the application loads with no top-level process and the binary
%% exits or hangs immediately because pharos:main/0 (the stdin reader
%% loop) is never invoked.
%%
%% Linked spawn: when main/0 returns (EOF on stdin, or fatal error),
%% the linked process exits, the application controller observes the
%% exit, and the release shuts the BEAM down. That matches the dev
%% wrapper's behavior of `erl -eval "pharos:main(), halt(0)."`.
%%
%% Wired in mix.exs's application/0 via `mod: {pharos_app_ffi, []}`.

-module(pharos_app_ffi).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    Pid = spawn_link(fun() ->
        pharos:main(),
        %% Explicitly halt instead of letting the spawn_link'd process
        %% die. Mix release sets :pharos to start_permanent in :prod, so
        %% normal termination of the application's primary process would
        %% otherwise crash the BEAM with a "Kernel pid terminated" notice
        %% and an erl_crash.dump in cwd. init:stop/1 closes applications
        %% gracefully and exits with the given status code, no dump.
        init:stop(0)
    end),
    {ok, Pid}.

stop(_State) ->
    ok.
