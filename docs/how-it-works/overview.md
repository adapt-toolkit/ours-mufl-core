# Overview

ours-mufl-core is the shared wire format and verification logic for the ours.network protocol,
written as MUFL (`.mm`) libraries. Every ours.network client — agent server, web messenger,
Telegram connector — vendors this repo as a git submodule and compiles the same libraries into
its own packet. Because all clients link the same code, they speak an **identical wire format**
and verification logic: a packet built by the web client and one built by the MCP agent are
byte-compatible peers.

The host application boots packets, routes inbound messages, and persists state. The protocol
libraries define what is valid; the host only moves bytes.

## Consuming the core

Add the repo as a submodule to your application:

```sh
git submodule add git@github.com:adapt-toolkit/ours-mufl-core.git mufl_code/core
```

Your `config.mufl` loads it with `config_load #"core"`. The full setup is in
[01 · Vendor the core](../guide/01-vendor-the-core.md).

## Modules at a glance

Seven `.mm` libraries and one config export. See [Modules](../reference/modules.md) for
per-module transaction listings.

| File | Role |
|------|------|
| [`a2a_protocol.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_protocol.mm) | Wire shapes (invites, certs, profiles) and verification helpers |
| [`a2a_messaging.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_messaging.mm) | Invite, contact, send/receive message, and send/receive file transactions |
| [`a2a_capabilities.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_capabilities.mm) | App manifest, verb dispatch, well-known capabilities |
| [`a2a_cluster.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_cluster.mm) | Child lifecycle, host-local contact book, cluster management |
| [`a2a_monitoring.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_monitoring.mm) | Monitoring copy receiver (CP side) |
| [`a2a_control.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_control.mm) | Control-plane transport |
| [`version.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/version.mm) | Core version, readable at runtime via `get_core_version` |

Source: [`README.md`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/README.md).

## Next steps

- [Identity: roots & roles](./identity.md) — delegation hierarchy and verification
- [Invites & contacts](./invites-and-contacts.md) — ephemeral-key invite and redeem flow
- [Messaging](./messaging.md) — send, receive, and contact-restore
