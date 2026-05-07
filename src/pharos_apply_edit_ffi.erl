%% Erlang FFI: apply LSP `TextEdit[]` to a file's bytes.
%%
%% The MCP tool `apply_workspace_edit` (M11.1) reads a `WorkspaceEdit`,
%% groups edits by file URI, and asks this module to splice them into
%% the file's contents. Two concerns live here because they are far
%% easier in Erlang than in Gleam:
%%
%%   1. Position → byte-offset translation. LSP positions are
%%      `(line, character)` where `character` is a UTF-16 code-unit
%%      offset inside the line. We approximate via Unicode code points
%%      — exact for the BMP (covers all real-world source text we have
%%      seen) and off-by-one per emoji / supplementary-plane char in
%%      the unlucky line. Documented in the Gleam-side module.
%%
%%   2. Overlap detection + bottom-up splicing. Edits are sorted in
%%      descending order so applying one never shifts the offsets of
%%      another. Adjacent (touching) edits are allowed; strict overlap
%%      throws.
%%
%% The pure transform is exposed as `apply_text_edits/2`. A combined
%% read + transform + atomic-write entry point is `apply_to_file/3`,
%% with a `dry_run` flag for the safety-default workflow.
%%
%% Returns Gleam-friendly tagged tuples shaped as Result(t, e).

-module(pharos_apply_edit_ffi).
-export([apply_text_edits/2, apply_to_file/3]).

%% Apply a list of text edits to a file at Path.
%%   Edits  — list of {StartLine, StartChar, EndLine, EndChar, NewText}
%%            (zero-based positions, NewText is a binary)
%%   DryRun — atom 'true' or 'false'. When true, do not write; just
%%            compute the would-be result.
%%
%% Returns Gleam-shaped Result(#(OldBytes, NewBytes), ReasonBinary):
%%   {ok, {OldByteCount, NewByteCount}}  — wrote (or would have)
%%   {error, ReasonBinary}               — human-readable error
apply_to_file(Path, Edits, DryRun) when is_binary(Path), is_list(Edits) ->
    case file:read_file(binary_to_list(Path)) of
        {error, Reason} ->
            {error, prefix(<<"read failed: ">>, format_reason(Reason))};
        {ok, Bytes} ->
            OldSize = byte_size(Bytes),
            case apply_text_edits(Bytes, Edits) of
                {ok, NewBytes} ->
                    NewSize = byte_size(NewBytes),
                    case DryRun of
                        true -> {ok, {OldSize, NewSize}};
                        false ->
                            case write_atomic(binary_to_list(Path), NewBytes) of
                                ok -> {ok, {OldSize, NewSize}};
                                {error, R} ->
                                    {error, prefix(<<"write failed: ">>, R)}
                            end
                    end;
                {error, R} -> {error, format_apply_error(R)}
            end
    end.

prefix(Pfx, Bin) -> <<Pfx/binary, Bin/binary>>.

format_apply_error({overlap, E1, E2}) ->
    iolist_to_binary(io_lib:format("overlapping edits: ~p and ~p", [E1, E2]));
format_apply_error({position_out_of_range, E}) ->
    iolist_to_binary(io_lib:format("position past EOF in edit: ~p", [E]));
format_apply_error({inverted_range, E}) ->
    iolist_to_binary(io_lib:format("end before start in edit: ~p", [E]));
format_apply_error({invalid_utf8, E}) ->
    iolist_to_binary(io_lib:format("invalid UTF-8 in line for edit: ~p", [E]));
format_apply_error(Other) ->
    iolist_to_binary(io_lib:format("~p", [Other])).

%% Pure transform: take Bytes (UTF-8 binary) + Edits, return new Bytes.
%% Exposed for tests that want to exercise the splicing logic without
%% disk I/O.
apply_text_edits(Bytes, Edits) when is_binary(Bytes), is_list(Edits) ->
    Index = compute_line_index(Bytes),
    try
        ByteEdits = [edit_to_byte_range(E, Bytes, Index) || E <- Edits],
        check_no_overlap(ByteEdits),
        Sorted = lists:sort(
            fun({SA, _, _}, {SB, _, _}) -> SA > SB end,
            ByteEdits
        ),
        {ok, splice_all(Bytes, Sorted)}
    catch
        %% Throws are tagged tuples of arbitrary arity
        %% (e.g. `{overlap, E1, E2}`, `{position_out_of_range, E}`).
        %% Pattern matches both 2- and 3-tuple shapes by accepting any tuple.
        throw:Reason when is_tuple(Reason) -> {error, Reason}
    end.

%% -- Position indexing ----------------------------------------------------

%% Build a tuple of byte offsets where each line starts. Index 1 is
%% line 0's start (= 0), index 2 is line 1's start (after first \n),
%% etc. The number of lines is byte-counted by counting \n + 1.
compute_line_index(Bytes) ->
    list_to_tuple([0 | line_starts(Bytes, 0, [])]).

line_starts(<<>>, _Pos, Acc) ->
    lists:reverse(Acc);
line_starts(<<$\n, Rest/binary>>, Pos, Acc) ->
    line_starts(Rest, Pos + 1, [Pos + 1 | Acc]);
line_starts(<<_, Rest/binary>>, Pos, Acc) ->
    line_starts(Rest, Pos + 1, Acc).

%% Translate a single TextEdit's (line, character) range to a byte range.
%% Throws {position_out_of_range, Edit} if positions are past EOF.
edit_to_byte_range({SL, SC, EL, EC, NewText} = Edit, Bytes, Index) ->
    StartByte = position_to_byte(SL, SC, Bytes, Index, Edit),
    EndByte = position_to_byte(EL, EC, Bytes, Index, Edit),
    case EndByte >= StartByte of
        true -> {StartByte, EndByte, NewText};
        false -> throw({inverted_range, Edit})
    end.

position_to_byte(Line, Char, Bytes, Index, Edit) ->
    LineStart =
        case Line + 1 =< tuple_size(Index) of
            true -> element(Line + 1, Index);
            false ->
                %% Position past last \n (LSP allows pointing at virtual
                %% trailing line for inserts at EOF). Clamp to EOF when
                %% Char is 0; else throw.
                case Char of
                    0 -> byte_size(Bytes);
                    _ -> throw({position_out_of_range, Edit})
                end
        end,
    %% Slice the line (without trailing \n) and walk Char codepoints.
    LineBin =
        case Line + 2 =< tuple_size(Index) of
            true ->
                NextStart = element(Line + 2, Index),
                %% NextStart - 1 strips the trailing \n.
                Len = NextStart - LineStart - 1,
                binary:part(Bytes, LineStart, Len);
            false ->
                Len = byte_size(Bytes) - LineStart,
                binary:part(Bytes, LineStart, max(Len, 0))
        end,
    LineStart + char_offset_to_bytes(LineBin, Char, Edit).

%% Walk a line's bytes, advancing one Unicode codepoint per Char step.
%% Returns the byte offset within the line at which Char codepoints
%% have been consumed. Char beyond the line clamps to end-of-line —
%% LSP spec says positions past line length should be treated as
%% end-of-line.
char_offset_to_bytes(_Bin, 0, _Edit) -> 0;
char_offset_to_bytes(Bin, Char, Edit) ->
    walk_codepoints(Bin, Char, 0, Edit).

walk_codepoints(_Bin, 0, Offset, _Edit) -> Offset;
walk_codepoints(<<>>, _Remaining, Offset, _Edit) ->
    %% Reached EOL; clamp.
    Offset;
walk_codepoints(<<_/utf8, Rest/binary>> = Bin, Remaining, Offset, Edit) ->
    Consumed = byte_size(Bin) - byte_size(Rest),
    walk_codepoints(Rest, Remaining - 1, Offset + Consumed, Edit);
walk_codepoints(_Bin, _Remaining, _Offset, Edit) ->
    %% Invalid UTF-8 in the line. Bail rather than silently corrupt.
    throw({invalid_utf8, Edit}).

%% -- Overlap detection ----------------------------------------------------

check_no_overlap(ByteEdits) ->
    %% Sort ascending by start; adjacent edits with end == start are OK
    %% (they touch but do not overlap). Strict overlap (E1.end > E2.start)
    %% throws.
    Sorted = lists:sort(fun({A, _, _}, {B, _, _}) -> A =< B end, ByteEdits),
    check_pairs(Sorted).

check_pairs([_]) -> ok;
check_pairs([]) -> ok;
check_pairs([{_, E1End, _} = E1, {S2, _, _} = E2 | Rest]) ->
    case E1End > S2 of
        true -> throw({overlap, E1, E2});
        false -> check_pairs([E2 | Rest])
    end.

%% -- Splicing -------------------------------------------------------------

%% Apply edits to Bytes. Edits MUST be sorted in descending order by
%% start byte so that applying one never shifts another's offsets.
splice_all(Bytes, []) -> Bytes;
splice_all(Bytes, [{S, E, NewText} | Rest]) ->
    Before = binary:part(Bytes, 0, S),
    After = binary:part(Bytes, E, byte_size(Bytes) - E),
    Updated = <<Before/binary, NewText/binary, After/binary>>,
    splice_all(Updated, Rest).

%% -- Atomic write helper --------------------------------------------------

%% Same shape as pharos_fs_ffi:atomic_write_text/2 but takes raw binary
%% (no UTF assumption; writes bytes verbatim) and returns Erlang-style
%% ok / {error, _}.
write_atomic(PathStr, Bytes) ->
    Tmp = PathStr ++ ".tmp",
    case file:write_file(Tmp, Bytes) of
        ok ->
            case file:rename(Tmp, PathStr) of
                ok -> ok;
                {error, Reason} ->
                    file:delete(Tmp),
                    {error, format_reason(Reason)}
            end;
        {error, Reason} -> {error, format_reason(Reason)}
    end.

format_reason(R) when is_binary(R) -> R;
format_reason(R) -> iolist_to_binary(io_lib:format("~p", [R])).
