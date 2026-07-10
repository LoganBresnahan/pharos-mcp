%% Single source of truth for pharos's own version string.
%%
%% Returns the OTP application `vsn` for `pharos`, which mix/gleam bake
%% from `mix.exs` (@version_base, cleaned to bare semver when
%% PHAROS_RELEASE=1) and `gleam.toml`. The Gleam `pharos/version`
%% module wraps this so --version, the MCP serverInfo, and the
%% clientInfo pharos sends as an LSP/MCP client all read one value that
%% tracks the built artifact automatically — no hand-bumped literals to
%% drift out of sync (five of them once shipped 0.1.3 as "0.1.2").
-module(pharos_version_ffi).
-export([current/0]).

current() ->
    %% `load` makes `get_key` work even when the app is present on the
    %% code path but not started (e.g. a bare unit-test process).
    %% already_loaded / already-started both return quietly.
    _ = application:load(pharos),
    case application:get_key(pharos, vsn) of
        {ok, Vsn} when is_list(Vsn) -> list_to_binary(Vsn);
        {ok, Vsn} when is_binary(Vsn) -> Vsn;
        _ -> <<"0.0.0-unknown">>
    end.
