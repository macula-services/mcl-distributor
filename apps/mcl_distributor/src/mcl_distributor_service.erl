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

info() ->
    #{name => <<"mcl-distributor">>,
      version => <<"0.1.0">>,
      description => <<"Distributes a sealed pubsub group's rotating epoch keys to its admitted members over sealed calls">>}.

%% @doc The distributor starts here, after mcl_om's pool: its default
%% membership path reads the realm slot over that pool, so a missing org
%% or realm pin is refused loudly at boot, never discovered by callers.
start(_Opts) ->
    _ = mcl_distributor:options(),
    mcl_distributor_sup:start_link().

stop(_State) -> ok.

%% @doc The service's own health: the distributor process answers. The
%% mesh, the claim and the advertise liveness are mcl_om's own checks,
%% combined into /health by mcl_om_health.
health() ->
    case whereis(mcl_distributor) of
        undefined -> {down, distributor_not_running};
        _Pid      -> ok
    end.

%% WHAT THIS SERVICE ANNOUNCES IT CAN DO. One capability: the org's
%% `group_keys_v1'. On the wire it is `Org/group_keys_v1', the org being
%% deploy config (MCL_GROUP_ORG, the same org mcl_om advertises under).
%%
%% `auth' gates the procedure on the org's `group_keys' UCAN, checked by
%% the link before the handler runs; `confidential => required' makes the
%% link refuse a clear pull, so a key never travels readable by a
%% station. `confidential' refuses to boot while kem_advertise is off
%% (mcl_om's own verdict), which is the flip the fleet must make first.
capabilities() ->
    [#{name => <<"group_keys_v1">>,
       version => 1,
       handler => {mcl_distributor_pull, []},
       auth => {realm_member_required, mcl_distributor:org_key_id(), <<"group_keys">>},
       confidential => required}].

%% THE AUTHORITY THIS SERVICE ASKS THE REALM FOR, and deliberately nothing
%% more. The boot claim covers the org-namespaced procedure above; no
%% topics are published or subscribed.
identity_spec() ->
    #{scope => <<"mcl-distributor">>,
      actions => [],
      resources => [],
      ttl_days => 30}.
