%%%-------------------------------------------------------------------
%%% @doc The distributor worker: the SDK's `macula_group_keys' started
%%% for THIS service's org, registered as `mcl_distributor' so the pull
%%% handler (`mcl_distributor_pull') can forward to it by name.
%%%
%%% What it holds: each group's epoch keys, in memory only, rotated every
%%% `MCL_GROUP_ROTATE_MS'. It is NOT in the data path: events flow
%%% publisher -> stations -> subscribers whether or not this process is
%%% alive. Popped, a member holding the current epoch goes on; new joins
%%% and rotations fail closed until it is back.
%%%
%%% Membership is the DEFAULT path: the realm slot read over the mesh
%%% pool (`pool'), pinned by `realm' and `realm_key_id', verified under
%%% the node's crypto profile. Every piece of that is public material.
%%% @end
%%%-------------------------------------------------------------------
-module(mcl_distributor).

-export([start_link/0, options/0, org/0, policy/0, org_key_id/0, realm/0, realm_key_id/0]).

-define(POOL, mcl_om_mesh_pool).
-define(DEFAULT_ROTATE_MS, 15 * 60000).

%% @doc Start the distributor and register it by name. The name is what
%% the pull handler forwards to; a supervisor restart re-registers it
%% (a dead process frees its name).
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    started(macula_group_keys:start_link(options())).

started({ok, Pid}) ->
    %% register/2 returns `true' or raises badarg (name taken, or the pid
    %% already gone); a restart after a crash finds the name free.
    true = register(?MODULE, Pid),
    {ok, Pid};
started(Error) ->
    Error.

%% @doc The distributor's options, from deploy env. Everything here is
%% public material except nothing: no key leaves the secrets volume.
%% The policy's `org_key_id' names the org's PUBLIC key (the
%% org_directory's org_key), which the realm_member_required check
%% matches the caller's UCAN issuer against.
-spec options() -> map().
options() ->
    #{org => org(),
      policy => policy(),
      rotate_after_ms => rotate_after_ms(),
      pool => pool(),
      realm => realm(),
      realm_key_id => realm_key_id(),
      profile => profile()}.

-spec org() -> binary().
org() ->
    required_binary("MCL_GROUP_ORG").

-spec policy() -> required | preferred | off.
policy() ->
    case os:getenv("MCL_GROUP_POLICY") of
        false     -> required;
        "required" -> required;
        "preferred" -> preferred;
        "off"     -> off;
        Other     -> error({mcl_group_policy, {not_a_policy, Other}})
    end.

-spec org_key_id() -> <<_:256>>.
org_key_id() ->
    decode_hex(required_binary("MCL_GROUP_ORG_KEY_ID")).

rotate_after_ms() ->
    case os:getenv("MCL_GROUP_ROTATE_MS") of
        false -> ?DEFAULT_ROTATE_MS;
        Ms    -> list_to_integer(Ms)
    end.

realm() ->
    %% MCL_REALM carries the realm id as 64 hex chars; the membership check's
    %% trust wants the 32 bytes they decode to.
    decode_hex(required_binary("MCL_REALM")).

%% The mesh pool by its registered name, as a pid: the SDK's options type
%% demands a pid, and a missing pool is refused here, at boot, never by the
%% first member whose pull would fail.
pool() ->
    case whereis(?POOL) of
        undefined -> error({mcl_distributor, pool_not_started});
        Pid       -> Pid
    end.

realm_key_id() ->
    decode_hex(required_binary("MCL_GROUP_REALM_KEY_ID")).

profile() ->
    {ok, Profile} = macula_crypto_profile:configured(),
    Profile.

required_binary(Name) ->
    case os:getenv(Name) of
        false -> error({mcl_distributor, {unset, Name}});
        ""    -> error({mcl_distributor, {empty, Name}});
        Value -> list_to_binary(Value)
    end.

decode_hex(Hex) ->
    << <<(list_to_integer([A, B], 16))>> || <<A:8, B:8>> <= Hex >>.
