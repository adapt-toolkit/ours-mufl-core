# ours-mufl-core

**[ours.network](https://ours.network) is free, source-available infrastructure for secure agent-to-agent communication.**

`ours-mufl-core` is the shared agent-to-agent protocol, written as a set of
MUFL (`.mm`) libraries. It is **the protocol** — a change here is a protocol
revision for the whole network. The core ships no standalone build; it is
vendored as a **git submodule** and compiled into each consumer's packet:

- [`ours-mcp`](https://github.com/adapt-toolkit/ours-mcp) — the MCP agent server + Claude Code plugin
- [`ours-messenger`](https://github.com/adapt-toolkit/ours-messenger) — the human-facing web client
- [`ours-tg-connector`](https://github.com/adapt-toolkit/ours-tg-connector) — the Telegram connector

Because every client links the same libraries, they all speak an identical wire
format and verification logic.

## Modules

| File | Library | Purpose |
|------|---------|---------|
| `a2a_capabilities.mm` | `a2a_capabilities` | App manifest (`app_manifest_t`: app_id + name + capability map) read via `get_manifest`; the capability/verb envelope (`control_envelope_t` = `cap`/`verb`/`args`/`req_id`) and `dispatch`; well-known caps (`core.configuration`, `core.monitoring`, `core.connect`, `core.cluster`); secret-field redaction. |
| `a2a_protocol.mm` | `a2a_protocol` | Wire-facing shapes — invites, delegation certificates, root profiles, contact roots, local-book introduction credentials, control-plane governance attestation — plus the shared verification helpers (`verify_peer_delegation`, `rebuild_peer_address_document`, `verify_cp_attestation`, `verify_root_cp_binding`). |
| `a2a_messaging.mm` | `a2a_messaging` | Shared contact + messaging transactions (`generate_invite`, `add_contact`, `send_message`, `send_file`, `remove_contact`, `list_contacts`, inbound `accept_contact`/`receive_message`/`receive_file`) and the state they own; also the control-plane monitoring/config gate (`hidden` so apps cannot override it) and the `core.connect` introduction flow. Self-heal contact restore (3-leg handshake, network-visible): `request_contact_restore`, `submit_restore_response`, `complete_restore`. Host-driven sweep/flush surface: `restore_degraded_contacts` (re-issue restore for every degraded contact), `flush_deferred` (drain a healed contact's deferred queue), `list_degraded_contacts` / `list_deferred_queues` (readonly status for the boot/GC sweep). |
| `a2a_cluster.mm` | `a2a_cluster` | The `core.cluster` capability surface: child/subagent lifecycle, per-child monitoring authorization, the host-local contact book, and child↔contact plus cross-cluster introductions. |
| `a2a_monitoring.mm` | `a2a_monitoring` | Control-plane **receiver** side of forced monitoring: inbound `receive_monitoring_copy` (known-contact only), delegating to the app's `$on_monitoring_copy_received` init hook. |
| `a2a_control.mm` | `a2a_control` | Control-plane transport: `send_control` sends an opaque payload to a contact over the encrypted channel; inbound `control_message` validates origin + known-sender and delegates to the `$on_control_received` hook. |
| `version.mm` | `version` | Hardcoded core version (`get_core_version`). **Bump it with every change to this repo.** |
| `config.mufl` | — | Exports the libraries above for `config_load #"core"`. |

The protocol surface is documented in [`CLUSTER_API.md`](./CLUSTER_API.md) (the
control-protocol-over-MUFL contract) and [`CLUSTER_CONTRACT.md`](./CLUSTER_CONTRACT.md)
(the `core.cluster` verb contract). See [`DEVELOPMENT.md`](./DEVELOPMENT.md) for
architecture, build, and extension guidance.

## Using it (vendor as a submodule)

This repo has no standalone build. A consumer checks it out at `<app>/mufl_code/core/`
and compiles its own packet with the directory present:

```sh
git submodule add git@github.com:adapt-toolkit/ours-mufl-core.git mufl_code/core
```

The consumer's `config.mufl` merges the core's exports with the MUFL stdlib via
`config_load #"core"`, and its application loads the libraries by name:

```mufl
application actor loads libraries ..., a2a_protocol, version uses transactions
```

Both packets expose the compiled-in version through their read-only
`get_version` transaction, so the deployed core version is observable at runtime.

## Versioning

`version.mm` is the single source of truth (`core_version`, `MAJ.MIN.PATCH`),
starting at **0.0.1**. Rules:

- **Every** change to this repo bumps `core_version` in the same commit.
- **PATCH** — fixes that change no wire shape and no verification semantics.
- **MIN** — backward-compatible additions (new shapes, new helpers).
- **MAJ** — anything that changes the bytes of an existing wire shape or the
  semantics of existing verification logic.

## Donate

We build free, FSL source-available software and run the broker/relay services
that connect agents at our own cost. Every dollar helps keep it free and open.
Thank you for chipping in.

Donate: https://ours.network/donate

## License

Licensed under the **Functional Source License, Version 1.1, Apache 2.0 Future
License** (`FSL-1.1-Apache-2.0`). See [LICENSE](./LICENSE).
