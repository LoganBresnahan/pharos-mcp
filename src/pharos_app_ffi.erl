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
            %% Burrito-wrapped releases start :pharos via the OTP
            %% application controller — `pharos:main/0` is NOT
            %% called. Meta-flag dispatch (handle_meta_flags) lives
            %% inside main/0, so without this hook flags like
            %% `--doctor`, `--purge-cache`, and `--cleanup` would
            %% silently fall through into normal boot mode. Run
            %% the dispatcher here; on a Handled outcome we halt
            %% with the exit code the CLI returned. On Continue we
            %% fall through to pharos:boot/0 unchanged.
            case 'pharos':dispatch_meta_or_continue() of
                true -> halt(0);
                _ -> ok
            end,
            case 'pharos':boot() of
                {ok, Pid} ->
                    %% ADR-024 + `pharos warm <lang>...`: same
                    %% post-boot dispatch the `mix start` / main
                    %% path runs. Either spawns a warm-and-exit
                    %% process (subcommand mode) or a normal
                    %% PHAROS_WARM_LANGS background warmup.
                    'pharos':post_boot_dispatch(),
                    {ok, Pid};
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
    %% ADR-030 S3: remove this pharos instance's tracking directory
    %% (`~/.local/share/pharos/instances/<our-pid>/`) so a subsequent
    %% `pharos cleanup` run does not see this instance as an orphan.
    %% Called by application_controller during graceful shutdown
    %% (init:stop / SIGTERM → OTP default → app stop). Best-effort:
    %% the FFI swallows all failures so a slow filesystem cannot
    %% block BEAM teardown.
    _ = pharos_instance_track_ffi:clear_instance_dir(),
    ok.
