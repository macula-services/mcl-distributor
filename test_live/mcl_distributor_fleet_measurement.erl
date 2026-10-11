%% @doc The fleet measurement (DESIGN_E2E_SEALED_PUBSUB.md §9): a sealed
%% publication crosses EVERY fleet station, through the DEPLOYED distributor
%% (org mcl-distributor, the real realm), and the member opens it.
%%
%% The two member identities are FIXED (keys persisted under _build/test/
%% identity), because the org's group_keys UCANs are minted against their
%% node ids on the realm box (scripts/mint-group-ucan.sh in macula-realm).
%% The runner prints the ids; export the minted tokens and run:
%%   MCL_MEASURE_PUB_UCAN=... MCL_MEASURE_SUB_UCAN=... \
%%     rebar3 as live_test eunit --dir test_live --module=mcl_distributor_fleet_measurement
%%
%% The station list comes from mcl-stations/list_stations over the mesh, so
%% a station added to the fleet is measured on the next run with no edit.
%%
%% The D28 budget read (§9's "without charging the publisher") lives in the
%% STATION's VM (macula_dht_slots is station-internal, not SDK): it needs a
%% station read surface and is reported n/a until that lands. The functional
%% half here still proves the sealed event crosses each station and opens.
-module(mcl_distributor_fleet_measurement).

-include_lib("eunit/include/eunit.hrl").

-define(REALM_NAME, <<"io.macula">>).
-define(REALM, crypto:hash(sha256, ?REALM_NAME)).
-define(GROUP_PROC, <<"mcl-distributor/group_keys_v1">>).
-define(PREFIX, <<"io.macula/mcl-distributor/measure">>).
-define(MARKER, <<"fleet-measurement-marker">>).

the_fleet_measurement_test_() ->
    {timeout, 1800, fun run/0}.

run() ->
    {ok, _} = application:ensure_all_started(macula),
    PubUcan = required_env("MCL_MEASURE_PUB_UCAN"),
    SubUcan = required_env("MCL_MEASURE_SUB_UCAN"),
    PublisherKp = identity_key(pub),
    SubscriberKp = identity_key(sub),
    {ok, PubNode} = macula_node_keys:node_id(PublisherKp),
    {ok, SubNode} = macula_node_keys:node_id(SubscriberKp),
    io:format("member node ids (for mint-group-ucan.sh):~n"
              "  publisher:  ~s~n  subscriber: ~s~n",
              [binary:encode_hex(PubNode), binary:encode_hex(SubNode)]),
    RealmPub = realm_pub(),
    Stations = stations(RealmPub),
    io:format("~-34s ~-10s ~-10s ~-8s ~s~n",
              ["station", "pull", "publish", "open", "d28_budget"]),
    Results = [measure(S, PublisherKp, SubscriberKp, RealmPub, PubUcan, SubUcan)
               || S <- Stations],
    ?assert(lists:all(fun(ok) -> true; (_) -> false end, Results)),
    ok.

measure(Station, PublisherKp, SubscriberKp, RealmPub, PubUcan, SubUcan) ->
    Name = maps:get(hostname, Station),
    Node = maps:get(node_id, Station),
    Seed = #{host => Name, port => maps:get(quic_port, Station, 4433),
             expected_node_id => Node},
    {ok, Publisher} = macula_client:connect([Seed], pool_opts(PublisherKp, RealmPub)),
    {ok, Subscriber} = macula_client:connect([Seed], pool_opts(SubscriberKp, RealmPub)),
    try
        ok = wait_healthy(Publisher, 100),
        ok = wait_healthy(Subscriber, 100),
        Topic = <<Name/binary, "/fact_v1">>,
        Pull = #{{text, <<"prefix">>} => {text, ?PREFIX},
                 {text, <<"epoch">>} => {text, <<"current">>}},
        PullResult = macula:call(Publisher, ?REALM, ?GROUP_PROC, Pull, 10_000,
                                 #{confidential => required, ucan_token => PubUcan}),
        {ok, SubRef} = macula:subscribe(Subscriber, ?REALM, Topic, self(),
                                        #{group => ?PREFIX, ucan_token => SubUcan}),
        ok = macula:publish(Publisher, ?REALM, Topic, #{fact => {text, ?MARKER}},
                            #{group => ?PREFIX, ucan_token => PubUcan}),
        Opened = receive_event(SubRef, Topic),
        io:format("~-34s ~-10s ~-10s ~-8s ~s~n",
                  [Name, pull(PullResult), ok, opened(Opened), "n/a"]),
        ok
    catch
        Class:Reason ->
            io:format("~-34s ~-10p:~p~n", [Name, Class, Reason]),
            {error, Reason}
    after
        catch macula_client:close(Publisher),
        catch macula_client:close(Subscriber)
    end.

%%------------------------------------------------------------------
%% Stations, keys, pools
%%------------------------------------------------------------------

stations(RealmPub) ->
    {ok, Pool} = macula_client:connect(seed_pair(), #{realm_trust => #{?REALM => RealmPub}}),
    ok = wait_healthy(Pool, 100),
    {ok, Payload} = macula:call(Pool, ?REALM, <<"mcl-stations/list_stations">>, #{}, 20_000),
    catch macula_client:close(Pool),
    [S || S <- macula_record:payload_field(Payload, <<"stations">>), is_map(S),
          maps:is_key(hostname, S), maps:is_key(node_id, S)].

seed_pair() ->
    [#{host => <<"station-nl-ams.macula.io">>, port => 4433,
       expected_node_id => <<16#000370eebafa9a89a44c9448b4796788fbff1885abd67c80d681d28cebb04b0c:256>>},
     #{host => <<"station-fi-helsinki.macula.io">>, port => 4433,
       expected_node_id => <<16#004d1f470097ccf8826ce291900e882fdb1f20375e53901facaec0f23eb4efd8:256>>},
     #{host => <<"station-fr-paris.macula.io">>, port => 4433,
       expected_node_id => <<16#0063acc4a5af409ca6b15041975128d389222c48366fb3a1dfb948da01f7ca94:256>>}].

identity_key(Which) ->
    Path = filename:join(["_build/test/identity", atom_to_list(Which) ++ ".key"]),
    filelib:ensure_dir(Path),
    case macula_node_keys:load(Path, identity, pq_hybrid) of
        {ok, Key} ->
            Key;
        {error, enoent} ->
            {ok, Key} = macula_node_keys:generate(
                          identity, pq_hybrid,
                          #{puzzle_difficulty => macula_node_keys:puzzle_difficulty()}),
            ok = macula_node_keys:save(Path, Key),
            Key
    end.

realm_pub() ->
    {ok, Hex} = file:read_file("config/io_macula_realm_key.hex"),
    << <<(list_to_integer([A, B], 16))>> || <<A:8, B:8>> <= string:trim(Hex) >>.

pool_opts(KeyPair, RealmPub) ->
    #{node_identity => KeyPair, realm_trust => #{?REALM => RealmPub}}.

wait_healthy(_Pool, 0) ->
    erlang:error(seed_never_healthy);
wait_healthy(Pool, N) ->
    healthy_or_wait(macula_client:status(Pool), Pool, N).

healthy_or_wait({ok, #{healthy_links := H}}, _Pool, _N) when H > 0 -> ok;
healthy_or_wait(_Status, Pool, N) -> timer:sleep(100), wait_healthy(Pool, N - 1).

pull({ok, Reply}) when is_map(Reply) -> ok;
pull(Other) -> Other.

opened({macula_event, _Ref, _Topic, Payload, _Meta}) ->
    case macula_record:payload_field(Payload, <<"fact">>) of
        {text, ?MARKER} -> ok;
        _ -> wrong_payload
    end;
opened(Other) -> Other.

receive_event(SubRef, Topic) ->
    receive {macula_event, SubRef, Topic, _, _} = Event -> Event
    after 10_000 -> erlang:error({no_event, Topic})
    end.

required_env(Name) ->
    case os:getenv(Name) of
        false -> erlang:error({unset_env, Name});
        Value -> list_to_binary(Value)
    end.
