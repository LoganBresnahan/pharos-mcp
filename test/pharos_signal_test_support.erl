%% Erlang-side helpers for signal_target_test.gleam. Same role as
%% pharos_ffi_shape_test_support: expose runtime behaviour that isn't
%% expressible from Gleam alone — here, spawning a real OS process
%% that itself spawns a grandchild, so the process-group kill path can
%% be asserted against actual processes rather than mocked.

-module(pharos_signal_test_support).

-export([
    own_os_pid/0,
    signal_target/1,
    spawn_child_with_grandchild/0
]).

%% This BEAM's own OS pid, as an integer.
own_os_pid() ->
    list_to_integer(os:getpid()).

%% Thin re-export so the Gleam test can reach the decision function
%% without the production module needing a Gleam-facing wrapper.
signal_target(Pid) when is_integer(Pid) ->
    pharos_instance_track_ffi:signal_target(Pid).

%% Spawn a shell that backgrounds a `sleep` (the grandchild) and then
%% sleeps itself, printing both pids. Mirrors the shape that actually
%% leaks in production: jdtls and metals spawn helper processes which
%% survive a bare `kill <lsp_pid>`.
%%
%% Returns `{ChildPid, GrandchildPid}`, or `{0, 0}` if the child never
%% reported. `{0, 0}` rather than an `error` atom so the Gleam side
%% keeps a single `#(Int, Int)` type and treats the failure as a skip —
%% a sandbox without `/bin/sh` job control should not fail the suite.
%% The caller is responsible for reaping: every test that calls this
%% kills the group before returning.
spawn_child_with_grandchild() ->
    Port = erlang:open_port(
        {spawn_executable, "/bin/sh"},
        [{args, ["-c", "sleep 30 & echo $$ $!; sleep 30"]},
         binary, use_stdio, exit_status, stream, hide]),
    receive
        {Port, {data, Data}} ->
            case string:lexemes(string:trim(binary_to_list(Data)), " \n") of
                [Child, Grandchild] ->
                    try
                        {list_to_integer(Child), list_to_integer(Grandchild)}
                    catch
                        _:_ -> {0, 0}
                    end;
                _ ->
                    {0, 0}
            end
    after 5000 ->
        {0, 0}
    end.
