# Invites & contacts

Contact establishment uses a **slim ephemeral-key invite** (core 3.0). The invite blob carries
only an ephemeral encryption pubkey, the inviter's container id, a display name, and a crypto
scheme id — no long-term keys, no self-signatures. Identity material moves inside two encrypted
messages exchanged after the initial out-of-band transfer.

Source: [`a2a_messaging.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_messaging.mm).

## Invite shape

```
metadef invite_eph_t: (
    $d -> global_id,          -- invite id (correlates legs; single-use)
    $c -> global_id,          -- inviter container id
    $n -> str,                -- inviter display name
    $k -> publickey_encrypt,  -- inviter ephemeral pubkey
    $v -> int                 -- crypto scheme id
).
```

Generate an invite with `generate_invite`. The returned blob is the value to share out-of-band
(QR code, deep link, etc.).

## Three-leg redeem flow

| Leg | Direction | Mechanism | What moves |
|-----|-----------|-----------|------------|
| OOB | inviter → responder | out-of-band | slim `invite_eph_t` blob |
| Leg 1 | responder → inviter | BARE send (box to invite's eph pub) | responder identity bundle |
| Leg 3 | inviter → responder | BARE send (box to responder's eph pub) | inviter identity bundle |

Both boxes carry the same identity bundle shape: address document + optional delegation cert +
optional root profile + optional §3c CP binding. After leg 3, both sides hold the other's
verified address document and `encrypted_channel` resumes for all subsequent traffic.

Redeem an invite with `add_contact` (leg 1). The inviter processes the responder's leg 1 in
`submit_invite_response` (leg 2 internally) and replies with leg 3 (`complete_invite`).

## Single-use guarantee

An invite is consumed on the first valid leg-2 reception. A second attempt for the same
`invite_id` aborts with `already-redeemed` and mutates no state. The ephemeral private key is
deleted atomically with the invite record (INV-4: secrets are never exported).

Test suite scenario T3 (`single-use`) asserts a second leg-1 for the same `invite_id` aborts
and leaves inviter state unchanged. Scenario T4 (`invalid-then-valid`) asserts that a failed
box-open does not consume the invite, so a subsequent valid redeem succeeds. See
[`tests/README.md`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/tests/README.md).

## Pending-invite transience

Responder-side pending redemption state (`pending_redemptions`) is not exported and does not
survive a daemon restart. An interrupted handshake does not leave half-registered state; the
responder must run `add_contact` again with a fresh invite. This is the fail-closed design: no
dangling partial contacts after a restart.

## Introductions via core.connect

When two nodes share a control plane that advertises `core.connect`, the CP can introduce them
without another out-of-band invite. The CP sends each node the other's signed address document
via `ingest_connect_descriptor`. The receiving node verifies:

1. The relay came from its bound CP (or the CP its root designated).
2. Its own live manifest advertises `core.connect`.
3. The peer's address document self-signature is valid (proof-of-possession).

The contact is registered immediately — no SAS, no confirmation step.

Scenario T1 (`happy-flat`) verifies the end-to-end invite + `send_message` round-trip in both
directions. Scenarios T5–T8 cover adversarial inputs (tampered box, cid-bind mismatch, stripped
PoP, unexpected inviter on leg 3). See
[`tests/README.md`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/tests/README.md).
