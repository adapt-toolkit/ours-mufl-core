# Contact restore

A **degraded contact** is a cid present in `contacts` but missing from `peer_ads` — typically
after a breaking-change migration carried the contact but had to drop its address document.
Contact restore re-runs the key exchange between two *mutually known* addresses: the same
machinery as the invite legs (identity bundle, box to an ephemeral key, gates before any
write), but the trust anchor is "a signed request from an address already in my contacts"
instead of an out-of-band invite token.

Traced from [`a2a_messaging.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_messaging.mm)
(`begin_contact_restore`, `handle_request_contact_restore`, `handle_submit_restore_response`,
`handle_complete_restore`, `flush_deferred`, `restore_degraded_contacts`).

```mermaid
sequenceDiagram
    autonumber
    participant H as Requester host
    participant A as Requester packet (degraded contact for B)
    participant B as Responder packet (still holds A in contacts)

    Note over H,A: trigger: send_message toward the degraded contact<br/>(queues into deferred_msgs) OR the host boot/GC sweep<br/>restore_degraded_contacts (up to 30 attempts per contact)
    Note over A: begin_contact_restore - fresh ephemeral keypair + $rid.<br/>pending_restores[B] (replaces any outstanding attempt)
    A->>B: LEG 0 request_contact_restore ($rid, $epk, $v) - bare signed send

    Note over B: gate: sender in contacts - else SILENT no-op<br/>(no error reply, so address knowledge never leaks)
    Note over B: pending_restore_replies[A] + fresh reply eph keypair.<br/>Nothing installed or replaced yet
    B->>A: LEG 1 submit_restore_response ($rid, $epk, $v, $data) - B's bundle boxed to A's eph key

    Note over A: gates: pending lookup - $rid pin - box-open -<br/>cid-bind + PoP - optional chain
    Note over A: reinstall peer_ads[B], consume pending_restores single-use
    A->>B: LEG 2 complete_restore ($rid, $epk, $v, $data) - A's bundle boxed to B's reply eph key
    A-->>H: notify $contact_restored

    Note over B: gates: reply lookup - $rid pin - box-open - cid-bind + PoP - chain
    Note over B: REPLACE peer_ads[A] (a reseeded peer rolls fresh keys,<br/>so even a present-but-stale document must be replaced)
    B-->>B: notify $contact_restored (to its own host)

    H->>A: flush_deferred ($contact) - host-driven on the notify
    A->>B: receive_message x queued - encrypted channel, original wire_ids preserved
```

## Why the pieces are shaped this way

- **Leg 0 is unboxed** (just `$rid`, an ephemeral pubkey, and a scheme id): there is nothing
  secret to carry yet, and the framework signs every envelope, so the responder authenticates
  the requester from the envelope alone.
- **Silent no-op for strangers**: a request from an address not in `contacts` returns success
  with no actions — whether an address is known never leaks.
- **The flush is host-driven**, not automatic: firing `flush_deferred` on the
  `$contact_restored` notify means the encrypted sends can never race the restore legs' bare
  sends on the wire.
- **Retry budget**: the host sweep re-fires on its GC cadence, up to `restore_max_attempts`
  (30) per contact; a peer that upgraded and came back online answers on the first
  post-upgrade attempt. Each re-mint supersedes the previous ephemeral key, so a stale leg-1
  reply fails both the `$rid` check and the unbox.
- **Observability**: `list_degraded_contacts` and `list_deferred_queues` are the readonly
  views the host sweep keys off.

This flow is what makes contacts survive breaking changes — see the migration contract in
[Versioning](../how-it-works/versioning.md).
