%% SPDX-License-Identifier: Apache-2.0

%%% The small part of testing that needs to look beneath a value's coat.
%%%
%%% Pooka owns generation, shrinking, diffs and review. Erlang lends exception
%%% capture, value inspection and atomic snapshot writes. Assertion failures use
%%% the same tagged payload as the compiler, so its runner retains expected/got.
-module(poke_ffi).
-export([capture_failure/1, mismatch/3, fail/1, inspect/1, equal/3, write_atomic/2, halt/1, columns/0, wrap/2, fit/2, cells/1, visible/1]).

%% Leave source selection to the native runner, which knows the calling test.
fail(Message) -> erlang:error({pooka_assert, Message}).

equal(Actual, Expected, _) when Actual =:= Expected -> nil;
equal(Actual, Expected, Message) ->
    erlang:error({pooka_assert_values, Message, Expected, Actual}).

%% Write beside the destination and rename only after the whole file is closed.
%% A failed write leaves the old accepted snapshot intact. Temporary names use
%% exclusive creation and are cleaned up on every failure path.
write_atomic(Path, Content) ->
    Token = iolist_to_binary([os:getpid(), "-", integer_to_list(erlang:unique_integer([positive]))]),
    Temp = <<Path/binary, ".tmp-", Token/binary>>,
    case file:open(Temp, [write, binary, exclusive]) of
        {ok, Device} ->
            Written = file:write(Device, Content),
            Closed = file:close(Device),
            case {Written, Closed} of
                {ok, ok} ->
                    case file:rename(Temp, Path) of
                        ok -> {ok, nil};
                        {error, Why} -> cleanup(Temp, Why)
                    end;
                {{error, Why}, _} -> cleanup(Temp, Why);
                {_, {error, Why}} -> cleanup(Temp, Why)
            end;
        %% A failed exclusive open does not own the path: never delete it.
        {error, Why} -> {error, reason(Why)}
    end.

cleanup(Temp, Why) ->
    _ = file:delete(Temp),
    {error, reason(Why)}.

reason(Why) -> unicode:characters_to_binary(file:format_error(Why)).
halt(Code) -> erlang:halt(Code).

%% Render the language's ordinary shapes, rather than their BEAM transport tags.
%% Depth is bounded so a failed assertion can still be reported for a deep tree.
inspect(Value) -> unicode:characters_to_binary(value(Value, 0)).
value(_, D) when D > 40 -> "...";
value(true, _) -> "True";
value(false, _) -> "False";
value(nil, _) -> "Nil";
value(none, _) -> "None";
value({ok, V}, D) -> ["Ok(", value(V, D + 1), ")"];
value({error, V}, D) -> ["Error(", value(V, D + 1), ")"];
value({some, V}, D) -> ["Some(", value(V, D + 1), ")"];
value(V, _) when is_binary(V) ->
    case unicode:characters_to_list(V) of
        Text when is_list(Text) -> [$", [escape(C) || C <- Text], $"];
        _ -> io_lib:format("~w", [V])
    end;
value(V, D) when is_list(V) -> ["[", join(V, D + 1), "]"];
value(V, D) when is_tuple(V) ->
    case tuple_to_list(V) of
        [Tag | Fields] when is_atom(Tag) ->
            case string:prefix(atom_to_list(Tag), "pooka@class@") of
                nomatch -> ["#(", join(tuple_to_list(V), D + 1), ")"];
                _ -> [lists:last(string:split(atom_to_list(Tag), "@", all)), "(", join(Fields, D + 1), ")"]
            end;
        Fields -> ["#(", join(Fields, D + 1), ")"]
    end;
value(V, D) when is_map(V) ->
    ["#{", lists:join(", ", [[value(K, D + 1), ": ", value(X, D + 1)] || {K, X} <- lists:sort(maps:to_list(V))]), "}"];
value(V, _) when is_function(V) -> "fn(...) { ... }";
value(V, _) when is_atom(V) -> atom_to_list(V);
value(V, _) -> io_lib:format("~tp", [V]).

join(Values, D) -> lists:join(", ", [value(V, D) || V <- Values]).
escape($") -> "\\\"";
escape($\\) -> "\\\\";
escape($\n) -> "\\n";
escape($\r) -> "\\r";
escape($\t) -> "\\t";
escape(C) when C < 32; C =:= 127 -> io_lib:format("\\u{~.16b}", [C]);
escape(C) -> [C].

%% https://www.erlang.org/doc/apps/stdlib/io.html#columns/0
%% COLUMNS also makes a deterministic width available to redirected previews.
columns() ->
    %% Live geometry wins over a stale COLUMNS inherited from the shell.
    case io:columns() of
        {ok, N} when N > 0 -> N;
        _ ->
            case os:getenv("COLUMNS") of
                false -> 96;
                Text -> try list_to_integer(Text) of
                    N when N > 0 -> N;
                    _ -> 96
                catch _:_ -> 96 end
            end
    end.

%% Keep all clusters, including spaces at the boundary. Snapshot bytes are
%% untouched: these are display rows, not a normalization of stored content.
wrap(Text, Width) ->
    Clusters = string:to_graphemes(unicode:characters_to_list(Text)),
    wrap_clusters(Clusters, max(2, Width), 0, [], []).

wrap_clusters([], _, _, Current, Rows) ->
    case {Current, Rows} of
        {[], []} -> [<<>>];
        {[], _} -> lists:reverse(Rows);
        _ -> lists:reverse([unicode:characters_to_binary(lists:reverse(Current)) | Rows])
    end;
wrap_clusters([Cluster | Rest] = Clusters, Width, Used, Current, Rows) ->
    Size = cluster_width(Cluster),
    case Used + Size > Width andalso Current =/= [] of
        true ->
            Row = unicode:characters_to_binary(lists:reverse(Current)),
            wrap_clusters(Clusters, Width, 0, [], [Row | Rows]);
        false -> wrap_clusters(Rest, Width, Used + Size, [Cluster | Current], Rows)
    end.

%% Fit grapheme clusters rather than slicing UTF-8 bytes. Wide CJK characters,
%% emoji and joined emoji occupy two cells; combining marks stay with their base.
%% Terminal fonts may differ for ambiguous-width characters, treated here as one.
fit(_Text, Width) when Width =< 0 -> <<>>;
fit(Text, Width) ->
    Clusters = string:to_graphemes(unicode:characters_to_list(Text)),
    Size = lists:sum([cluster_width(C) || C <- Clusters]),
    case Size =< Width of
        true -> unicode:characters_to_binary([Text, lists:duplicate(Width - Size, $\s)]);
        false ->
            {Kept, Used} = take_cells(Clusters, Width - 1, [], 0),
            unicode:characters_to_binary([lists:reverse(Kept), "…", lists:duplicate(Width - 1 - Used, $\s)])
    end.

cells(Text) -> lists:sum([cluster_width(C) || C <- string:to_graphemes(unicode:characters_to_list(Text))]).
take_cells([], _, Acc, Used) -> {Acc, Used};
take_cells([C | Rest], Remaining, Acc, Used) ->
    W = cluster_width(C),
    case W =< Remaining of
        true -> take_cells(Rest, Remaining - W, [C | Acc], Used + W);
        false -> {Acc, Used}
    end.
cluster_width(C) when is_integer(C) -> code_width(C);
cluster_width(Cs) ->
    case lists:member(16#FE0F, Cs) of
        true -> 2;
        false -> lists:max([0 | [code_width(C) || C <- Cs]])
    end.
code_width(C) when C =:= 16#200D; C >= 16#300, C =< 16#36F;
                   C >= 16#FE00, C =< 16#FE0F -> 0;
code_width(C) when C >= 16#1100, C =< 16#115F;
                   C >= 16#2329, C =< 16#232A;
                   C >= 16#2E80, C =< 16#A4CF;
                   C >= 16#AC00, C =< 16#D7A3;
                   C >= 16#F900, C =< 16#FAFF;
                   C >= 16#FE10, C =< 16#FE6F;
                   C >= 16#FF00, C =< 16#FF60;
                   C >= 16#FFE0, C =< 16#FFE6;
                   C >= 16#1F1E6, C =< 16#1FAFF;
                   C >= 16#20000, C =< 16#3FFFD -> 2;
code_width(_) -> 1.

%% A snapshot's control bytes are data, never instructions for the terminal.
visible(Text) -> unicode:characters_to_binary([visible_char(C) || C <- unicode:characters_to_list(Text)]).
visible_char(27) -> "\\x1b";
visible_char(0) -> "\\0";
visible_char(8) -> "\\b";
visible_char(9) -> "⇥   ";
visible_char(10) -> "␊";
visible_char(13) -> "␍";
visible_char(C) when C < 32; C >= 127, C =< 159;
                     C >= 16#202A, C =< 16#202E;
                     C >= 16#2066, C =< 16#2069 -> io_lib:format("\\u{~.16b}", [C]);
visible_char(C) -> [C].

%% Keep the compiler's existing assertion protocol. Poke adds a public data
%% representation when a caller captures a failure, not a new runner protocol.
mismatch(Message, Expected, Actual) ->
    erlang:error({pooka_assert_values, Message, Expected, Actual}).

capture_failure(Run) ->
    try {ok, Run()}
    catch
        error:{pooka_assert_values, Message, Expected, Actual} ->
            {error, {<<"comparison">>, Message, {some, pretty(Expected)}, {some, pretty(Actual)}}};
        error:{pooka_assert_values, Message, Expected, Actual, _, _} ->
            {error, {<<"comparison">>, Message, {some, pretty(Expected)}, {some, pretty(Actual)}}};
        error:{pooka_assert, Message} -> assertion_failure(Message);
        error:{pooka_assert, Message, _, _} -> assertion_failure(Message);
        error:{pooka_panic, Message} -> panic_failure(Message);
        error:{pooka_panic, Message, _, _} -> panic_failure(Message);
        Class:Reason ->
            {error, {<<"exception">>, iolist_to_binary([atom_to_list(Class), ": ", pretty(Reason)]), none, none}}
    end.

assertion_failure(Message) -> {error, {<<"assertion">>, Message, none, none}}.
panic_failure(Message) -> {error, {<<"panic">>, Message, none, none}}.
pretty(Value) -> poke_pretty_ffi:format(Value, 80, 2, 0, 0).
