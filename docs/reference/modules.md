# Modules

The core is seven `.mm` libraries and one config export loaded by `config_load #"core"` from a consumer's
`config.mufl`. The source is the authoritative reference; the
[how-it-works](../how-it-works/overview.md) pages explain the protocol design behind each module.

| File | Purpose |
|------|---------|
| [`a2a_capabilities.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_capabilities.mm) | App manifest, capability/verb envelope and dispatch, well-known capability ids (`core.configuration`, `core.monitoring`, `core.connect`, `core.cluster`). |
| [`a2a_protocol.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_protocol.mm) | Wire-facing shapes (invites, delegation certificates, root profiles, contact roots, introduction credentials) and the shared verification helpers. |
| [`a2a_messaging.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_messaging.mm) | Contact and messaging transactions: invite generation/redemption, add/remove contact, send message, send file, inbound receive, and the introduction flow. |
| [`a2a_cluster.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_cluster.mm) | The `core.cluster` capability handler: child/subagent lifecycle, per-child monitoring authorization, host-local contact book, and introductions between children and contacts. |
| [`a2a_monitoring.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_monitoring.mm) | Control-plane receiver side of monitoring copies: validates sender and hands the copy to the app's storage hook. |
| [`a2a_control.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_control.mm) | Control-plane transport: an opaque payload delivered to a contact over the `encrypted_channel`, validated on receipt. |
| [`version.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/version.mm) | Core version record, readable at runtime via `get_core_version`. |
| [`config.mufl`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/config.mufl) | Compile configuration: exports the libraries above for `config_load #"core"`. |

Source: [`README.md`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/README.md).
