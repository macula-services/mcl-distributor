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
%% The handler's refusals reach the member as the SDK names them
%%------------------------------------------------------------------

a_removed_member_is_refused_through_the_handler_test() ->
    Removed = crypto:strong_rand_bytes(32),
    with_distributor(#{removed => fun(Caller) -> Caller =:= Removed end},
                     fun() ->
                         ?assertMatch({error, not_a_member, _}, pull(?PREFIX, Removed)),
                         ?assertMatch({reply, #{epochs := [_]}, _}, pull(?PREFIX, crypto:strong_rand_bytes(32)))
                     end).

another_orgs_group_is_refused_through_the_handler_test() ->
    with_distributor(#{}, fun() ->
        ?assertMatch({error, unknown_group, _}, pull(<<"io.macula/contoso/chat">>, crypto:strong_rand_bytes(32)))
    end).

a_pull_while_the_distributor_is_away_is_no_distributor_test() ->
    catch unregister(mcl_distributor),
    ?assertMatch({error, no_distributor, _}, pull(?PREFIX, crypto:strong_rand_bytes(32))).

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

%% A distributor registered as the handler finds it, with `Opts' over the defaults, for the length of `Test'.
with_distributor(Opts, Test) ->
    {ok, Pid} = macula_group_keys:start_link(
                  maps:merge(#{org => ?ORG, policy => required, membership => fun(_Caller) -> ok end}, Opts)),
    true = register(mcl_distributor, Pid),
    try Test() after unregister(mcl_distributor), gen_server:stop(Pid) end.

pull(Prefix, Caller) ->
    mcl_distributor_pull:handle_request(#{{text, <<"prefix">>} => {text, Prefix},
                                          {text, <<"epoch">>} => {text, <<"current">>},
                                          caller => Caller}, undefined).

scratch(Name) ->
    Dir = filename:join(["_build", "test", "mcl_distributor_tests", integer_to_list(erlang:unique_integer([positive]))]),
    ok = filelib:ensure_path(Dir),
    filename:join(Dir, Name).

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
