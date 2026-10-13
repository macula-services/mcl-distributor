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
%%% pool, pinned by `realm' and `realm_key_id', verified under the node's
%%% crypto profile. Every piece of that is public material. The pool is
%%% given by its registered name, which the SDK looks up at every read, so
%%% a pool mcl_om's supervisor restarts is found again. Before membership,
%%% the org's removed set (mcl_distributor_removed_members) refuses every
%%% node the org has removed.
%%% @end
%%%-------------------------------------------------------------------
-module(mcl_distributor).

-export([start_link/0, options/0, org/0, policy/0, org_key_id/0, realm/0, realm_key_id/0, removed_file/0,
         node_id/1]).

-define(POOL, mcl_om_mesh_pool).
-define(DEFAULT_ROTATE_MS, 15 * 60000).
-define(DEFAULT_REMOVED_FILE, "/var/lib/mcl-distributor/removed_members").

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
-spec options() -> macula_group_keys:options().
options() ->
    RemovedFile = removed_set_checked(removed_file()),
    #{org => org(),
      policy => policy(),
      rotate_after_ms => rotate_after_ms(),
      pool => pool(),
      removed => fun(Caller) -> mcl_distributor_removed_members:removed(RemovedFile, Caller) end,
      realm => realm(),
      realm_key_id => realm_key_id(),
      profile => profile()}.

%% @doc The removed set's file, on the persistent volume:
%% `MCL_GROUP_REMOVED_FILE', or /var/lib/mcl-distributor/removed_members.
-spec removed_file() -> string().
removed_file() ->
    case os:getenv("MCL_GROUP_REMOVED_FILE") of
        false -> ?DEFAULT_REMOVED_FILE;
        ""    -> ?DEFAULT_REMOVED_FILE;
        Path  -> Path
    end.

%% A removed set that cannot be read is refused at boot, before anyone pulls.
removed_set_checked(Path) ->
    removed_set_read(mcl_distributor_removed_members:read(Path), Path).

removed_set_read({ok, _NodeIds}, Path) -> Path;
removed_set_read({error, Reason}, Path) -> error({mcl_distributor, {removed_set, Path, Reason}}).

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

%% The org's PUBLIC key id, or `undefined' until the realm has minted the
%% org key and published its org_directory. The realm generates the org key
%% lazily when it issues the provider grant, so this is UNKNOWN at first
%% boot: the claim lands first, the operator admits the node, and the key id
%% comes back from the published org_directory. The capability's
%% realm_member_required policy needs it, so capabilities() omits
%% group_keys_v1 while it is unset -- the claim and the other capabilities
%% still work, and a restart after the env is filled registers the full set.
-spec org_key_id() -> <<_:256>> | undefined.
org_key_id() ->
    case os:getenv("MCL_GROUP_ORG_KEY_ID") of
        false -> undefined;
        ""    -> undefined;
        Hex   -> hex_32("MCL_GROUP_ORG_KEY_ID", list_to_binary(Hex))
    end.

rotate_after_ms() ->
    case os:getenv("MCL_GROUP_ROTATE_MS") of
        false -> ?DEFAULT_ROTATE_MS;
        Ms    -> list_to_integer(Ms)
    end.

realm() ->
    %% MCL_REALM carries the realm id as 64 hex chars; the membership check's
    %% trust wants the 32 bytes they decode to.
    hex_32("MCL_REALM", required_binary("MCL_REALM")).

%% The mesh pool by its registered name, which the SDK looks up at every
%% membership read: a pid read once here would die with the first pool
%% restart, and every pull after it would crash the distributor. A pool not
%% started at all is refused here, at boot, never by the first member.
pool() ->
    case whereis(?POOL) of
        undefined -> error({mcl_distributor, pool_not_started});
        _Pid      -> ?POOL
    end.

realm_key_id() ->
    hex_32("MCL_GROUP_REALM_KEY_ID", required_binary("MCL_GROUP_REALM_KEY_ID")).

profile() ->
    {ok, Profile} = macula_crypto_profile:configured(),
    Profile.

required_binary(Name) ->
    case os:getenv(Name) of
        false -> error({mcl_distributor, {unset, Name}});
        ""    -> error({mcl_distributor, {empty, Name}});
        Value -> list_to_binary(Value)
    end.

%% A 32-byte id from deploy env: exactly 64 hex characters, or the boot stops
%% and names the variable. A shorter value would decode to a short id that
%% matches nothing, and every pull would be refused while /health says ok.
hex_32(Name, Hex) ->
    hex_decoded(node_id(Hex), Name).

hex_decoded({ok, Id}, _Name) -> Id;
hex_decoded(error, Name) -> error({mcl_distributor, {not_64_hex, Name}}).

%% @doc A 32-byte id from exactly 64 hex characters, either case.
-spec node_id(binary()) -> {ok, <<_:256>>} | error.
node_id(Hex) when byte_size(Hex) =:= 64 ->
    try binary:decode_hex(Hex) of
        Id -> {ok, Id}
    catch
        error:badarg -> error
    end;
node_id(_NotSixtyFour) ->
    error.
