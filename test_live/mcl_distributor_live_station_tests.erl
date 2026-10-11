%% @doc Live end-to-end walking skeleton: THIS service, booted as it deploys
%% (env-driven, a real mcl_om identity and pool), against a real PQ-fleet
%% station. A member pulls group keys over a sealed call with the org's
%% `group_keys' UCAN, and a group-sealed publication crosses the fleet
%% station from one member to another.
%%
%% Lives in test_live/, NOT test/ — excluded from CI's main gate on purpose
%% (the fleet station is disposable dev infra; a blip must never block an
%% unrelated PR). Run explicitly:
%%   rebar3 as live_test eunit --dir test_live --module=mcl_distributor_live_station_tests
%%
%% Realm AND org are unique per run: the fleet station's DHT keeps TTL'd
%% records, so a fixed (realm, org) pair would collide with the previous
%% run's org_directory and fail resolution with org_directory_wrong_realm.
%% The realm must still be NAME-derived (sha256 of a canonical name), or
%% the group_keys UCAN's realm check refuses every token as wrong_realm.
%%
%% The boot advertise runs before the D25 chain exists (the delegation must
%% name the node id the boot itself mints), so the test publishes the chain
%% after boot and waits for the republish tick to carry the advertisement.
-module(mcl_distributor_live_station_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SEED_HOST, <<"station-fi-helsinki.macula.io">>).
-define(SEED_PORT, 4433).
-define(SEED_NODE_ID, <<16#004d1f470097ccf8826ce291900e882fdb1f20375e53901facaec0f23eb4efd8:256>>).
-define(MARKER, <<"walking-skeleton-marker">>).

the_service_serves_group_keys_and_a_sealed_publication_crosses_the_fleet_test_() ->
    {timeout, 300, fun run/0}.

run() ->
    {ok, _} = application:ensure_all_started(macula),
    Suffix = string:lowercase(binary:encode_hex(crypto:strong_rand_bytes(6))),
    RealmName = <<"test-", Suffix/binary>>,
    Realm = crypto:hash(sha256, RealmName),
    Org = <<"acme-", Suffix/binary>>,
    GroupProc = <<Org/binary, "/group_keys_v1">>,
    Prefix = <<RealmName/binary, "/", Org/binary, "/chat">>,
    Topic = <<Prefix/binary, "/fact_v1">>,
    {RealmKey, OrgKey} = realm_and_org_keys(),
    Previous = install_env(Realm, RealmKey, OrgKey, Org),
    try
        ok = application:set_env(mcl_om, realm, binary:encode_hex(Realm)),
        ok = application:set_env(mcl_om, realm_key,
                                 binary:encode_hex(macula_node_keys:public_key(RealmKey))),
        ok = application:set_env(mcl_om, org, Org),
        {ok, _} = application:ensure_all_started(mcl_distributor),

        %% The service's own identity, minted at boot: the delegation names it.
        {ok, ServiceKey} = mcl_om:identity_key(),
        {ok, ServiceNode} = macula_node_keys:node_id(ServiceKey),

        %% Two genuinely separate member identities, as in any deployment.
        PublisherKp = identity_key(),
        SubscriberKp = identity_key(),
        {ok, Publisher} = member_pool(PublisherKp, Realm, RealmKey),
        {ok, Subscriber} = member_pool(SubscriberKp, Realm, RealmKey),
        ok = wait_healthy(Publisher, 200),
        ok = wait_healthy(Subscriber, 200),

        %% The D25 chain for the capability (realm-signed org_directory,
        %% org-signed delegation naming the SERVICE node), and each member's
        %% realm-signed slot endorsement, which the distributor's default
        %% membership reads on every pull.
        publish_chain(Publisher, Realm, Org, RealmKey, OrgKey, ServiceNode),
        publish_endorsement(Publisher, Realm, RealmKey, PublisherKp),
        publish_endorsement(Publisher, Realm, RealmKey, SubscriberKp),

        %% The advertisement appears on the republish tick after the chain
        %% lands (the boot advertise had nothing to resolve yet).
        _ = wait_advertisement(Publisher, Realm, GroupProc, ServiceNode, 120),

        SubToken = member_token(OrgKey, SubscriberKp, RealmName, GroupProc),
        PubToken = member_token(OrgKey, PublisherKp, RealmName, GroupProc),

        Pull = #{{text, <<"prefix">>} => {text, Prefix},
                 {text, <<"epoch">>} => {text, <<"current">>}},
        {ok, Reply} = macula:call(Publisher, Realm, GroupProc, Pull, 5_000,
                                  #{confidential => required, ucan_token => PubToken}),
        ?assertMatch(#{{text, <<"epochs">>} := [_ | _]}, Reply),

        {ok, SubRef} = macula:subscribe(Subscriber, Realm, Topic, self(),
                                        #{group => Prefix, ucan_token => SubToken}),
        ok = macula:publish(Publisher, Realm, Topic, #{fact => {text, ?MARKER}},
                            #{group => Prefix, ucan_token => PubToken}),
        ?assertMatch({macula_event, SubRef, Topic,
                      #{{text, <<"fact">>} := {text, ?MARKER}}, _},
                     receive_event(SubRef)),
        ok
    after
        cleanup(Previous)
    end.

%%------------------------------------------------------------------
%% Env install/restore: the deploy config the service reads
%%------------------------------------------------------------------

install_env(Realm, RealmKey, OrgKey, Org) ->
    Previous = [{Name, os:getenv(Name)}
                || Name <- ["MCL_GROUP_ORG", "MCL_GROUP_ORG_KEY_ID",
                            "MCL_GROUP_REALM_KEY_ID", "MCL_REALM",
                            "MACULA_STATION_SEEDS", "MACULA_STATION_NODE_IDS"]],
    true = os:putenv("MCL_GROUP_ORG", binary_to_list(Org)),
    true = os:putenv("MCL_GROUP_ORG_KEY_ID",
                     binary_to_list(binary:encode_hex(macula_node_keys:key_id(OrgKey)))),
    true = os:putenv("MCL_GROUP_REALM_KEY_ID",
                     binary_to_list(binary:encode_hex(
                                      macula_node_keys:key_id(macula_node_keys:public_key(RealmKey),
                                                              pq_hybrid)))),
    true = os:putenv("MCL_REALM", binary_to_list(binary:encode_hex(Realm))),
    true = os:putenv("MACULA_STATION_SEEDS", "station-fi-helsinki.macula.io:4433"),
    true = os:putenv("MACULA_STATION_NODE_IDS",
                     binary_to_list(binary:encode_hex(?SEED_NODE_ID))),
    Previous.

cleanup(Previous) ->
    catch application:stop(mcl_distributor),
    catch application:stop(mcl_om),
    catch application:stop(macula),
    [case Value of
         false -> os:unsetenv(Name);
         _     -> os:putenv(Name, Value)
     end || {Name, Value} <- Previous],
    ok.

%%------------------------------------------------------------------
%% Keys, pools, chains (as mcl_om's own live suite)
%%------------------------------------------------------------------

identity_key() ->
    {ok, Key} = macula_node_keys:generate(identity, pq_hybrid,
                                          #{puzzle_difficulty => macula_node_keys:puzzle_difficulty()}),
    Key.

realm_and_org_keys() ->
    {ok, RealmKey} = macula_node_keys:generate(realm, pq_hybrid),
    {ok, OrgKey} = macula_node_keys:generate(org, pq_hybrid),
    {RealmKey, OrgKey}.

member_pool(KeyPair, Realm, RealmKey) ->
    macula_client:connect(seed(), #{node_identity => KeyPair,
                                    realm_trust => #{Realm =>
                                                       macula_node_keys:public_key(RealmKey)}}).

seed() ->
    [#{host => ?SEED_HOST, port => ?SEED_PORT, expected_node_id => ?SEED_NODE_ID}].

wait_healthy(_Pool, 0) ->
    erlang:error(seed_never_healthy);
wait_healthy(Pool, N) ->
    healthy_or_wait(macula_client:status(Pool), Pool, N).

healthy_or_wait({ok, #{healthy_links := H}}, _Pool, _N) when H > 0 ->
    ok;
healthy_or_wait(_Status, Pool, N) ->
    timer:sleep(100),
    wait_healthy(Pool, N - 1).

%% The capability's D25 chain: the realm-signed org_directory and the
%% org-signed procedure_delegation naming the service node id.
publish_chain(Pool, Realm, Org, RealmKey, OrgKey, ServiceNode) ->
    OrgKeyId = macula_node_keys:key_id(OrgKey),
    OrgDir = macula_record:sign(
               macula_record:org_directory(Realm, Org, OrgKeyId), RealmKey),
    Deleg = macula_record:sign(
              macula_record:procedure_delegation(OrgKeyId, ServiceNode), OrgKey),
    ok = macula:put_record(Pool, macula_record:encode(OrgDir)),
    ok = macula:put_record(Pool, macula_record:encode(Deleg)).

%% The member's realm slot: a realm-signed realm_member_endorsement, which
%% the distributor's default membership verifies on every pull.
publish_endorsement(Pool, Realm, RealmKey, MemberKey) ->
    {ok, MemberNode} = macula_node_keys:node_id(MemberKey),
    Endorsement = macula_record:sign(
                    macula_record:realm_member_endorsement(
                      Realm, #{realm => Realm, member_node => MemberNode,
                               roles => [<<"peer">>]}),
                    RealmKey),
    ok = macula:put_record(Pool, macula_record:encode(Endorsement)).

wait_advertisement(_Pool, _Realm, _GroupProc, _ServiceNode, 0) ->
    %% The service's own view, dumped into the failure so a silent
    %% advertise loop cannot hide: what it thinks it serves, what the
    %% realm granted, and whether the loop process is even alive.
    erlang:error({advertisement_never_resolved,
                  #{capabilities => catch mcl_om_capabilities:list(),
                    grants => catch mcl_om_capabilities:provider_grants(),
                    caps_alive => erlang:is_process_alive(whereis(mcl_om_capabilities))}});
wait_advertisement(Pool, Realm, GroupProc, ServiceNode, Tries) ->
    case macula:find_records(Pool, macula_record:procedure_key(Realm, GroupProc)) of
        {ok, Recs} ->
            case [R || R <- Recs, maps:get(key_id, R) =:= ServiceNode] of
                [_ | _] -> ok;
                [] ->
                    timer:sleep(1000),
                    wait_advertisement(Pool, Realm, GroupProc, ServiceNode, Tries - 1)
            end;
        {error, _TimeoutOrBusyStation} ->
            timer:sleep(1000),
            wait_advertisement(Pool, Realm, GroupProc, ServiceNode, Tries - 1)
    end.

%% The org's grant to this member: the group_keys capability over the group
%% procedure, in the name-derived test realm.
member_token(OrgKey, MemberKey, RealmName, GroupProc) ->
    {ok, MemberNode} = macula_node_keys:node_id(MemberKey),
    Exp = erlang:system_time(second) + 3600,
    macula_ucan:create(OrgKey, MemberNode,
                       [#{with => <<"mri:proc:", RealmName/binary, "/", GroupProc/binary>>,
                          can => <<"group_keys">>}],
                       #{exp => Exp}).

receive_event(SubRef) ->
    receive {macula_event, SubRef, _, _, _} = Event -> Event
    after 10_000 -> erlang:error({no_event, SubRef})
    end.
