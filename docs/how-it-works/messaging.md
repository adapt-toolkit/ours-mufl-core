# Messaging

All message and file traffic between contacts rides the `encrypted_channel`, established during
invite redemption and persisted across restarts by replaying stored peer address documents on
import. `a2a_messaging.mm` is the single path for all send/receive operations.

Source: [`a2a_messaging.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_messaging.mm).
Module description: [`README.md`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/README.md)
— "Contact and messaging transactions (generate invite, add/remove contact, send message, send
file, inbound receive) and the introduction flow."

## Outbound

- **`send_message`** — sends text to a named or container-id-referenced contact. Accepts an
  optional `reply_to` pointer (`$wire_id`, `$sentence`) for threaded replies. Every message
  receives a stable `wire_id` (a stringified `_new_id`) that the peer can reference in its own
  replies.
- **`send_file`** — sends binary data with a `$filename` and optional `$mime`. Files and text
  messages share the same `wire_id` namespace; a reply pointer can reference either.

Both fail if the contact has no registered address document (see Contact-restore below).

## Inbound

| Transaction name | Source constant | Payload |
|-----------------|-----------------|---------|
| `::actor::receive_message` | `receive_message_tx` | `$text`, `$wire_id`, optional `$reply_to`, sender id from envelope |
| `::a2a_messaging::receive_file` | `receive_file_tx` | `$filename`, `$mime`, `$data`, `$wire_id`, optional `$reply_to` |

The core fires the app-injected `on_message_received` / `on_file_received` storage hooks.
Message storage is the consumer's responsibility; the core handles wire, validation, and contact
resolution.

## Receiver-side state

`contacts` (keyed by container id) and `peer_ads` (keyed by container id) are the persistent
contact state. `encrypted_channel` resolves the peer's encryption key from `peer_ads` on every
send. `peer_ads` entries survive code upgrades because `import_core_state` replays each stored
address document through `process_address_document` — no re-handshake is needed.

## Contact-restore across breaking changes

If a migration carries `contacts` but drops `peer_ads` for a contact, that contact becomes a
**DEGRADED contact** (cid present, no address document). `send_message` to a degraded contact
queues the message and fires a `request_contact_restore` handshake to re-fetch the peer's
address document. Once the peer's AD is re-established, queued messages flush automatically.

`send_file` to a degraded contact fails fast with an explicit error — binary payloads are not
queued. `send_message` toward the same contact will queue and drive the restore.

See [Identity: roots & roles](./identity.md) for the address document and key structure that
`encrypted_channel` depends on.
