%% Session context in the process dictionary (ADR-034).
%%
%% A dispatcher process serving one MCP session binds that session's
%% id, cwd, env, Config and language registry here once, at spawn.
%% `config:cached/0`, `registry:cached/0` and `session_ctx` read them
%% back without threading a context argument through every tool. The
%% shape mirrors the correlation id in `pharos_log_ffi`: per process,
%% not propagated across sends, so anything that runs on behalf of a
%% session must run on (or be handed values from) a bound process.
%%
%% Gleam cannot express the process dictionary, hence the shim.

-module(pharos_session_ctx_ffi).
-export([bind/5, id/0, cwd/0, env/0, config/0, registry/0, os_env/0]).

-define(ID, pharos_session_id).
-define(CWD, pharos_session_cwd).
-define(ENV, pharos_session_env).
-define(CONFIG, pharos_session_config).
-define(REGISTRY, pharos_session_registry).

bind(Id, Cwd, Env, Config, Registry) ->
    erlang:put(?ID, Id),
    erlang:put(?CWD, Cwd),
    erlang:put(?ENV, Env),
    erlang:put(?CONFIG, Config),
    erlang:put(?REGISTRY, Registry),
    nil.

id() -> lookup(?ID).
cwd() -> lookup(?CWD).
env() -> lookup(?ENV).
config() -> lookup(?CONFIG).
registry() -> lookup(?REGISTRY).

lookup(Key) ->
    case erlang:get(Key) of
        undefined -> {error, nil};
        Value -> {ok, Value}
    end.

%% The process environment as a map of binaries. Values that are not
%% valid UTF-8 are read as latin1, as `pharos_env_ffi:get/1` does, so
%% one odd variable can't drop the whole map.
os_env() ->
    maps:from_list([{to_binary(K), to_binary(V)} || {K, V} <- os:env()]).

to_binary(Chars) ->
    case unicode:characters_to_binary(Chars) of
        Bin when is_binary(Bin) -> Bin;
        _ -> unicode:characters_to_binary(Chars, latin1)
    end.
