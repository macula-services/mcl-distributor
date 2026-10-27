%%%-------------------------------------------------------------------
%%% @doc The mcl_om service contract for mcl_distributor.
%%%
%%% SIX CALLBACKS, ALL REQUIRED. mcl_om resolves them BY NAME at startup,
%%% so the `-behaviour' attribute turns a missing one into a compile
%%% error. A group-key distributor for one org: it admits members, hands
%%% out the rotating epoch keys over sealed calls, and touches no traffic
%%% itself.
%%% @end
%%%-------------------------------------------------------------------
-module(mcl_distributor_service).

-behaviour(mcl_om_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0]).

%% @doc The service's identity, plus the one setup wait this service has.
%% `org_key_id' reports whether the realm has minted the org key yet, in the
%% `/health' body while the verdict stays `ok': a fresh realm mints it when
%% it issues the provider grant, so `unset' is a normal first-boot state, not
%% a fault, and an operator reads it here instead of in the container log
%% (mcl_om 1.5.0 widens info() for exactly this; mcl-distributor#5).
info() ->
    #{name => <<"mcl-distributor">>,
      version => <<"0.5.0">>,
      description => <<"Distributes a sealed pubsub group's rotating epoch keys to its admitted members over sealed calls">>,
      org_key_id => org_key_state()}.

%% The wait, named: `set' once the operator has filled
%% MCL_GROUP_ORG_KEY_ID. The id itself stays out of /health.
-spec org_key_state() -> set | unset.
org_key_state() ->
    case mcl_distributor:org_key_id() of
        undefined -> unset;
        _KeyId    -> set
    end.

%% @doc The distributor starts here, after mcl_om's pool: its default
%% membership path reads the realm slot over that pool, so a missing org
%% or realm pin is refused loudly at boot, never discovered by callers.
start(_Opts) ->
    _ = mcl_distributor:options(),
    naming_the_wait(mcl_distributor:org_key_id()),
    mcl_distributor_sup:start_link().

%% The org-key wait is a normal setup state (health answers ok for it), so
%% it must still be findable: one notice at boot, and the `group_keys_v1'
%% capability absent from everything the service advertises until it is
%% filled.
naming_the_wait(undefined) ->
    logger:notice("mcl_distributor: serving no group keys yet -- MCL_GROUP_ORG_KEY_ID is unset, "
                  "so no distributor starts and group_keys_v1 is not advertised. The realm mints "
                  "the org key when it issues the provider grant: set the id from the published "
                  "org_directory and restart.");
naming_the_wait(_OrgKeyId) ->
    ok.

stop(_State) -> ok.

%% @doc The service's own health: the distributor process answers. The
%% mesh, the claim and the advertise liveness are mcl_om's own checks,
%% combined into /health by mcl_om_health.
%%
%% A distributor that was never started because the realm still owes the
%% org key is a NORMAL SETUP STATE, not a fault: mcl_om's contract has a
%% service waiting on setup answer ok and name what is missing, and a
%% fresh realm's first boot must never fail a canary. So the wait answers
%% ok; the boot notice (below) and the absent `group_keys_v1' in the
%% advertisement are how an operator finds it. With the org key id known,
%% a missing distributor is a genuine `down'.
health() ->
    case whereis(mcl_distributor) of
        undefined -> not_running(mcl_distributor:org_key_id());
        _Pid      -> ok
    end.

not_running(undefined) -> ok;
not_running(_OrgKeyId) -> {down, distributor_not_running}.

%% WHAT THIS SERVICE ANNOUNCES IT CAN DO. One capability: the org's
%% `group_keys_v1'. On the wire it is `Org/group_keys_v1', the org being
%% deploy config (MCL_GROUP_ORG, the same org mcl_om advertises under).
%%
%% The capability is omitted until the org's key id is known: the realm
%% mints the org key only when it issues the provider grant, so a first
%% boot advertises everything else, files the claim, and a restart after
%% MCL_GROUP_ORG_KEY_ID is filled (from the published org_directory)
%% registers this one.
%%
%% The SDK's advertise_opts/0 supplies `auth => handler_authorizes', which
%% runs no gate at the link and hands the handler the call's token and
%% proofs, and `confidential => required', which makes the link refuse a
%% clear pull, so a key never travels readable by a station. The gate
%% cannot make this check any more: the group a pull names travels inside
%% the sealed payload, where no gate sees it (macula#129), so the handler
%% decides (mcl_distributor_pull).
capabilities() ->
    case mcl_distributor:org_key_id() of
        undefined ->
            [];
        _OrgKeyId ->
            [maps:merge(#{name => <<"group_keys_v1">>,
                          version => 1,
                          handler => {mcl_distributor_pull, []}},
                        macula_group_keys:advertise_opts())]
    end.

%% THE AUTHORITY THIS SERVICE ASKS THE REALM FOR, and deliberately nothing
%% more. The boot claim covers the org-namespaced procedure above; no
%% topics are published or subscribed.
identity_spec() ->
    #{scope => <<"mcl-distributor">>,
      actions => [],
      resources => [],
      ttl_days => 30}.
