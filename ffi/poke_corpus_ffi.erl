%% SPDX-License-Identifier: Apache-2.0

%%% Store encoded values as data, never as executable Erlang terms. The caller's
%%% codec owns validation. File names are hashes, so equal failures share a home.
-module(poke_corpus_ffi).
-export([load/2, save/3]).
-include_lib("kernel/include/file.hrl").

load(Directory, Name) ->
    case property_directory(Directory, Name) of
        {error, _} = Error -> Error;
        {ok, Path} ->
            case file:list_dir(Path) of
                {error, enoent} -> {ok, []};
                {error, Why} -> failure(Why);
                {ok, Names} -> read_cases(Path, lists:sort(Names), [])
            end
    end.

read_cases(_, [], Acc) -> {ok, lists:reverse(Acc)};
read_cases(Path, [Name | Rest], Acc) ->
    case filename:extension(Name) of
        Extension when Extension =:= <<".case">>; Extension =:= ".case" ->
            File = filename:join(Path, Name),
            case file:read_link_info(File) of
                {ok, #file_info{type = regular}} ->
                    case file:read_file(File) of
                        {ok, Text} ->
                            case unicode:characters_to_binary(Text) of
                                Text when is_binary(Text) -> read_cases(Path, Rest, [Text | Acc]);
                                _ -> {error, <<"counterexample is not UTF-8">>}
                            end;
                        {error, Why} -> failure(Why)
                    end;
                {ok, _} -> {error, <<"counterexample must be a regular file">>};
                {error, Why} -> failure(Why)
            end;
        _ -> read_cases(Path, Rest, Acc)
    end.

save(Directory, Name, Text) ->
    case property_directory(Directory, Name) of
        {error, _} = Error -> Error;
        {ok, Path} ->
            Hash = binary:encode_hex(crypto:hash(sha256, Text)),
            File = filename:join(Path, <<Hash/binary, ".case">>),
            case filelib:ensure_dir(File) of
                ok ->
                    case file:read_file(File) of
                        {ok, Text} -> {ok, nil};
                        {ok, _} -> {error, <<"counterexample hash collision">>};
                        {error, enoent} -> save_atomic(File, Text);
                        {error, Why} -> failure(Why)
                    end;
                {error, Why} -> failure(Why)
            end
    end.

%% On hosts where rename will not replace a concurrently saved destination,
%% accept only the exact same bytes. Other failures stay visible to the caller.
save_atomic(File, Text) ->
    case poke_ffi:write_atomic(File, Text) of
        {ok, nil} = Ok -> Ok;
        {error, _} = Error ->
            case file:read_file(File) of {ok, Text} -> {ok, nil}; _ -> Error end
    end.

property_directory(Directory, Name) when byte_size(Name) > 0, byte_size(Name) =< 120 ->
    case lists:all(fun(C) ->
        (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse
        (C >= $0 andalso C =< $9) orelse C =:= $- orelse C =:= $_
    end, binary_to_list(Name)) of
        true -> {ok, filename:join(Directory, Name)};
        false -> {error, <<"property names need ASCII letters, digits, '-' or '_'">>}
    end;
property_directory(_, _) -> {error, <<"property names need 1-120 safe characters">>}.

failure(Why) -> {error, unicode:characters_to_binary(file:format_error(Why))}.
