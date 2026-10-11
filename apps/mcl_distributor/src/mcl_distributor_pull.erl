%%%-------------------------------------------------------------------
%%% @doc The `<org>/group_keys_v1' handler, in macula_response's
%%% per-request `init/1' + `handle_request/2' contract, forwarding every
%%% pull to the live distributor by its registered name.
%%%
%%% The UCAN policy and the sealed-only channel are enforced by the link
%%% BEFORE this handler runs (the capability's `auth' and `confidential'
%%% fields), so the handler itself decides only membership and epochs,
%%% exactly as macula_group_keys documents.
%%% @end
%%%-------------------------------------------------------------------
-module(mcl_distributor_pull).

-behaviour(macula_response).

-export([init/1, handle_request/2]).

init(_Args) -> {ok, undefined}.

-spec handle_request(term(), term()) -> {reply, term(), term()} | {error, term(), term()}.
handle_request(Payload, State) ->
    Handler = macula_group_keys:handler(whereis(mcl_distributor)),
    case Handler(Payload) of
        {error, Reason} = Refusal when is_atom(Reason) -> {error, Refusal, State};
        Reply                                          -> {reply, Reply, State}
    end.
