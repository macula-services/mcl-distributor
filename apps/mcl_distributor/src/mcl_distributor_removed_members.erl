%%%-------------------------------------------------------------------
%%% @doc The org's removed set (DESIGN_E2E_SEALED_PUBSUB §3): the node ids
%%% the org has removed from its groups, refused every epoch whatever
%%% their realm membership or their grant says.
%%%
%%% The set is a file on the distributor's persistent volume, so it
%%% survives a restart: a set lost to a restart would re-admit every
%%% removed member whose grant still verifies. One node id per line, 64
%%% hex characters; blank lines and lines starting with `#' are ignored.
%%% The operator adds a line to remove a member.
%%%
%%% The file is read at every pull, so a removal takes effect at the next
%%% pull, without a restart. A missing file is an empty set (a fresh
%%% volume). A file that cannot be read or holds a malformed line refuses
%%% EVERY caller: a removal the distributor cannot read must not admit the
%%% member it names. The same file is checked at boot, so a malformed one
%%% stops the service before it serves anyone.
%%% @end
%%%-------------------------------------------------------------------
-module(mcl_distributor_removed_members).

-export([removed/2, read/1]).

%% @doc Whether `Caller' is in the removed set at `Path'; `true' too when
%% the set cannot be read.
-spec removed(file:filename_all(), <<_:256>>) -> boolean().
removed(Path, Caller) ->
    in_set(read(Path), Caller).

in_set({ok, Removed}, Caller) -> lists:member(Caller, Removed);
in_set({error, _Unreadable}, _Caller) -> true.

%% @doc The node ids in the removed set at `Path'.
-spec read(file:filename_all()) ->
          {ok, [<<_:256>>]} | {error, {malformed_line, pos_integer()} | file:posix() | badarg | terminated | system_limit}.
read(Path) ->
    contents(file:read_file(Path)).

contents({ok, Bin}) ->
    node_ids(binary:split(Bin, [<<"\n">>, <<"\r\n">>], [global]), 1, []);
contents({error, enoent}) ->
    {ok, []};
contents({error, _} = Unreadable) ->
    Unreadable.

node_ids([], _LineNo, Acc) ->
    {ok, lists:reverse(Acc)};
node_ids([Line | Rest], LineNo, Acc) ->
    line(string:trim(Line), Rest, LineNo, Acc).

line(<<>>, Rest, LineNo, Acc) ->
    node_ids(Rest, LineNo + 1, Acc);
line(<<"#", _Comment/binary>>, Rest, LineNo, Acc) ->
    node_ids(Rest, LineNo + 1, Acc);
line(Hex, Rest, LineNo, Acc) ->
    decoded(mcl_distributor:node_id(Hex), Rest, LineNo, Acc).

decoded({ok, NodeId}, Rest, LineNo, Acc) -> node_ids(Rest, LineNo + 1, [NodeId | Acc]);
decoded(error, _Rest, LineNo, _Acc) -> {error, {malformed_line, LineNo}}.
