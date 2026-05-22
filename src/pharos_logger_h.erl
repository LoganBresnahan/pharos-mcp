%% ADR-030 B1: minimal try/catch-wrapped logger handler.
%%
%% Writes formatted log events to `standard_error` with the
%% `io:put_chars` call wrapped in try/catch. If fd 2 has been closed
%% (host shutdown race, MCP client closing pipes, `2>/dev/null`
%% patterns) the write raises and we silently drop the event instead
%% of cascading into the BEAM logger crash path that terminated the
%% runtime three times on 2026-05-22.
%%
%% This module deliberately does NOT use `logger_h_common` (the
%% gen_server-like framework that `logger_std_h` and
%% `logger_disk_log_h` piggyback on). logger_h_common requires the
%% callback module to export ~16 functions covering init, terminate,
%% reset_state, write, filesync, handle_info, check_config,
%% config_changed, and the standard handler lifecycle. That surface
%% inherits backpressure (drop_mode_qlen / flush_qlen) which pharos
%% does not need: the only events we route through this handler are
%% SASL crash reports, supervisor restart notices, and the
%% occasional `logger:error/1` call from pharos's own code — a
%% volume that does not stress a synchronous I/O handler.
%%
%% The kernel default handler is suppressed via
%% `config :kernel, :logger, [{:handler, :default, :undefined}]` in
%% `config/config.exs`, so this handler is the only path log events
%% take after `pharos:main/0` installs it. The window between BEAM
%% startup and main installing the handler (~50 ms in dev,
%% comparable in release) drops events silently — those events are
%% pre-main OTP boot chatter that pharos does not surface to users
%% under any condition anyway.

-module(pharos_logger_h).

-export([
    log/2,
    adding_handler/1,
    removing_handler/1
]).

%% Optional callback. Logger calls this once when the handler is
%% installed via `logger:add_handler/3`. Returning `{ok, Config}`
%% accepts the config unchanged.
adding_handler(Config) ->
    {ok, Config}.

%% Optional callback. Logger calls this when the handler is removed
%% via `logger:remove_handler/1`. No internal state to release.
removing_handler(_Config) ->
    ok.

%% Required callback. Format the log event and write to stderr.
%% The format step itself can raise (a buggy custom formatter, an
%% unprintable term in the message metadata) — we catch that too,
%% so a malformed log event cannot take down the runtime.
log(LogEvent, Config) ->
    Formatted = format_event(LogEvent, Config),
    try
        io:put_chars(standard_error, Formatted)
    catch
        _:_ -> ok
    end,
    ok.

%% Pick the formatter from handler config and run it inside try/catch.
%% Falls back to `logger_formatter` with default options if the
%% configured formatter raises or no formatter is configured.
format_event(LogEvent, Config) ->
    {FmtMod, FmtConfig} = case maps:get(formatter, Config, undefined) of
        {M, C} when is_atom(M) -> {M, C};
        _ -> {logger_formatter, #{}}
    end,
    try
        FmtMod:format(LogEvent, FmtConfig)
    catch
        _:_ ->
            try
                logger_formatter:format(LogEvent, #{})
            catch
                _:_ -> <<>>
            end
    end.
