%%%-------------------------------------------------------------------
%%% @doc The service contract, and the pull handler forwarding to a live
%%% distributor. The seal machinery itself is macula's, tested there;
%%% this suite pins THIS service's wiring: the six callbacks, the
%%% capability's sealed-only shape, the env refusals, the removed set, the
%%% handler's answers and refusals, and the image's no-distribution,
%%% no-dump posture.
%%% @end
%%%-------------------------------------------------------------------
-module(mcl_distributor_service_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ORG, <<"acme">>).
-define(ORG_KEY_ID_HEX, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff").
-define(REALM_NAME, <<"io.macula">>).
-define(PREFIX, <<"io.macula/acme/chat">>).
%% The suite's own keys are minted in the pure profile: no RSA half to
%% generate, and the checks are the same ones the hybrid profile makes.
-define(PROFILE, pq_pure).

%%------------------------------------------------------------------
%% The six callbacks have the contract's shape
%%------------------------------------------------------------------

info_names_the_service_test() ->
    Info = mcl_distributor_service:info(),
    ?assertEqual(<<"mcl-distributor">>, maps:get(name, Info)),
    ?assert(is_binary(maps:get(version, Info))),
    ?assert(is_binary(maps:get(description, Info))).

%% The link runs no gate on the pull (macula 17, macula#129): the group a
%% pull names travels inside the sealed payload, where no gate sees it, so
%% the handler is handed the call's token and decides. The sealed-only
%% channel stays the link's to enforce.
capabilities_are_the_one_group_keys_v1_test() ->
    {ok, Env} = save_env(),
    try
        true = os:putenv("MCL_GROUP_ORG_KEY_ID", ?ORG_KEY_ID_HEX),
        [Cap] = mcl_distributor_service:capabilities(),
        ?assertEqual(<<"group_keys_v1">>, maps:get(name, Cap)),
        ?assertEqual({mcl_distributor_pull, []}, maps:get(handler, Cap)),
        ?assertEqual(handler_authorizes, maps:get(auth, Cap)),
        ?assertEqual(required, maps:get(confidential, Cap))
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

%% The SDK refuses to start without it (macula 17), so options/0 carries
%% the org key id: the one the operator read from the published
%% org_directory, and `undefined' while the realm still owes the org key.
options_carry_the_org_key_id_the_sdk_requires_test() ->
    with_deploy_env(fun() ->
        ?assertEqual(mcl_distributor:org_key_id(), maps:get(org_key_id, mcl_distributor:options())),
        ?assertEqual(32, byte_size(maps:get(org_key_id, mcl_distributor:options())))
    end),
    with_deploy_env(fun() ->
        true = os:unsetenv("MCL_GROUP_ORG_KEY_ID"),
        ?assertEqual(undefined, maps:get(org_key_id, mcl_distributor:options()))
    end).

%% The membership answer a withdrawal rides on is the realm's own: the
%% distributor supplies the pool, the realm and its key id and leaves the
%% read to the SDK, so no pull is ever decided on its token alone.
options_leave_membership_to_the_realms_slot_test() ->
    with_deploy_env(fun() ->
        Opts = mcl_distributor:options(),
        ?assertEqual(mcl_om_mesh_pool, maps:get(pool, Opts)),
        ?assertEqual(32, byte_size(maps:get(realm, Opts))),
        ?assertEqual(32, byte_size(maps:get(realm_key_id, Opts))),
        ?assertNot(maps:is_key(membership, Opts))
    end).

%% A first boot on a fresh realm: the org key does not exist yet, so there
%% is nothing for a pull to be checked against and no distributor starts.
%% The claim and /health carry the node until the id is filled, and the
%% first start after that serves the group.
start_link_starts_nothing_until_the_org_key_id_is_known_test() ->
    with_deploy_env(fun() ->
        true = os:unsetenv("MCL_GROUP_ORG_KEY_ID"),
        ?assertEqual(ignore, mcl_distributor:start_link())
    end).

%%------------------------------------------------------------------
%% The pull handler reaches a live distributor, and health sees it
%%------------------------------------------------------------------

pull_forwards_to_the_registered_distributor_test() ->
    with_org_distributor(#{}, fun(Pull) ->
        ?assertEqual(ok, mcl_distributor_service:health()),
        {ok, _} = mcl_distributor_pull:init([]),
        {reply, Reply, _} = pull(?PREFIX, Pull),
        ?assertMatch(#{prefix := {text, ?PREFIX}, policy := {text, <<"required">>}, epochs := [_]}, Reply)
    end).

%% No distributor was ever asked to run: the realm still owes the org key,
%% and the SDK cannot check a pull without it (macula 17). That is a normal
%% setup state, so /health answers ok -- a fresh realm's first boot must
%% never fail a canary -- and the wait is named by the boot notice, by the
%% capability this service does not advertise (next test), and, since
%% mcl_om 1.5.0 widens info(), in the body an operator actually reads
%% (mcl-distributor#5).
health_is_ok_while_the_org_key_id_is_unknown_test() ->
    {ok, Env} = save_env(),
    try
        true = os:unsetenv("MCL_GROUP_ORG_KEY_ID"),
        catch unregister(mcl_distributor),
        ?assertEqual(ok, mcl_distributor_service:health()),
        ?assertMatch(#{org_key_id := unset}, mcl_distributor_service:info()),
        %% Encoded, because the canary reads the JSON: a value jsx cannot
        %% write raises inside the handler and /health answers 500.
        Body = mcl_om_health_handler:body(ok, mcl_distributor_service:info(), [], [], #{}, 0),
        ?assertEqual(<<"unset">>,
                     maps:get(<<"org_key_id">>, jsx:decode(jsx:encode(Body), [return_maps])))
    after
        restore_env(Env)
    end.

%% Known, and the process is gone: that is a fault, and it says so.
health_is_down_once_the_org_key_id_is_known_test() ->
    {ok, Env} = save_env(),
    try
        true = os:putenv("MCL_GROUP_ORG_KEY_ID", ?ORG_KEY_ID_HEX),
        catch unregister(mcl_distributor),
        ?assertEqual({down, distributor_not_running}, mcl_distributor_service:health()),
        ?assertMatch(#{org_key_id := set}, mcl_distributor_service:info())
    after
        restore_env(Env)
    end.

%%------------------------------------------------------------------
%% The handler's refusals reach the member as the SDK names them
%%------------------------------------------------------------------

%% A member whose node the org has put in its removed set is refused
%% though its chain verifies: the org's own list is asked before membership.
a_removed_member_is_refused_through_the_handler_test() ->
    with_org_distributor(#{removed => fun(_Caller) -> true end}, fun(Pull) ->
        ?assertMatch({error, not_a_member, _}, pull(?PREFIX, Pull))
    end).

%% A member the realm has withdrawn: its token chain still verifies, and
%% the pull is refused anyway. The handler asks the realm's slot for the
%% caller after it checks the token, and there is no gate at the link to
%% end it (macula 17 runs none, macula#129), so this check is the one that
%% holds -- Uranus's observation, folded into mcl-distributor#5.
a_withdrawn_member_is_refused_though_its_chain_verifies_test() ->
    with_org_distributor(#{membership => fun(_Caller) -> {error, not_a_member} end}, fun(Pull) ->
        ?assertMatch({error, not_a_member, _}, pull(?PREFIX, Pull))
    end).

%% The chain must end at the org key the deploy config names, not merely
%% at some org key: a grant this org's sibling signed is refused, which is
%% what makes MCL_GROUP_ORG_KEY_ID the thing that admits a pull.
a_pull_signed_by_another_org_key_is_refused_test() ->
    with_org_distributor(#{}, fun(#{caller := Caller}) ->
        ?assertMatch({error, <<"not_authorized: group_keys on ", _/binary>>, _},
                     pull(?PREFIX, #{caller => Caller, token => org_grant(org_key(), Caller)}))
    end).

%% Without the org's grant the SDK refuses with its own text, and the pull
%% handler must carry it as an ERROR: answered as a reply, the member would
%% read it as a malformed key reply and name it `no_distributor', losing
%% the one reason that tells it to go and get a grant.
a_pull_without_the_orgs_grant_is_refused_not_authorized_test() ->
    with_org_distributor(#{}, fun(#{caller := Caller}) ->
        ?assertMatch({error, <<"not_authorized: group_keys on ", _/binary>>, _},
                     pull(?PREFIX, #{caller => Caller}))
    end).

another_orgs_group_is_refused_through_the_handler_test() ->
    with_org_distributor(#{}, fun(Pull) ->
        ?assertMatch({error, unknown_group, _}, pull(<<"io.macula/contoso/chat">>, Pull))
    end).

a_pull_while_the_distributor_is_away_is_no_distributor_test() ->
    catch unregister(mcl_distributor),
    ?assertMatch({error, no_distributor, _},
                 pull(?PREFIX, #{caller => crypto:strong_rand_bytes(32)})).

%%------------------------------------------------------------------
%% The removed set: a file on the volume, read at every pull
%%------------------------------------------------------------------

a_missing_removed_set_is_empty_test() ->
    ?assertEqual({ok, []}, mcl_distributor_removed_members:read(scratch("absent"))),
    ?assertNot(mcl_distributor_removed_members:removed(scratch("absent"), <<1:256>>)).

the_removed_set_lists_node_ids_skipping_blanks_and_comments_test() ->
    Path = scratch("removed_members"),
    A = <<1:256>>, B = <<2:256>>,
    ok = file:write_file(Path, [<<"# removed 2026-10-13
">>, binary:encode_hex(A), <<"

  ">>,
                                binary:encode_hex(B, lowercase), <<"  
">>]),
    ?assertEqual({ok, [A, B]}, mcl_distributor_removed_members:read(Path)),
    ?assert(mcl_distributor_removed_members:removed(Path, B)),
    ?assertNot(mcl_distributor_removed_members:removed(Path, <<3:256>>)).

%% A removal that cannot be read must not admit the member it names.
a_malformed_removed_set_refuses_every_caller_test() ->
    Path = scratch("malformed"),
    ok = file:write_file(Path, [binary:encode_hex(<<1:256>>), <<"
not-a-node-id
">>]),
    ?assertEqual({error, {malformed_line, 2}}, mcl_distributor_removed_members:read(Path)),
    ?assert(mcl_distributor_removed_members:removed(Path, <<3:256>>)).

an_unreadable_removed_set_refuses_every_caller_test() ->
    Dir = scratch("a_directory"),
    ok = filelib:ensure_path(Dir),
    ?assert(mcl_distributor_removed_members:removed(Dir, <<3:256>>)).

a_malformed_removed_set_stops_the_boot_test() ->
    Path = scratch("malformed_boot"),
    ok = file:write_file(Path, <<"abc\n">>),
    {ok, Env} = save_env(),
    try
        true = os:putenv("MCL_GROUP_REMOVED_FILE", Path),
        ?assertError({mcl_distributor, {removed_set, Path, {malformed_line, 1}}}, mcl_distributor:options())
    after
        restore_env(Env)
    end.

%%------------------------------------------------------------------
%% Ids from env are exactly 64 hex characters
%%------------------------------------------------------------------

an_id_that_is_not_64_hex_stops_the_boot_test_() ->
    [?_test(begin
         {ok, Env} = save_env(),
         try
             true = os:putenv("MCL_REALM", Bad),
             ?assertError({mcl_distributor, {not_64_hex, "MCL_REALM"}}, mcl_distributor:realm())
         after
             restore_env(Env)
         end
     end) || Bad <- [lists:duplicate(63, $a), lists:duplicate(66, $a), lists:duplicate(64, $g)]].

%%------------------------------------------------------------------
%% The image: no distribution, no crash dump, the removed set's volume
%%------------------------------------------------------------------

the_image_writes_no_crash_dump_and_keeps_the_removed_set_test() ->
    {ok, Containerfile} = file:read_file("Containerfile"),
    ?assertEqual(nomatch, re:run(Containerfile, <<"^ENV (MCL_COOKIE|MCL_NODE_NAME|MCL_NODE_HOST|ERL_EPMD_ADDRESS)">>, [multiline])),
    ?assertMatch({match, _}, re:run(Containerfile, <<"^ENV ERL_CRASH_DUMP_SECONDS=0$">>, [multiline])),
    ?assertMatch({match, _}, re:run(Containerfile, <<"^VOLUME \\[\"/var/lib/mcl-distributor\"\\]$">>, [multiline])).

%% The node holds epoch keys and uses no distributed Erlang: no cookie, no
%% epmd, and no listener for a node connection. The short name is only what
%% relx's start script demands; a long name would also mean an address.
the_node_listens_for_no_distribution_test() ->
    {ok, VmArgs} = file:read_file("config/vm.args.src"),
    ?assertEqual(nomatch, re:run(VmArgs, <<"^-(name|setcookie)\\b">>, [multiline])),
    ?assertMatch({match, _}, re:run(VmArgs, <<"^-start_epmd false$">>, [multiline])),
    ?assertMatch({match, _}, re:run(VmArgs, <<"^-dist_listen false$">>, [multiline])).

%% Nothing in the service needs distribution: a call that would is a sign the
%% no-distribution posture above was broken by a later change.
no_module_uses_distributed_erlang_test() ->
    Sources = filelib:wildcard("apps/mcl_distributor/src/*.erl"),
    ?assertNotEqual([], Sources),
    ?assertEqual([], [S || S <- Sources,
                           {ok, Bin} <- [file:read_file(S)],
                           re:run(Bin, <<"\\b(net_kernel|erpc|rpc|global|pg):|\\bnodes\\(">>) =/= nomatch]).

%%------------------------------------------------------------------
%% Helpers
%%------------------------------------------------------------------

%% A distributor over a realm and an org key of the test's own making, and
%% one member holding the org's `group_keys' grant -- the chain an admitted
%% member presents, which the SDK verifies before it asks anything else.
%% `Opts' overrides the standing the test wants that member to have.
with_org_distributor(Opts, Test) ->
    OrgKey = org_key(),
    Member = member(),
    Pull = #{caller => Member, token => org_grant(OrgKey, Member)},
    {ok, Pid} = macula_group_keys:start_link(maps:merge(org_options(OrgKey), Opts)),
    true = register(mcl_distributor, Pid),
    try Test(Pull) after unregister(mcl_distributor), gen_server:stop(Pid) end.

%% The org key the realm would have minted: its PUBLIC id is what the
%% distributor is told to admit chains against, and its private part signs
%% the member's grant here, exactly as the realm signs it.
org_key() ->
    {ok, OrgKey} = macula_node_keys:generate(org, ?PROFILE),
    OrgKey.

%% A member's node id: the audience of its grant, and the caller the link
%% reports for it.
member() ->
    {ok, Key} = macula_node_keys:generate(identity, ?PROFILE),
    {ok, NodeId} = macula_node_keys:node_id(Key),
    NodeId.

%% The org's `group_keys' grant to that member, on the procedure the
%% distributor serves in this realm.
org_grant(OrgKey, Member) ->
    macula_ucan:create(OrgKey, Member,
                       [#{with => <<"mri:proc:", ?REALM_NAME/binary, "/acme/group_keys_v1">>,
                          can => <<"group_keys">>}],
                       #{exp => erlang:system_time(second) + 3600}).

%% The distributor's options over that key: what options/0 builds from
%% deploy env, with a membership answer the test chooses.
org_options(OrgKey) ->
    #{org => ?ORG, policy => required, rotate_after_ms => 15 * 60000,
      org_key_id => macula_node_keys:key_id(OrgKey),
      realm => macula_realm:id(?REALM_NAME), profile => ?PROFILE,
      membership => fun(_Caller) -> ok end,
      removed => fun(_Caller) -> false end}.

pull(Prefix, #{caller := Caller, token := Token}) ->
    mcl_distributor_pull:handle_request(payload(Prefix, Caller, Token), undefined);
pull(Prefix, #{caller := Caller}) ->
    mcl_distributor_pull:handle_request(payload(Prefix, Caller), undefined).

%% What the link hands the handler: the pull, the wire-verified caller, and
%% the token and proofs the caller signed into the request.
payload(Prefix, Caller, Token) ->
    (payload(Prefix, Caller))#{ucan_token => Token, proofs => []}.

payload(Prefix, Caller) ->
    #{{text, <<"prefix">>} => {text, Prefix},
      {text, <<"epoch">>} => {text, <<"current">>},
      caller => Caller}.

scratch(Name) ->
    Dir = filename:join(["_build", "test", "mcl_distributor_tests", integer_to_list(erlang:unique_integer([positive]))]),
    ok = filelib:ensure_path(Dir),
    filename:join(Dir, Name).

%% A box's deploy env for the length of `Fun': the org and realm pins, a
%% removed set on a scratch file, a pool holding the name the SDK looks up
%% at every membership read, and the node's crypto profile.
with_deploy_env(Fun) ->
    {ok, Env} = save_env(),
    Profile = application:get_env(macula, crypto_profile),
    ok = application:set_env(macula, crypto_profile, ?PROFILE),
    true = os:putenv("MCL_GROUP_ORG", "acme"),
    true = os:putenv("MCL_GROUP_ORG_KEY_ID", ?ORG_KEY_ID_HEX),
    true = os:putenv("MCL_GROUP_REALM_KEY_ID", ?ORG_KEY_ID_HEX),
    true = os:putenv("MCL_REALM", ?ORG_KEY_ID_HEX),
    true = os:putenv("MCL_GROUP_REMOVED_FILE", scratch("removed_members")),
    Pool = fake_pool(),
    try Fun() after restore_env(Env), restore_profile(Profile), stop_fake_pool(Pool) end.

restore_profile(undefined) -> ok = application:unset_env(macula, crypto_profile);
restore_profile(Profile) -> ok = application:set_env(macula, crypto_profile, Profile).

%% Nothing reads through this pool here: the name is all the SDK's default
%% membership path needs to find one.
fake_pool() ->
    Pid = spawn(fun() -> receive stop -> ok end end),
    true = register(mcl_om_mesh_pool, Pid),
    Pid.

stop_fake_pool(Pid) ->
    true = unregister(mcl_om_mesh_pool),
    Pid ! stop,
    ok.

%%------------------------------------------------------------------
%% Env save/restore, so one suite never leaks into another
%%------------------------------------------------------------------

-define(ENV, ["MCL_GROUP_ORG", "MCL_GROUP_ORG_KEY_ID", "MCL_GROUP_REALM_KEY_ID", "MCL_REALM", "MCL_GROUP_REMOVED_FILE"]).

save_env() ->
    {ok, maps:from_list([{Name, os:getenv(Name)} || Name <- ?ENV])}.

restore_env(Env) ->
    maps:foreach(fun restore/2, Env).

%% A variable that was unset before the test is unset again, not left as the test set it.
restore(Name, false) -> true = os:unsetenv(Name), ok;
restore(Name, Value) -> true = os:putenv(Name, Value), ok.
