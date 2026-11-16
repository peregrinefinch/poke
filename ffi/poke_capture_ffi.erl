%% SPDX-License-Identifier: Apache-2.0

%%% One group leader per capture, with no registered names or global devices.
%%% The collector watches its owner, so abrupt test termination cannot orphan it.
-module(poke_capture_ffi).
-export([output/1]).

output(Run) ->
    Owner = self(),
    Original = group_leader(),
    {Collector, Monitor} = spawn_monitor(fun() ->
        OwnerMonitor = monitor(process, Owner),
        collect(Owner, OwnerMonitor, [])
    end),
    true = group_leader(Collector, Owner),
    Outcome = try {ok, Run()}
              catch Class:Reason:Stack -> {raised, Class, Reason, Stack}
              after true = group_leader(Original, Owner) end,
    Text = finish(Collector, Monitor),
    case Outcome of
        {ok, Value} -> {Value, Text};
        {raised, FailureClass, FailureReason, FailureStack} -> erlang:raise(FailureClass, FailureReason, FailureStack)
    end.

finish(Collector, Monitor) ->
    Reference = make_ref(),
    Collector ! {finish, self(), Reference},
    receive
        {Reference, Text} ->
            receive {'DOWN', Monitor, process, Collector, normal} -> Text end;
        {'DOWN', Monitor, process, Collector, Reason} ->
            erlang:error({capture_collector_failed, Reason})
    end.

collect(Owner, OwnerMonitor, Parts) ->
    receive
        {io_request, From, ReplyAs, Request} ->
            {Reply, Next} = request(Request, Parts),
            From ! {io_reply, ReplyAs, Reply},
            collect(Owner, OwnerMonitor, Next);
        {finish, Owner, Reference} ->
            Owner ! {Reference, iolist_to_binary(lists:reverse(Parts))};
        {'DOWN', OwnerMonitor, process, Owner, _} -> ok
    end.

%% Standard io:format and io:put_chars requests arrive in several shapes.
%% Reject invalid encodings and unsupported input explicitly, never by silence.
request({put_chars, Encoding, Characters}, Parts) ->
    try unicode:characters_to_binary(Characters, Encoding) of
        Text when is_binary(Text) -> {ok, [Text | Parts]};
        _ -> {{error, put_chars}, Parts}
    catch _:_ -> {{error, put_chars}, Parts} end;
request({put_chars, Encoding, Module, Function, Arguments}, Parts) ->
    try apply(Module, Function, Arguments) of
        Characters -> request({put_chars, Encoding, Characters}, Parts)
    catch _:_ -> {{error, put_chars}, Parts} end;
request({put_chars, Characters}, Parts) -> request({put_chars, latin1, Characters}, Parts);
request({put_chars, Module, Function, Arguments}, Parts) ->
    request({put_chars, latin1, Module, Function, Arguments}, Parts);
request({requests, Requests}, Parts) -> requests(Requests, Parts);
request(getopts, Parts) -> {[{binary, false}, {encoding, unicode}], Parts};
request({get_geometry, _}, Parts) -> {{error, enotsup}, Parts};
request(_, Parts) -> {{error, request}, Parts}.

requests([], Parts) -> {ok, Parts};
requests([Request | Rest], Parts) ->
    case request(Request, Parts) of
        {ok, Next} -> requests(Rest, Next);
        Error -> Error
    end;
requests(_, Parts) -> {{error, request}, Parts}.
