%% `simple_one_for_one` supervisor for lsp_proc workers (ADR-017a).
%%
%% Hosts every Gleam-side `pharos@lsp@proc` actor as a real child
%% of an Erlang :supervisor so individual worker crashes restart
%% in place. The Gleam side reads the spawned actor's Subject from
%% the ETS bridge table `pharos_lsp_proc_subjects` after
%% `start_child/5` returns; see ADR-017a for the bridge mechanics.
%%
%% Restart strategy:
%%   - simple_one_for_one (one child spec, dynamic instances)
%%   - intensity 5 / period 60 (matches pharos_root)
%%   - per-child restart: transient (abnormal exit restarts;
%%     normal exit, e.g. operator-requested via runtime_kill_lsp,
%%     does not)
%%
%% Pool calls `start_child/5` with the proc's spawn arguments.
%% Cooperative termination uses `terminate_child/1` which suppresses
%% restart per supervisor protocol.

-module(pharos_lsp_dyn_sup).
-behaviour(supervisor).

-export([start_link/0, start_child/8, terminate_child/1]).
-export([init/1]).

-define(NAME, pharos_lsp_dyn_sup).

%% Spawn the supervisor under the local registered name `?NAME`.
%% Idempotent: a second call returns the existing pid so the
%% supervised wiring works whether the parent supervisor restarts
%% it from scratch or finds a pre-existing instance.
start_link() ->
    case supervisor:start_link({local, ?NAME}, ?MODULE, []) of
        {ok, Pid} -> {ok, Pid};
        {error, {already_started, Pid}} -> {ok, Pid};
        {error, Reason} -> {error, Reason}
    end.

%% Spawn a new lsp_proc worker. simple_one_for_one appends these
%% args to the spec's empty default arg list, so the call shape on
%% the worker side is
%%   pharos@lsp@proc:start_link_supervised(
%%     Language, Workspace, Cmd, Args, InitParams, TimeoutMs)
%% which performs init + ETS bridge insert keyed by
%% (Language, Workspace) and returns {ok, Pid}. The Language and
%% Workspace also become the supervisor's restart args, so an
%% abnormal exit + automatic restart calls start_link_supervised
%% with the same (Language, Workspace) — overwriting the bridge
%% row instead of leaking.
start_child(Language, Workspace, Cmd, Args, InitParams, TimeoutMs,
            ReadinessToken, ReadinessTimeoutMs) ->
    case supervisor:start_child(?NAME,
            [Language, Workspace, Cmd, Args, InitParams, TimeoutMs,
             ReadinessToken, ReadinessTimeoutMs]) of
        {ok, Pid} -> {ok, Pid};
        {ok, Pid, _Info} -> {ok, Pid};
        {error, {already_started, Pid}} -> {ok, Pid};
        {error, Reason} ->
            {error, format_reason(Reason)}
    end.

%% Preserve the human-readable error string when the child returned
%% one (proc.start_link_supervised maps every internal error to a
%% binary via describe_start_error/1). Without this branch
%% io_lib:format("~p", [<<"..."/utf8>>]) renders the binary as a
%% literal byte list — `<<99,108,...>>` — and the BinaryNotFound /
%% handshake-failed text gets unreadable. For non-binary reasons we
%% still fall back to ~p so unexpected supervisor protocol errors
%% (already_present, max_children, etc.) get a useful description.
format_reason(Reason) when is_binary(Reason) -> Reason;
format_reason(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).

%% Operator-requested termination of one worker. transient strategy
%% means the supervisor does NOT auto-restart after this call, so
%% pool's runtime_kill_lsp + cache eviction stay clean.
terminate_child(ChildPid) when is_pid(ChildPid) ->
    case supervisor:terminate_child(?NAME, ChildPid) of
        ok -> nil;
        {error, _} -> nil
    end.

init([]) ->
    Flags = #{
        strategy => simple_one_for_one,
        intensity => 5,
        period => 60
    },
    ChildSpec = #{
        id => lsp_proc,
        start => {pharos@lsp@proc, start_link_supervised, []},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [pharos@lsp@proc]
    },
    {ok, {Flags, [ChildSpec]}}.
