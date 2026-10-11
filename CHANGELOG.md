# Changelog

## 0.1.0 (2026-10-11)

- **The group-key distributor as a service:** `macula_group_keys` under mcl_om, advertising `<org>/group_keys_v1` with the `realm_member_required` `group_keys` policy and `confidential => required`, the default realm-slot membership, and the `{mcl_distributor_pull, pull}` handler forwarding to the registered distributor.
