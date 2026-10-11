%%%-------------------------------------------------------------------
%%% @doc The service contract, and the pull handler forwarding to a live
%%% distributor. The seal machinery itself is macula's, tested there;
%%% this suite pins THIS service's wiring: the six callbacks, the
%%% capability's sealed-only shape, the env refusals, and the
%%% `{Module, Function}' handler reaching a registered distributor.
%%% @end
%%%-------------------------------------------------------------------
-module(mcl_distributor_service_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ORG, <<"acme">>).
-define(ORG_KEY_ID_HEX, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff").
-define(PREFIX, <<"io.macula/acme/chat">>).

%%------------------------------------------------------------------
%% The six callbacks have the contract's shape
%%------------------------------------------------------------------

info_names_the_service_test() ->
    Info = mcl_distributor_service:info(),
    ?assertEqual(<<"mcl-distributor">>, maps:get(name, Info)),
    ?assert(is_binary(maps:get(version, Info))),
    ?assert(is_binary(maps:get(description, Info))).

capabilities_are_the_one_group_keys_v1_test() ->
    {ok, Env} = save_env(),
    try
        true = os:putenv("MCL_GROUP_ORG_KEY_ID", ?ORG_KEY_ID_HEX),
        [Cap] = mcl_distributor_service:capabilities(),
        ?assertEqual(<<"group_keys_v1">>, maps:get(name, Cap)),
        ?assertEqual({mcl_distributor_pull, []}, maps:get(handler, Cap)),
        ?assertEqual(required, maps:get(confidential, Cap)),
        {realm_member_required, OrgKeyId, <<"group_keys">>} = maps:get(auth, Cap),
        ?assertEqual(32, byte_size(OrgKeyId))
    after
        restore_env(Env)
    end.

%% The org key id is unknown until the realm mints the org key (it does so
%% only when it issues the provider grant), so a first boot advertises no
%% group capability: the claim lands, the operator admits, and a restart
%% after the env is filled registers it. Advertising it without the key id
%% would mean an `open' group_keys_v1, which admits any realm member.
capabilities_are_empty_until_the_org_key_id_is_known_test() ->
    {ok, Env} = save_env(),
    try
        true = os:unsetenv("MCL_GROUP_ORG_KEY_ID"),
        ?assertEqual([], mcl_distributor_service:capabilities())
    after
        restore_env(Env)
    end.

identity_spec_is_scoped_and_empty_test() ->
    Spec = mcl_distributor_service:identity_spec(),
    ?assertEqual(<<"mcl-distributor">>, maps:get(scope, Spec)),
    ?assertEqual([], maps:get(actions, Spec)),
    ?assertEqual([], maps:get(resources, Spec)).

%%------------------------------------------------------------------
%% The env refusals are loud at boot, never discovered by callers
%%------------------------------------------------------------------

options_refuse_an_unset_org_test() ->
    {ok, Env} = save_env(),
    try
        true = os:unsetenv("MCL_GROUP_ORG"),
        ?assertError({mcl_distributor, {unset, "MCL_GROUP_ORG"}}, mcl_distributor:options())
    after
        restore_env(Env)
    end.

options_accept_the_deploy_shape_test() ->
    {ok, Env} = save_env(),
    try
        true = os:putenv("MCL_GROUP_ORG", "acme"),
        true = os:putenv("MCL_GROUP_ORG_KEY_ID", ?ORG_KEY_ID_HEX),
        true = os:putenv("MCL_GROUP_REALM_KEY_ID", ?ORG_KEY_ID_HEX),
        true = os:putenv("MCL_REALM", "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"),
        ?assertEqual(?ORG, mcl_distributor:org()),
        ?assertEqual(required, mcl_distributor:policy()),
        ?assertEqual(32, byte_size(mcl_distributor:realm())),
        ?assertEqual(32, byte_size(mcl_distributor:org_key_id()))
    after
        restore_env(Env)
    end.

%%------------------------------------------------------------------
%% The pull handler reaches a live distributor, and health sees it
%%------------------------------------------------------------------

pull_forwards_to_the_registered_distributor_test() ->
    Now = counters:new(1, []),
    counters:put(Now, 1, 1_000_000),
    {ok, Pid} = macula_group_keys:start_link(
                  #{org => ?ORG, policy => required, rotate_after_ms => 15 * 60000,
                    now => fun() -> counters:get(Now, 1) end,
                    membership => fun(_Caller) -> ok end,
                    removed => fun(_Caller) -> false end}),
    true = register(mcl_distributor, Pid),
    try
        ?assertEqual(ok, mcl_distributor_service:health()),
        Payload = #{{text, <<"prefix">>} => {text, ?PREFIX},
                    {text, <<"epoch">>} => {text, <<"current">>},
                    caller => crypto:strong_rand_bytes(32)},
        {ok, _} = mcl_distributor_pull:init([]),
        {reply, Reply, _} = mcl_distributor_pull:handle_request(Payload, undefined),
        ?assertMatch(#{prefix := {text, ?PREFIX}, policy := {text, <<"required">>}, epochs := [_]}, Reply)
    after
        unregister(mcl_distributor),
        gen_server:stop(Pid)
    end.

health_is_down_without_a_distributor_test() ->
    {ok, Env} = save_env(),
    try
        true = os:unsetenv("MCL_GROUP_ORG"),
        catch unregister(mcl_distributor),
        ?assertEqual({down, distributor_not_running}, mcl_distributor_service:health())
    after
        restore_env(Env)
    end.

%%------------------------------------------------------------------
%% Env save/restore, so one suite never leaks into another
%%------------------------------------------------------------------

save_env() ->
    {ok, #{org => os:getenv("MCL_GROUP_ORG"),
           org_key_id => os:getenv("MCL_GROUP_ORG_KEY_ID"),
           realm_key_id => os:getenv("MCL_GROUP_REALM_KEY_ID"),
           realm => os:getenv("MCL_REALM")}}.

restore_env(Env) ->
    restore("MCL_GROUP_ORG", maps:get(org, Env)),
    restore("MCL_GROUP_ORG_KEY_ID", maps:get(org_key_id, Env)),
    restore("MCL_GROUP_REALM_KEY_ID", maps:get(realm_key_id, Env)),
    restore("MCL_REALM", maps:get(realm, Env)),
    ok.

restore(_Name, false) -> ok;
restore(Name, Value) -> os:putenv(Name, Value), ok.
