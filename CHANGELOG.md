# Changelog

## Unreleased

- **The base library is macula 17** (macula-io/macula#129), which moves a sealed group's access check from the advertise gate into the distributor's own handler. This follows with the only shape 17 knows: `macula_group_keys:advertise_opts/0` (`auth => handler_authorizes`, so the link runs no gate and hands the handler the call's token and proofs) and `start_link/1` with `org_key_id`, `realm` and `profile`. A pull is now admitted only when its chain ends at the org key; a member the realm has withdrawn is refused right after that check though its chain still verifies, and an unadmitted one is refused `not_authorized: group_keys on mri:proc:<org>/group_keys_v1`. `mcl_distributor_pull` now carries a binary refusal as a handler error instead of a reply, which the member's keyring would have read as a malformed reply and named `no_distributor`. `MCL_GROUP_ORG_KEY_ID` is needed to START: on a fresh realm, where the org key is minted only when the realm issues the provider grant, no distributor starts and `/health` stays `ok` through that wait (a normal setup state, as mcl_om's contract has a waiting service answer ok), so a fresh realm's first boot never fails a canary; the boot logs one notice naming `MCL_GROUP_ORG_KEY_ID`, and `group_keys_v1` is absent from everything advertised until it is set. With the id known and the distributor missing, health is `down`. mcl_om 1.4.0 still declares `macula ~> 16.0` and does not name `handler_authorizes` in its `capability()` type; it forwards the value unchanged, so this builds and runs, and moving that floor is mcl_om's own release.
- **The base library is macula 16** (macula-codebase-checks#4): the floor moves `~> 15.6` to `~> 16.0`, and `mcl_om` from `~> 1.0` to `~> 1.4`. This is the one service where the move has a behavioural edge: a key pull checks the caller's realm endorsement slot (`macula_group_keys` through `macula_hyparview_endorsement:slot_endorsement/4`), and under 16.0 an endorsement whose window exceeds 24 hours is refused as `endorsement_window_too_long`, while a revoked member is refused at once where the tombstone is readable (macula#118). Both live realms already issue 24-hour windows and renew them hourly (macula-realm 0.8.2, `EndorsementSweep`), so a pull over a live membership is unaffected.

## 0.3.0 - 2026-10-17

- wire 1.0: on macula 15.6 / mcl_om 1.0 (macula-io/macula#105). A wire 1.0 node and a 0.10.3-fleet node do not interoperate, so this release reaches a box only on the flag day (macula-io/macula-fleet#27).

## 0.2.2 - 2026-10-15

- **Rebuilt on mcl_om 0.42** (mcl-om#26): advertisement renewals move to a 70 s interval under a 280 s TTL (from 30 s / 120 s), so a station sends far fewer renewal frames; the health windows derive from the interval. Carries macula 14.11.0 (mcl_om 0.42's floor).

## 0.2.1 - 2026-10-14

- **Rebuilt on mcl_om 0.40** (mcl-om#25): a lapsed provider delegation claims again and comes back without a restart, and `/health` shows each authorization's `not_after_ms`, degraded as `expiring` with a third or less of its life left.

## 0.2.0 (2026-10-13)

Supersedes 0.1.1, which was tagged off main and never gated (mcl-distributor#1).

- **The org can remove a member.** The removed set is a file on the service's own volume (`MCL_GROUP_REMOVED_FILE`, default `/var/lib/mcl-distributor/removed_members`), read at every pull and kept across restarts; a removed node is refused every epoch. A set that cannot be read refuses every caller, and a malformed one stops the boot.
- **No epoch key in a log or a dump.** On macula 14.10 the distributor keeps its epochs out of its process state and redacts them in status and crash reports. The image sets `ERL_CRASH_DUMP_SECONDS=0`, so the VM writes no crash dump.
- **A pool restart no longer crashes the distributor.** The mesh pool is passed by its registered name and looked up at every membership read.
- **No Erlang distribution listener.** The node starts with no cookie, `-start_epmd false` and `-dist_listen false` (a short name stays, because relx's start script requires one): the distributor serves members over the mesh and uses no distributed Erlang, so nothing accepts a node connection, and no remote shell or dist-eval (the path that once printed keys) reaches the process holding them. The release's `remote_console` and `eval` no longer work against it, by design. The image sets no `MCL_COOKIE`, `MCL_NODE_NAME` or `MCL_NODE_HOST`.
- **Ids from env are exactly 64 hex characters**, or the boot stops naming the variable; a short one used to match nothing while /health said ok.
- **A refusal reaches the member as the SDK names it** (`not_a_member`, `unknown_group`, ...), no longer wrapped twice; a pull while the distributor restarts is `no_distributor` instead of a crashed handler.
- The capability takes `macula_group_keys:advertise_opts/1`; C4 model in `architecture/`.

## 0.1.0 (2026-10-11)

- **The group-key distributor as a service:** `macula_group_keys` under mcl_om, advertising `<org>/group_keys_v1` with the `realm_member_required` `group_keys` policy and `confidential => required`, the default realm-slot membership, and the `{mcl_distributor_pull, []}` handler forwarding to the registered distributor.
