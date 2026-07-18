# Contact exchange (invite redeem)

Two strangers become mutual contacts through a **slim ephemeral-key invite** and a three-leg
redeem handshake. The invite blob itself carries no identity material — only an ephemeral
pubkey and correlation data (see [Invites & contacts](../how-it-works/invites-and-contacts.md)
for the invite shape). Identity bundles move inside boxes on legs 1 and 3, both of which are
**bare sends**: the two sides are not each other's contacts yet, so the encrypted channel
cannot carry them.

Traced from [`a2a_messaging.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_messaging.mm)
(`generate_invite` / `mint_eph_invite`, `add_contact`, `handle_submit_invite_response`,
`handle_complete_invite`).

```mermaid
sequenceDiagram
    autonumber
    participant IH as Inviter host
    participant I as Inviter packet
    participant R as Responder packet
    participant RH as Responder host

    IH->>I: generate_invite ($name)
    Note over I: mint_eph_invite - fresh ephemeral keypair.<br/>pending_invites[id] = pub half + assigned name.<br/>pending_invite_keys[id] = private half (hidden, never exported)
    I-->>IH: $invite blob, $invite_id

    Note over IH,RH: invite blob travels out-of-band (QR, link, chat)

    RH->>R: add_contact ($invite, $name)
    Note over R: LEG 1 - fresh responder ephemeral keypair.<br/>Box my identity bundle to the invite's eph pubkey.<br/>pending_redemptions[id] + pending_redemption_keys[id]
    R->>I: submit_invite_response ($invite_id, $epk, $v, $data) - bare boxed send

    Note over I: LEG 2 gates, in order, no writes until all pass:<br/>pending lookup (single-use) - box-open -<br/>cid-bind + PoP self-sig - optional delegation chain
    Note over I: register contact + peer_ads, consume<br/>pending_invites + pending_invite_keys atomically
    I->>R: complete_invite ($invite_id, $epk, $v, $data) - bare boxed send
    I-->>IH: notify $contact_accepted

    Note over R: LEG 3 gates: pending lookup - expected-inviter<br/>cid pin - box-open with kept eph key -<br/>cid-bind + PoP - optional chain
    Note over R: register contact + peer_ads, clear<br/>pending_redemptions + pending_redemption_keys
    R-->>RH: notify $contact_added

    Note over I,R: both sides registered - encrypted_channel carries all further traffic
```

## Key properties visible in the flow

- **Single-use**: the first valid leg 2 consumes `pending_invites[id]` *and*
  `pending_invite_keys[id]` together. A replayed leg 1 aborts with `already-redeemed` and
  mutates nothing; a leg 1 that fails a gate (bad box, forged bundle) consumes nothing.
- **Disclosure order**: the responder discloses its identity first (leg 1); the inviter answers
  with its own bundle only after the responder's bundle verified (leg 3).
- **Why bare sends**: on leg 1 the inviter is not registered on the responder side (and vice
  versa on leg 3), so `send_encrypted_tx` could not resolve a source key. The box to the
  ephemeral key is the confidentiality; envelope signing plus the cid-bind and
  proof-of-possession checks are the authenticity.
- **Role invites**: when either side is a delegated role, its bundle also carries the delegation
  cert, root profile, and optional root-CP binding — verified with `verify_identity_bundle`, so
  each side learns the other's verified root linkage (`contact_roots`).

An invite can also be minted for a hosted child via the cluster `contact` verb — same
construction path (`mint_eph_invite`), see [Cluster lifecycle](./cluster.md).
