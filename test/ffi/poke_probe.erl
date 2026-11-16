%% SPDX-License-Identifier: Apache-2.0

-module(poke_probe).
-export([current_leader/0, wait_dead/2, io_requests/0, fail/0, sleep/1, alive/1, self_pid/0]).
sleep(Milliseconds) -> timer:sleep(Milliseconds), nil.
alive(Pid) -> is_process_alive(Pid).
self_pid() -> self().

current_leader() -> group_leader().
wait_dead(Pid, Timeout) ->
    Ref = monitor(process, Pid),
    receive {'DOWN', Ref, process, Pid, _} -> true
    after Timeout -> demonitor(Ref, [flush]), false end.
io_requests() ->
    ok = io:request(group_leader(), {requests, [
        {put_chars, unicode, <<"one">>},
        {put_chars, unicode, io_lib, format, ["~s", ["two"]]}]}),
    {error, put_chars} = io:request(group_leader(), {put_chars, unicode, <<255>>}),
    {error, request} = io:request(group_leader(), {unsupported, request}),
    nil.
fail() -> erlang:error(foreign_failure).
