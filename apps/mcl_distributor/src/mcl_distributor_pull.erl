%%%-------------------------------------------------------------------
%%% @doc The `<org>/group_keys_v1' handler, in the `{Module, Function}'
%%% shape mcl_om's capabilities advertise: forwards the pull to the live
%%% distributor by its registered name.
%%%
%%% The UCAN policy and the sealed-only channel are enforced by the link
%%% BEFORE this handler runs (the capability's `auth' and `confidential'
%%% fields), so the handler itself decides only membership and epochs,
%%% exactly as macula_group_keys documents.
%%% @end
%%%-------------------------------------------------------------------
-module(mcl_distributor_pull).

-export([pull/1]).

-spec pull(map()) -> map() | {error, atom()}.
pull(Payload) ->
    Handler = macula_group_keys:handler(whereis(mcl_distributor)),
    Handler(Payload).
