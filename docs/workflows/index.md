# Transaction flows

Each page in this section traces **one conceptual protocol workflow** as a sequence diagram:
which transaction invokes which, how the call leaves the node, and how the result comes back.
Every arrow is labeled with the real transaction or function name from the `.mm` source — the
diagrams are traced from the code, not from a design document.

## How to read the diagrams

**Participants.** A *packet* is the compiled MUFL protocol container of one identity. A *host*
is the daemon embedding that packet (the reference host is the ours MCP daemon). A *control
plane* (CP) is a peer node bound via the monitoring ceremony. Arrows between two packets are
network sends; delivery is the ADAPT framework's job — if the receiver is offline, the ADAPT
broker holds the pending message.

**Transaction origins.** Every transaction validates its origin first
(`current_transaction_info::validate_origin_or_abort`):

| Origin | Meaning | Drawn as |
|--------|---------|----------|
| `origin::user` | fired by the local host/daemon on behalf of the operator | `Host ->> Packet` |
| `origin::external` | arrived from the network (envelope carries the authenticated sender in `$from`) | `Packet A ->> Packet B` |

**Send mechanisms.** Two kinds of arrows leave a packet:

- **Encrypted-channel send** (`encrypted_channel::send_encrypted_tx`) — the normal path between
  registered contacts; requires the peer's address document in `peer_ads`.
- **Bare send** (`transaction::action::send`) — used only when the peer is *not yet* (or no
  longer) resolvable as a contact: the invite redeem legs and the contact-restore legs. Payload
  confidentiality then comes from a box to an ephemeral key carried in the flow itself, and the
  framework signs every envelope, so the receiver still authenticates the sender.

**Results.** A transaction returns *actions*: network sends, `$data` (the caller's return
value), `$notify_agent` (an event for the host — drawn as a dashed arrow back to the host), and
`$save_state` (persist the packet — emitted only at the end of a complete step, never
mid-handshake, so a crash restores to the last stable point).

## The workflows

| Workflow | What it covers |
|----------|----------------|
| [Contact exchange](./contact-exchange.md) | `generate_invite` → `add_contact` → the three redeem legs |
| [Send & receive messages](./messaging.md) | `send_message` / `receive_message`, `send_file` / `receive_file`, storage hooks |
| [Contact restore](./contact-restore.md) | self-healing a degraded contact: restore legs 0–2 + `flush_deferred` |
| [Monitoring bind & copies](./monitoring.md) | the 6-digit bind ceremony, forced copies, disable |
| [Control-plane verb calls](./control-verbs.md) | `send_control` → `dispatch` → capability handler → response envelope |
| [Introductions](./introductions.md) | `core.connect`: a shared CP connects two nodes without an invite |
| [Cluster lifecycle](./cluster.md) | async child create via host primitives, cluster enrollment, roster push |

All flows were traced from
[`a2a_messaging.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_messaging.mm),
[`a2a_control.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_control.mm),
[`a2a_capabilities.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_capabilities.mm),
[`a2a_cluster.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_cluster.mm) and
[`a2a_monitoring.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_monitoring.mm).
