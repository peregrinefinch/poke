%% SPDX-License-Identifier: Apache-2.0
%%% Resource boundaries need try/after and process monitors. Keep them here;
%%% test policy and typed assertions belong to the Pooka modules above them.
-module(poke_test_ffi).
-export([with_resource/3, with_directory/1, channel/0, send/3,
         receive_message/3, within/2, with_task/2, with_process/2]).

with_resource(Setup, Cleanup, Run) ->
    Resource = Setup(),
    try Run(Resource) after Cleanup(Resource) end.

with_directory(Run) ->
    Root = filename:join([<<"build">>, <<"poke-fixtures">>]),
    ok = filelib:ensure_dir(filename:join(Root, <<"placeholder">>)),
    Path = fresh_directory(Root),
    try Run(Path) after ok = file:del_dir_r(Path) end.

fresh_directory(Root) ->
    Token = iolist_to_binary([os:getpid(), "-", integer_to_list(erlang:unique_integer([positive]))]),
    Path = filename:join(Root, Token),
    case file:make_dir(Path) of
        ok -> Path;
        {error, eexist} -> fresh_directory(Root);
        {error, Why} -> erlang:error({temporary_directory_failed, Why})
    end.

channel() -> {self(), erlang:unique_integer([positive, monotonic])}.
send(Pid, Tag, Value) -> Pid ! {'$poke_message', Tag, Value}, nil.
receive_message(Owner, Tag, Timeout) when is_integer(Timeout), Timeout >= 0 ->
    case Owner =:= self() of
        false -> {error, <<"channel can only receive in its owner process">>};
        true ->
            receive {'$poke_message', Tag, Value} -> {ok, Value}
            after Timeout -> {error, <<"message timed out">>} end
    end;
receive_message(_, _, _) -> {error, <<"timeout must be nonnegative">>}.

%% The result travels in the monitor reason, so it cannot leave a second late
%% result message behind after a timeout. Every worker is joined before return.
within(Run, Timeout) when is_integer(Timeout), Timeout >= 0 ->
    {Pid, Ref} = spawn_monitor(fun() ->
        Outcome = try {ok, Run()}
                  catch Class:Reason -> {error, describe(Class, Reason)} end,
        exit({'$poke_result', Outcome})
    end),
    receive
        {'DOWN', Ref, process, Pid, {'$poke_result', Outcome}} -> Outcome;
        {'DOWN', Ref, process, Pid, Reason} -> {error, describe(exit, Reason)}
    after Timeout ->
        stop(Pid, Ref),
        {error, <<"worker timed out">>}
    end;
within(_, _) -> {error, <<"timeout must be nonnegative">>}.

with_task(Run, Use) ->
    {Pid, Ref} = spawn_monitor(Run),
    try Use(Pid) after stop(Pid, Ref) end.

stop(Pid, Ref) ->
    exit(Pid, kill),
    receive {'DOWN', Ref, process, Pid, _} -> ok end.

describe(Class, Reason) ->
    unicode:characters_to_binary(io_lib:format("~p: ~tp", [Class, Reason])).

with_process(Pid, Use) when Pid =/= self() ->
    Ref = monitor(process, Pid),
    try Use(Pid) after stop(Pid, Ref) end;
with_process(_, _) -> erlang:error(cannot_adopt_test_process).
