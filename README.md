# mcl-distributor

[![CI](https://img.shields.io/github/actions/workflow/status/macula-services/mcl-distributor/lint.yml?branch=main&label=CI)](https://github.com/macula-services/mcl-distributor/actions/workflows/lint.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![BEAM](https://img.shields.io/badge/beam-28%2B-A90533?logo=erlang&logoColor=white)](https://www.erlang.org)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub%20Sponsors-support-ea4aaa.svg?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/rgfaber)

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

The group-key distributor for [Macula](https://github.com/macula-io/macula)'s sealed pubsub: a single-purpose service that advertises `<org>/group_keys_v1` and answers the sealed pulls every group member makes at join and at each epoch rotation. The design it implements is [`DESIGN_E2E_SEALED_PUBSUB.md`](https://github.com/macula-io/macula/blob/main/docs/design/DESIGN_E2E_SEALED_PUBSUB.md); the distributor itself is the SDK's `macula_group_keys`, started here with this service's deploy config.

**What it is not:** it is not in the data path. Events flow publisher → stations → subscribers whether or not the distributor is up. Popped, members holding the current epoch go on publishing and opening; new joins and rotations fail closed until it returns.

**What it holds:** each group's epoch keys, in memory only, rotated every `MCL_GROUP_ROTATE_MS` (default 15 minutes). Keys never travel readable by a station: the pull is a sealed call (`confidential => required`), refused in the clear by the link before the handler runs.

**What it decides:** membership, per pull, against the realm slot (`MCL_REALM` + `MCL_GROUP_REALM_KEY_ID`) and the org's `group_keys` UCAN (the procedure's `auth` policy, checked by the link). The removed set is in memory; a revoked member is refused every epoch.

## Deploy config

| Env | Meaning |
|---|---|
| `MCL_GROUP_ORG` | The org whose groups this service distributes; also the procedure's namespace (`<org>/group_keys_v1`) |
| `MCL_GROUP_ORG_KEY_ID` | The org's PUBLIC key id (hex), the `realm_member_required` policy matches the caller's UCAN issuer against |
| `MCL_GROUP_REALM_KEY_ID` | The realm key id (hex) the membership check pins the realm slot to |
| `MCL_GROUP_POLICY` | `required` (default), `preferred`, or `off` |
| `MCL_GROUP_ROTATE_MS` | Epoch rotation interval, default 900000 |
| `MCL_REALM`, `MCL_REALM_KEY`, `MCL_REALM_NAME` | The realm this service lives in (as every mcl-* service) |

Everything above is public material; the only secret is the node identity key in the mounted secrets volume.

## Trust and blast radius

A distributor gets its power only through the org's delegation, and the damage a rogue one can do is capped at that org's groups for one epoch: it cannot claim another org's procedure (the D25 chain verifies against the realm key), cannot hand out keys in the clear, cannot forge publications, and cannot capture members already pinned to the honest distributor. Run it for your own org, keep delegations revocable, and the mesh isolates everyone else from it.
