%% Test support for fs_env_unicode_test (#20): run Fun with an environment
%% variable set (as the OS would set it: characters, via os:putenv) and
%% put the old value back afterwards, even when Fun raises. Otherwise a
%% regression that crashes inside Fun would leave HOME changed for every
%% later test in the run.
-module(fs_env_unicode_test_support).
-export([with_env/3]).

with_env(Key, Value, Fun) when is_binary(Key), is_binary(Value) ->
    K = unicode:characters_to_list(Key),
    Old = os:getenv(K),
    true = os:putenv(K, unicode:characters_to_list(Value)),
    try Fun()
    after
        case Old of
            false -> os:unsetenv(K);
            _ -> os:putenv(K, Old)
        end
    end.
