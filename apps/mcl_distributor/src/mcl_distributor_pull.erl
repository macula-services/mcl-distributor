%%%-------------------------------------------------------------------
%%% @doc The `<org>/group_keys_v1' handler, in macula_response's
%%% per-request `init/1' + `handle_request/2' contract, forwarding every
%%% pull to the live distributor by its registered name.
%%%
%%% The sealed-only channel is enforced by the link BEFORE this handler
%%% runs (`confidential => required'); the CALL's authority is not. The
%%% capability is advertised `auth => handler_authorizes' (macula 17,
%%% macula#129), so the link runs no gate and hands the handler the token
%%% the caller signed and its proofs beside `caller' -- a payload's own
%%% fields of those names dropped first. The SDK's handler checks that
%%% token per group, then the org's removed set, then live realm
%%% membership, so a member the realm has withdrawn is refused here even
%%% while its chain still verifies. A refusal goes back as the SDK names
%%% it -- `{error, Reason}' with an atom for the membership reasons and a
%%% binary `not_authorized: <what it lacked>' for an unadmitted token --
%%% which the link answers as `handler_error' with the name as its detail.
%%% While the distributor is restarting there is no one to ask, and the
%%% pull is refused as `no_distributor', the name a member's keyring gives
%%% a distributor it cannot reach.
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

%% The SDK refuses with an atom (a membership or epoch reason) or with a
%% binary (`not_authorized: <capability> on <resource>'). Both are the
%% handler's own error, never a reply: answered as a reply, the member
%% would take the refusal for a malformed key reply and name it
%% `no_distributor', hiding the reason it was refused.
answered({error, Reason}, State) when is_atom(Reason); is_binary(Reason) ->
    {error, Reason, State};
answered(Reply, State) ->
    {reply, Reply, State}.
