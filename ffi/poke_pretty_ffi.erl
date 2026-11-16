%% SPDX-License-Identifier: Apache-2.0

%%% Lay a Pooka value out as plain text.
%%%
%%% The work is done in two steps. First the value becomes a small document
%%% tree: leaves of text, and groups with an opening, some children and a
%%% closing. Each node knows how wide it would be on one line. Then the tree
%%% is printed: a group that fits in the space left goes on one line, and a
%%% group that does not puts each child on a line of its own.
%%%
%%% This module reads Pooka's runtime representation of values, which is not
%%% a public contract. Unknown shapes are still printed as Erlang values;
%%% the Pooka tests exercise the supported runtime shapes.
-module(poke_pretty_ffi).

-export([format/5, terminal_width/0, write/1]).

-record(opts, {max_items, max_depth}).

%% format(Value, Width, Indent, MaxItems, MaxDepth) -> binary()
format(Value, Width, Indent, MaxItems, MaxDepth) ->
    Opts = #opts{max_items = MaxItems, max_depth = MaxDepth},
    Doc = doc(Value, 1, Opts),
    unicode:characters_to_binary(render(Doc, 0, 0, 0, max(Width, 1), max(Indent, 0))).

%% The terminal's width, or 80 when output is going somewhere else.
terminal_width() ->
    case io:columns() of
        {ok, Columns} -> Columns;
        _ -> 80
    end.

write(Text) ->
    io:put_chars([Text, $\n]),
    nil.

%% --- printing the tree --------------------------------------------------------

%% render(Doc, Indent, Column, Trailing, Width, Step)
%% `Trailing` is the room needed after this node on its last line, for a comma.
render({text, Text, _}, _, _, _, _, _) ->
    Text;
render({group, Open, _, Children, Close, _, Flat}, _, Column, Trailing, Width, _)
  when Column + Flat + Trailing =< Width; Children =:= [] ->
    [Open, lists:join(", ", [flat(Child) || Child <- Children]), Close];
render({group, Open, _, Children, Close, _, _}, Indent, _, _, Width, Step) ->
    Inner = Indent + Step,
    [Open, $\n, lines(Children, Inner, Width, Step), pad(Indent), Close].

lines([Last], Inner, Width, Step) ->
    [pad(Inner), render(Last, Inner, Inner, 0, Width, Step), $\n];
lines([Child | Rest], Inner, Width, Step) ->
    [pad(Inner), render(Child, Inner, Inner, 1, Width, Step), ",\n" | lines(Rest, Inner, Width, Step)].

flat({text, Text, _}) -> Text;
flat({group, Open, _, Children, Close, _, _}) ->
    [Open, lists:join(", ", [flat(Child) || Child <- Children]), Close].

pad(Count) -> lists:duplicate(Count, $\s).

%% --- building the tree --------------------------------------------------------

text(Kind, Plain, Opts) ->
    {text, paint(Kind, Plain, Opts), string:length(Plain)}.

group(Open, Children, Close) ->
    {text, OpenText, OpenWidth} = Open,
    {text, CloseText, CloseWidth} = Close,
    Separators = 2 * max(length(Children) - 1, 0),
    Flat = OpenWidth + CloseWidth + Separators + lists:sum([width(Child) || Child <- Children]),
    {group, OpenText, OpenWidth, Children, CloseText, CloseWidth, Flat}.

width({text, _, Width}) -> Width;
width({group, _, _, _, _, _, Flat}) -> Flat.

%% A name, an opening bracket, and their closing bracket.
named(Name, Bracket, Children, Closing, Opts) ->
    {text, NameText, NameWidth} = text(name, Name, Opts),
    {text, BracketText, BracketWidth} = text(mark, Bracket, Opts),
    group({text, [NameText, BracketText], NameWidth + BracketWidth}, Children, text(mark, Closing, Opts)).

doc(_, Depth, #opts{max_depth = Max} = Opts) when Max > 0, Depth > Max ->
    text(mark, "...", Opts);
doc(true, _, Opts) -> text(word, "True", Opts);
doc(false, _, Opts) -> text(word, "False", Opts);
doc(nil, _, Opts) -> text(word, "Nil", Opts);
doc(none, _, Opts) -> text(word, "None", Opts);
doc({ok, Value}, Depth, Opts) -> named("Ok", "(", [doc(Value, Depth + 1, Opts)], ")", Opts);
doc({error, Value}, Depth, Opts) -> named("Error", "(", [doc(Value, Depth + 1, Opts)], ")", Opts);
doc({some, Value}, Depth, Opts) -> named("Some", "(", [doc(Value, Depth + 1, Opts)], ")", Opts);
doc(Value, _, Opts) when is_integer(Value) -> text(number, integer_to_list(Value), Opts);
doc(Value, _, Opts) when is_float(Value) -> text(number, float_to_list(Value, [short]), Opts);
doc(Value, _, Opts) when is_binary(Value) ->
    case printable(Value) of
        {true, Characters} -> text(string, [$", [escape(C) || C <- Characters], $"], Opts);
        false -> bytes(Value, Opts)
    end;
doc(Value, _, Opts) when is_bitstring(Value) -> text(number, io_lib:format("~tp", [Value]), Opts);
doc(Value, Depth, Opts) when is_list(Value) ->
    group(text(mark, "[", Opts), items(Value, Depth, Opts), text(mark, "]", Opts));
doc({'$pooka_actor', _, Name, Pid}, _, Opts) ->
    named(atom_to_list(Name), "(", [text(faint, pid_to_list(Pid), Opts)], ")", Opts);
doc(Value, Depth, Opts) when is_tuple(Value) ->
    case class_name(Value) of
        {ok, Module, Name} -> object(Value, Module, Name, Depth, Opts);
        error ->
            group(text(mark, "#(", Opts), [doc(V, Depth + 1, Opts) || V <- tuple_to_list(Value)], text(mark, ")", Opts))
    end;
doc(Value, Depth, Opts) when is_map(Value) ->
    Entries = [entry(K, V, Depth, Opts) || {K, V} <- lists:sort(maps:to_list(Value))],
    group(text(mark, "#{", Opts), limit(Entries, Opts), text(mark, "}", Opts));
doc(Value, _, Opts) when is_function(Value) ->
    {arity, Arity} = erlang:fun_info(Value, arity),
    text(faint, ["fn(", lists:join(", ", lists:duplicate(Arity, "_")), ") { ... }"], Opts);
doc(Value, _, Opts) when is_atom(Value) -> text(name, atom_to_list(Value), Opts);
doc(Value, _, Opts) -> text(faint, io_lib:format("~tp", [Value]), Opts).

items(List, Depth, Opts) ->
    limit(elements(List, Depth, Opts), Opts).

elements([], _, _) -> [];
elements([Value | Rest], Depth, Opts) when is_list(Rest) ->
    [doc(Value, Depth + 1, Opts) | elements(Rest, Depth, Opts)];
elements([Value | Tail], Depth, Opts) ->
    %% An improper list, which only Erlang code can make.
    {text, TailText, TailWidth} = doc(Tail, Depth + 1, Opts),
    [doc(Value, Depth + 1, Opts), {text, ["..", TailText], TailWidth + 2}].

%% Keep the first few children, and say how many were left out.
limit(Children, #opts{max_items = Max} = Opts) when Max > 0, length(Children) > Max ->
    Hidden = length(Children) - Max,
    lists:sublist(Children, Max) ++ [text(faint, io_lib:format("... ~b more", [Hidden]), Opts)];
limit(Children, _) -> Children.

entry(Key, Value, Depth, Opts) ->
    {text, KeyText, KeyWidth} = flatten(doc(Key, Depth + 1, Opts)),
    {text, Colon, 2} = text(mark, ": ", Opts),
    prefix([KeyText, Colon], KeyWidth + 2, doc(Value, Depth + 1, Opts)).

prefix(Text, Width, {text, Inner, InnerWidth}) -> {text, [Text, Inner], Width + InnerWidth};
prefix(Text, Width, {group, Open, OpenWidth, Children, Close, CloseWidth, Flat}) ->
    {group, [Text, Open], Width + OpenWidth, Children, Close, CloseWidth, Width + Flat}.

flatten({text, _, _} = Text) -> Text;
flatten({group, _, _, _, _, _, Flat} = Group) -> {text, flat(Group), Flat}.

bytes(Value, Opts) ->
    Numbers = [text(number, integer_to_list(Byte), Opts) || Byte <- binary_to_list(Value)],
    group(text(mark, "<<", Opts), limit(Numbers, Opts), text(mark, ">>", Opts)).

printable(Binary) ->
    case unicode:characters_to_list(Binary) of
        Characters when is_list(Characters) ->
            case lists:all(fun(C) -> C >= 32 orelse C =:= 9 orelse C =:= 10 orelse C =:= 13 end, Characters) of
                true -> {true, Characters};
                false -> false
            end;
        _ -> false
    end.

escape($") -> "\\\"";
escape($\\) -> "\\\\";
escape(10) -> "\\n";
escape(13) -> "\\r";
escape(9) -> "\\t";
escape(C) -> [C].

%% --- objects ------------------------------------------------------------------

%% Is this tuple a class instance? Its tag says which class, and where it lives:
%% 'pooka@class@main@Point', or with a '$package/name/' part for a dependency.
class_name(Tuple) when tuple_size(Tuple) >= 1, is_atom(element(1, Tuple)) ->
    case atom_to_list(element(1, Tuple)) of
        "pooka@class@" ++ Rest ->
            case string:split(Rest, "@", trailing) of
                [Module, Name] -> {ok, Module, Name};
                _ -> error
            end;
        _ -> error
    end;
class_name(_) -> error.

object(Value, "$package/pooka_stdlib/pooka/dict", "Dict", Depth, Opts) ->
    collection(Value, 'pooka@pooka_stdlib@pooka@dict', '$class@Dict@to_list', "dict.from_list([", Depth, Opts);
object(Value, "$package/pooka_stdlib/pooka/set", "Set", Depth, Opts) ->
    collection(Value, 'pooka@pooka_stdlib@pooka@set', '$class@Set@to_list', "set.from_list([", Depth, Opts);
object(Value, Module, Name, Depth, Opts) ->
    {Final, Fields} = fields(Value, Module, Name, 0, []),
    named(Final, "(", [doc(Field, Depth + 1, Opts) || Field <- Fields], ")", Opts).

%% Dicts and sets keep their contents behind functions. Ask them politely, and
%% show the answer as the code that would build the same collection.
collection(Value, Module, ToList, Opening, Depth, Opts) ->
    try Module:ToList(Value) of
        Items when is_list(Items) ->
            Sorted = lists:sort(Items),
            {text, Open, OpenWidth} = text(name, Opening, Opts),
            group({text, Open, OpenWidth}, items(Sorted, Depth, Opts), text(name, "])", Opts))
    catch
        _:_ -> text(faint, io_lib:format("~tp", [Value]), Opts)
    end.

%% An object of a subclass is stored as its parent, with the child tucked into
%% the parent's last place. Walk inwards, collecting fields, and keep the name
%% of the innermost class: that is the one the programmer wrote.
fields(Tuple, Module, Name, Inherited, Acc) ->
    [_Tag | Elements] = tuple_to_list(Tuple),
    {Own, Slot} = split(Elements, Module, Name, Inherited),
    Collected = Acc ++ Own,
    case Slot of
        none -> {Name, Collected};
        nil -> {Name, Collected};
        Child ->
            {ok, ChildModule, ChildName} = class_name(Child),
            fields(Child, ChildModule, ChildName, length(Collected), Collected)
    end.

%% Decide whether the last element is a field, or the place kept for a child.
split([], _, _, _) -> {[], none};
split(Elements, Module, Name, Inherited) ->
    Last = lists:last(Elements),
    Front = lists:droplast(Elements),
    Count = length(Elements),
    case constructor_arity(Module, Name) of
        {ok, Arity} when Arity - Inherited =:= Count -> {Elements, none};
        {ok, Arity} when Arity - Inherited =:= Count - 1 ->
            case slot(Last, Module) of
                field -> {Elements, none};
                Slot -> {Front, Slot}
            end;
        _ ->
            %% A constructor written by hand says nothing about the fields.
            %% An empty place is still recognisable; anything else is shown.
            case Last of
                nil -> {Front, nil};
                _ -> {Elements, none}
            end
    end.

%% A child's place holds nothing, or an object of a class from the same module.
%% Anything else is an ordinary field of a class that wrote its own `new`.
slot(nil, _) -> nil;
slot(Value, Module) ->
    case class_name(Value) of
        {ok, Module, _} -> Value;
        _ -> field
    end.

%% The generated constructor takes one argument per field, inherited ones
%% included, unless the class declares `new` itself.
constructor_arity(Module, Name) ->
    Function = list_to_atom("$class@" ++ Name ++ "@new"),
    case beam_module(Module) of
        {ok, Beam} ->
            case [Arity || {F, Arity} <- Beam:module_info(exports), F =:= Function] of
                [Arity] -> {ok, Arity};
                _ -> error
            end;
        error -> error
    end.

%% 'main' in the running package is 'pooka@<package>@main'; the package name
%% is not in the tag, so look for a loaded module with the right ending.
beam_module("$package/" ++ Rest) ->
    Name = "pooka@" ++ lists:flatten(string:replace(Rest, "/", "@", all)),
    loaded(fun(Module) -> Module =:= Name end);
beam_module(Path) ->
    Ending = "@" ++ lists:flatten(string:replace(Path, "/", "@", all)),
    loaded(fun(Module) -> lists:prefix("pooka@", Module) andalso lists:suffix(Ending, Module) end).

loaded(Matches) ->
    case [Module || {Module, _} <- code:all_loaded(), Matches(atom_to_list(Module))] of
        [Module | _] -> {ok, Module};
        [] -> error
    end.

%% Formatting is always plain; the review UI owns diff colours.
paint(_, Plain, _) -> Plain.
