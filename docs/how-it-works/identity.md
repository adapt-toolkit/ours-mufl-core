# Identity: roots & roles

An identity in ours.network is either a **root** — a self-sovereign keypair — or a **delegated
role** anchored to a root. A root's `delegation_cert` field is `NIL`; detection is structural,
not a flag. A role carries a signed `delegation_cert_t` that binds the role's container id and
address-document hash to its root, signed by the root's keys.

Source: [`a2a_protocol.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_protocol.mm).

## Delegation verification

When a peer presents its identity during invite redemption, verify the full chain with
`verify_peer_delegation`:

```
fn verify_peer_delegation (
    peer_cid:    global_id,
    peer_ad_hash: hash_code,
    cert:         delegation_cert_t,
    rp:           root_profile_t
) -> contact_root_t
```

The root profile carries the root's key list, so no prior knowledge of the root is needed. On
success the function returns a `contact_root_t` (root container id, root name, role id) to store
beside the contact. Any mismatch — wrong version, mismatched cid, bad signature — aborts.

## Control-plane governance (§3c)

Two verifiers support the optional non-enforcing governance edge between a root and its control
plane:

- **`verify_cp_attestation`** — verifies the CP's signed attestation that it governs a given
  root. Requires the caller to have run `process_address_document` on the CP's address document
  first.
- **`verify_root_cp_binding`** — verifies the root's self-signed edge naming the CP, domain-
  separated by `cp_attestation_context_tag`. The authoritative monitoring gate remains the
  6-digit bind ceremony; these verifiers let peers TOFU-pin the governance edge without an extra
  round-trip.

Source: [`a2a_protocol.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_protocol.mm).

## Wire shapes and the structural-records rule

All identity wire shapes are MUFL record types defined in `a2a_protocol.mm`. The key protocol
guarantee is: moving a shape between libraries never changes its bytes; renaming or retyping a
`$field` does. Field names are the version boundary. Example shapes:

```
metadef delegation_cert_t: ($c -> delegation_core_t, $s -> crypto_signature).
metadef root_profile_t:    ($p -> root_profile_core_t, $s -> crypto_signature).
metadef root_cp_binding_t: ($c -> root_cp_binding_core_t, $s -> crypto_signature).
```

The invite shape carries no identity keys — identity material moves inside the encrypted
two-message redeem hop (see [Invites & contacts](./invites-and-contacts.md)).
