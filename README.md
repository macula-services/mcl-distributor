# mcl-distributor

<!-- Service README template: swap the service name in the two badge URLs,
     the package link, and the tagline; everything else is shared. -->

[![CI](https://img.shields.io/github/actions/workflow/status/macula-services/mcl-distributor/lint.yml?branch=main&label=CI)](https://github.com/macula-services/mcl-distributor/actions/workflows/lint.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![ghcr.io](https://img.shields.io/badge/ghcr.io-macula--services%2Fmcl--distributor-blue.svg)](https://github.com/macula-services/mcl-distributor/pkgs/container/mcl-distributor)
[![BEAM](https://img.shields.io/badge/beam-28%2B-A90533?logo=erlang&logoColor=white)](https://www.erlang.org)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub%20Sponsors-support-ea4aaa.svg?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/rgfaber)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-support-ffdd00.svg?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/rlefever)

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/macula-full-dark.svg">
    <img src="assets/macula-full-light.svg" alt="Macula" width="320">
  </picture>
</p>

<p align="center">
  <strong>The group-key distributor for Macula's sealed pubsub</strong>
</p>

---

Distributes a sealed pubsub group's rotating epoch keys to its admitted members over sealed calls, and never touches the traffic itself.

The group-key distributor for [Macula](https://github.com/macula-io/macula)'s sealed pubsub. `<org>/group_keys_v1` is the service's own procedure, and the only one; `mcl_om` adds `<org>/info` and `<org>/get_limits` to every service, both open, and `capabilities/0` is the list. It answers the sealed pulls every group member makes at join and at each epoch rotation. The design it implements is [`DESIGN_E2E_SEALED_PUBSUB.md`](https://github.com/macula-io/macula/blob/main/docs/design/DESIGN_E2E_SEALED_PUBSUB.md); the distributor itself is the SDK's `macula_group_keys`, started here with this service's deploy config.

**What it is not:** it is not in the data path. Events flow publisher → stations → subscribers whether or not the distributor is up. Popped, members holding the current epoch go on publishing and opening; new joins and rotations fail closed until it returns.

**What it holds:** each group's epoch keys, in memory only, rotated every `MCL_GROUP_ROTATE_MS` (default 15 minutes). Keys never travel readable by a station: the pull is a sealed call (`confidential => required`), refused in the clear by the link before the handler runs.

**What it decides:** the call's authority, then membership, per pull. The procedure is advertised `auth => handler_authorizes` (macula 17, macula#129), so the link runs no gate and hands the handler the token the caller signed and its proofs: the handler admits the pull only when that chain ends at the org key, before it looks at anything else. Then the org's removed set, then the realm slot (`MCL_REALM` + `MCL_GROUP_REALM_KEY_ID`). A member the realm has withdrawn is refused there though its chain still verifies, and a pull without the org's grant is refused `not_authorized: group_keys on mri:proc:<org>/group_keys_v1`. The removed set is a file on the service's own volume, `removed_members`, one node id (64 hex characters) per line, read at every pull: a member whose id is there is refused every epoch from its next pull, and the set survives a restart. A set that cannot be read, or holds a malformed line, refuses every caller.

**What it shows:** no epoch key in its process state, its status or a crash report (macula 14.10), and the VM writes no crash dump. It runs without an Erlang distribution listener: no cookie, no epmd, `-dist_listen false`, so nothing accepts a node connection and no remote shell or dist-eval reaches the keys. The release's `remote_console` and `eval` do not work against it, by design.

The architecture (C4 context, containers, components) is in [architecture/README.md](architecture/README.md).

## Deploy config

| Env | Meaning |
|---|---|
| `MCL_GROUP_ORG` | The org whose groups this service distributes; also the procedure's namespace (`<org>/group_keys_v1`) |
| `MCL_GROUP_ORG_KEY_ID` | The org's PUBLIC key id (hex), which the handler admits a pull's chain against. The distributor cannot start without it: on a fresh realm the realm mints the org key only when it issues the provider grant, so a first boot runs without one. `/health` stays `ok` through that wait — a normal setup state must never fail a canary — while the boot logs one notice naming this variable and `group_keys_v1` is absent from everything advertised; fill it from the published `org_directory` and the first start that serves the group follows |
| `MCL_GROUP_REALM_KEY_ID` | The realm key id (hex) the membership check pins the realm slot to |
| `MCL_GROUP_POLICY` | `required` (default), `preferred`, or `off` |
| `MCL_GROUP_ROTATE_MS` | Epoch rotation interval, default 900000 |
| `MCL_GROUP_REMOVED_FILE` | The removed set, default `/var/lib/mcl-distributor/removed_members` on the service's named volume |
| `MCL_REALM`, `MCL_REALM_KEY`, `MCL_REALM_NAME` | The realm this service lives in (as every mcl-* service) |

The ids above are exactly 64 hex characters, or the service refuses to boot. Everything above is public material; the only secret is the node identity key in the mounted secrets volume.

## Trust and blast radius

A distributor gets its power only through the org's delegation, and the damage a rogue one can do is capped at that org's groups for the current epoch: it cannot claim another org's procedure (the D25 chain verifies against the realm key), cannot hand out keys in the clear, cannot forge publications, and cannot capture members already pinned to the honest distributor. Run it for your own org, keep delegations revocable, and the mesh isolates everyone else from it.
