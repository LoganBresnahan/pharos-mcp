%% #47: positions for a server whose columns aren't UTF-16 code units,
%% LSP's default and the only encoding pharos negotiates (ruby-lsp counts
%% UTF-8 bytes; terraform-ls returns code points).
%%
%% Walking a decoded JSON term to convert every {line, character} against
%% the line text of the document it belongs to is a recursive rewrite of
%% maps and lists with per-call caching of file lines; Gleam's typed
%% decoders can't rebuild an arbitrary JSON tree. Kept here, in one place.
%%
%% Encodings are recorded per LSP proc in an ETS table, keyed by the
%% proc's pid: {Pid, Sent, Returned}, each utf16 | utf8 | utf32.

-module(pharos_position_ffi).
-export([init/0, register/3, forget/1, lookup/1, translate/4, encode/1]).

-define(TABLE, pharos_position_encodings).

init() ->
    case ets:info(?TABLE) of
        undefined -> ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]);
        _ -> ok
    end,
    nil.

%% The table is made at boot by a long-lived process (init/0); one made
%% here would die with the spawn worker that registers.
register(Pid, Sent, Returned) ->
    case {Sent, Returned} of
        {utf16, utf16} -> catch ets:delete(?TABLE, Pid);
        _ -> catch ets:insert(?TABLE, {Pid, Sent, Returned})
    end,
    nil.

forget(Pid) ->
    catch ets:delete(?TABLE, Pid),
    nil.

%% {Sent, Returned}; {utf16, utf16} when nothing is recorded.
lookup(Pid) ->
    try ets:lookup(?TABLE, Pid) of
        [{_, S, R}] -> {S, R};
        [] -> {utf16, utf16}
    catch _:_ -> {utf16, utf16}
    end.

%% translate(Term, DefaultUri, to_server | from_server, Enc): Term with
%% every position's `character` converted. A position's document is the
%% nearest enclosing `uri` / `targetUri` / `textDocument.uri`, or the key
%% under a WorkspaceEdit's `changes`, else DefaultUri. A position past its
%% line's end, or on a line the file doesn't have, is left as it is.
translate(Term, _DefaultUri, _Dir, utf16) -> Term;
translate(Term, DefaultUri, Dir, Enc) ->
    put(pharos_position_lines, #{}),
    try walk(Term, DefaultUri, Dir, Enc)
    after erase(pharos_position_lines)
    end.

walk(M, Uri, Dir, Enc) when is_map(M) ->
    case M of
        #{<<"line">> := L, <<"character">> := C} when is_integer(L), is_integer(C), map_size(M) =:= 2 ->
            M#{<<"character">> => convert(Uri, L, C, Dir, Enc)};
        _ ->
            Own = own_uri(M, Uri),
            maps:map(fun(K, V) -> walk_field(K, V, M, Own, Uri, Dir, Enc) end, M)
    end;
walk(L, Uri, Dir, Enc) when is_list(L) ->
    [walk(X, Uri, Dir, Enc) || X <- L];
walk(X, _, _, _) ->
    X.

%% A LocationLink's origin range is in the requesting document; its target
%% ranges in targetUri's. A WorkspaceEdit's `changes` is keyed by uri. An
%% incoming call's fromRanges are in its caller's document, `from.uri`.
walk_field(<<"originSelectionRange">>, V, _M, _Own, Parent, Dir, Enc) ->
    walk(V, Parent, Dir, Enc);
walk_field(<<"fromRanges">>, V, #{<<"from">> := #{<<"uri">> := U}}, _Own, _Parent, Dir, Enc)
  when is_binary(U) ->
    walk(V, U, Dir, Enc);
walk_field(<<"changes">>, V, _M, _Own, _Parent, Dir, Enc) when is_map(V) ->
    maps:map(fun(DocUri, Edits) -> walk(Edits, DocUri, Dir, Enc) end, V);
walk_field(_K, V, _M, Own, _Parent, Dir, Enc) ->
    walk(V, Own, Dir, Enc).

own_uri(M, Default) ->
    case M of
        #{<<"targetUri">> := U} when is_binary(U) -> U;
        #{<<"uri">> := U} when is_binary(U) -> U;
        #{<<"textDocument">> := #{<<"uri">> := U}} when is_binary(U) -> U;
        _ -> Default
    end.

convert(Uri, L, C, Dir, Enc) ->
    case convert_opt(Uri, L, C, Dir, Enc) of
        {ok, C2} -> C2;
        pass -> C
    end.

%% {ok, Converted}, or pass: past the line's end or no such line.
convert_opt(Uri, L, C, Dir, Enc) ->
    case line_of(Uri, L) of
        {ok, Cps} ->
            {From, To} = case Dir of
                to_server -> {utf16, Enc};
                from_server -> {Enc, utf16}
            end,
            count(Cps, C, From, To, 0, 0);
        error ->
            pass
    end.

%% Walk the line's code points until `From` units reach C; answer the
%% same prefix in `To` units. A C that falls inside a code point (invalid
%% input) answers the position after that code point.
count(_Cps, C, _From, _To, FromAcc, ToAcc) when FromAcc >= C ->
    {ok, ToAcc};
count([], _C, _From, _To, _FromAcc, _ToAcc) ->
    pass;
count([Cp | Rest], C, From, To, FromAcc, ToAcc) ->
    count(Rest, C, From, To, FromAcc + units(From, Cp), ToAcc + units(To, Cp)).

units(utf16, Cp) when Cp > 16#FFFF -> 2;
units(utf16, _) -> 1;
units(utf32, _) -> 1;
units(utf8, Cp) when Cp < 16#80 -> 1;
units(utf8, Cp) when Cp < 16#800 -> 2;
units(utf8, Cp) when Cp < 16#10000 -> 3;
units(utf8, _) -> 4.

%% The code points of line L (0-based) of the file `Uri` names, as on
%% disk (the text pharos last synced, which follows the disk, ADR-038).
line_of(Uri, L) ->
    Cache = get(pharos_position_lines),
    Lines = case maps:find(Uri, Cache) of
        {ok, Ls} -> Ls;
        error ->
            Ls = read_lines(Uri),
            put(pharos_position_lines, Cache#{Uri => Ls}),
            Ls
    end,
    case Lines of
        error -> error;
        _ when L >= 0, L < tuple_size(Lines) ->
            case unicode:characters_to_list(element(L + 1, Lines)) of
                Cps when is_list(Cps) -> {ok, Cps};
                _ -> error
            end;
        _ -> error
    end.

read_lines(Uri) ->
    try 'pharos@workspace_root':uri_to_path(Uri) of
        {ok, Path} ->
            case file:read_file(Path) of
                {ok, Bin} -> list_to_tuple(binary:split(Bin, [<<"\r\n">>, <<"\n">>, <<"\r">>], [global]));
                _ -> error
            end;
        _ -> error
    catch _:_ -> error
    end.

%% A decoded JSON term back to JSON text.
encode(Term) ->
    iolist_to_binary(json:encode(Term)).
