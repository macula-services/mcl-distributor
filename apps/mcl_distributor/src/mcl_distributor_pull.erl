%%%-------------------------------------------------------------------
%%% @doc The `<org>/group_keys_v1' handler, in macula_response's
%%% per-request `init/1' + `handle_request/2' contract, forwarding every
%%% pull to the live distributor by its registered name.
%%%
%%% The UCAN policy and the sealed-only channel are enforced by the link
%%% BEFORE this handler runs (the capability's `auth' and `confidential'
%%% fields), so the handler itself decides only membership and epochs,
%%% exactly as macula_group_keys documents. A refusal goes back as the
%%% SDK names it, which the link answers as `handler_error' with the name
%%% as its detail. While the distributor is restarting there is no one to
%%% ask, and the pull is refused as `no_distributor', the name a member's
%%% keyring gives a distributor it cannot reach.
%%% @end
%%%-------------------------------------------------------------------
-module(mcl_distributor_pull).

-behaviour(macula_response).

-export([init/1, handle_request/2]).

init(_Args) -> {ok, undefined}.

-spec handle_request(term(), term()) -> {reply, term(), term()} | {error, term(), term()}.
handle_request(Payload, State) ->
    answered(pulled(whereis(mcl_distributor), Payload), State).

pulled(undefined, _Payload) -> {error, no_distributor};
pulled(Distributor, Payload) -> (macula_group_keys:handler(Distributor))(Payload).

answered({error, Reason}, State) when is_atom(Reason) -> {error, Reason, State};
answered(Reply, State) -> {reply, Reply, State}.
