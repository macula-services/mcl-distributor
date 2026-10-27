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
%%%
%%% THE ORG KEY ID IS REQUIRED TO START (macula 17, macula#129). The
%%% distributor checks each pull's token itself, and an org-grant group
%%% admits a chain that ends at the org's public key, so the SDK needs
%%% `org_key_id' at `start_link'. The realm mints that key only when it
%%% issues the provider grant, so on a first boot the id is UNKNOWN: no
%%% distributor starts (`ignore', so its supervisor has no child), the
%%% claim and /health carry the node through, and the first start after
%%% MCL_GROUP_ORG_KEY_ID is filled serves the group. `/health' stays ok
%%% through that wait -- a normal setup state must never fail a canary --
%%% and the service logs one notice naming the variable rather than report
%%% a distributor that was never asked to run.
%%% @end
%%%-------------------------------------------------------------------
-module(mcl_distributor).

-export([start_link/0, options/0, org/0, policy/0, org_key_id/0, realm/0, realm_key_id/0, removed_file/0,
         restricted_groups/0, restricted_issuer_key_id/0, node_id/1]).

-define(POOL, mcl_om_mesh_pool).
-define(DEFAULT_ROTATE_MS, 15 * 60000).
-define(DEFAULT_REMOVED_FILE, "/var/lib/mcl-distributor/removed_members").

%% @doc Start the distributor and register it by name. The name is what
%% the pull handler forwards to; a supervisor restart re-registers it
%% (a dead process frees its name). Without the org key id there is
%% nothing to check a pull against, so no distributor starts: `ignore'
%% leaves the supervisor with no child until the id is known.
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    starting(options()).

starting(#{org_key_id := undefined}) ->
    ignore;
starting(Opts) ->
    started(macula_group_keys:start_link(Opts)).

started({ok, Pid}) ->
    %% register/2 returns `true' or raises badarg (name taken, or the pid
    %% already gone); a restart after a crash finds the name free.
    true = register(?MODULE, Pid),
    {ok, Pid};
started(Error) ->
    Error.

%% The SDK's options while the org key id is known, and the same map with
%% it still `undefined' before the realm mints the org key (macula 17).
-type options() :: macula_group_keys:options()
                 | #{org := binary(), policy := macula_group_keys:policy(),
                     org_key_id := undefined, _ => _}.

%% @doc The distributor's options, from deploy env. Everything here is
%% public material except nothing: no key leaves the secrets volume.
%% The policy's `org_key_id' names the org's PUBLIC key (the
%% org_directory's org_key), which the SDK's org-grant check matches the
%% caller's UCAN chain against. It is `undefined' until the realm mints
%% the org key, and the SDK refuses to start without it, so
%% `start_link/0' starts nothing then; everything else here is checked
%% either way, so a bad deploy fails at boot rather than at the first
%% pull.
-spec options() -> options().
options() ->
    RemovedFile = removed_set_checked(removed_file()),
    #{org => org(),
      policy => policy(),
      org_key_id => org_key_id(),
      rotate_after_ms => rotate_after_ms(),
      pool => pool(),
      removed => fun(Caller) -> mcl_distributor_removed_members:removed(RemovedFile, Caller) end,
      realm => realm(),
      realm_key_id => realm_key_id(),
      groups => restricted_groups(),
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
%% comes back from the published org_directory. The SDK's org-grant check
%% needs it to start at all, so no distributor runs while it is unset and
%% capabilities() omits group_keys_v1 -- the claim and /health still work,
%% and the first start after the env is filled serves the group.
-spec org_key_id() -> <<_:256>> | undefined.
org_key_id() ->
    case os:getenv("MCL_GROUP_ORG_KEY_ID") of
        false -> undefined;
        ""    -> undefined;
        Hex   -> hex_32("MCL_GROUP_ORG_KEY_ID", list_to_binary(Hex))
    end.

%% @doc The restricted groups, from `MCL_GROUP_RESTRICTED': a comma-separated
%% list of `<prefix>=<mode>', the mode `refusing' or `counting' and never
%% left out, so a group is never fail-open by omission. Each one admits a
%% pull on the `pubsub/subscribe' grant of `restricted_issuer_key_id/0'
%% covering the whole group (macula#129); a group not listed keeps the
%% org's grant. Unset or empty lists none. A malformed entry or a prefix
%% listed twice stops the boot; a prefix the org does not own, or a
%% restricted group under a seal policy other than `required', is refused
%% by the SDK when the distributor starts.
-spec restricted_groups() -> #{binary() => {realm_capability, <<_:256>>, counting | refusing}}.
restricted_groups() ->
    restricted(string:lexemes(os:getenv("MCL_GROUP_RESTRICTED", ""), ","), #{}).

restricted([], Groups) ->
    Groups;
restricted([Entry | Rest], Groups) ->
    restricted(Rest, listed_once(restricted_entry([string:trim(Part) || Part <- string:split(Entry, "=")]), Entry, Groups)).

restricted_entry([Prefix, "refusing"]) when Prefix =/= "" -> {list_to_binary(Prefix), refusing};
restricted_entry([Prefix, "counting"]) when Prefix =/= "" -> {list_to_binary(Prefix), counting};
restricted_entry(_Malformed) -> malformed.

listed_once(malformed, Entry, _Groups) ->
    error({mcl_distributor, {not_a_restricted_group, Entry}});
listed_once({Prefix, _Mode}, _Entry, Groups) when is_map_key(Prefix, Groups) ->
    error({mcl_distributor, {restricted_group_listed_twice, Prefix}});
listed_once({Prefix, Mode}, _Entry, Groups) ->
    Groups#{Prefix => {realm_capability, restricted_issuer_key_id(), Mode}}.

%% @doc The key whose `pubsub/subscribe' grants admit a restricted group's
%% pull: `MCL_GROUP_RESTRICTED_ISSUER_KEY_ID', or the realm key
%% (`MCL_GROUP_REALM_KEY_ID') when unset, which is the production shape.
%% A lab box may name another issuer to measure the refusal before the
%% realm mints topic roles (macula-realm#98); the membership check stays
%% pinned to the realm key either way.
-spec restricted_issuer_key_id() -> <<_:256>>.
restricted_issuer_key_id() ->
    case os:getenv("MCL_GROUP_RESTRICTED_ISSUER_KEY_ID") of
        false -> realm_key_id();
        ""    -> realm_key_id();
        Hex   -> hex_32("MCL_GROUP_RESTRICTED_ISSUER_KEY_ID", list_to_binary(Hex))
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
