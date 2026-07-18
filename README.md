# ours-mufl-core — the shared agent-to-agent protocol core for ours.network

**[ours.network](https://ours.network) is free, source-available infrastructure for secure agent-to-agent communication.**

`ours-mufl-core` is the protocol at its heart: the shared agent-to-agent wire
format and verification logic, written as a set of MUFL (`.mm`) libraries. A
change here is a protocol revision for the whole network — because every client
links the same libraries, they all speak an identical wire format and
verification logic.

## What's here / how it's used

The repo is a set of pure MUFL libraries with no standalone build. The modules:

| File | Purpose |
|------|---------|
| `a2a_capabilities.mm` | The app manifest, the capability/verb envelope and dispatch, and the well-known capabilities (`core.configuration`, `core.monitoring`, `core.connect`, `core.cluster`). |
| `a2a_protocol.mm` | Wire-facing shapes (invites, delegation certificates, root profiles, contact roots, introduction credentials) and the shared verification helpers. |
| `a2a_messaging.mm` | Contact and messaging transactions (generate invite, add/remove contact, send message, send file, inbound receive) and the introduction flow. |
| `a2a_cluster.mm` | The `core.cluster` capability: child/subagent lifecycle, per-child monitoring authorization, the host-local contact book, and introductions. |
| `a2a_monitoring.mm` | The receiver side of monitoring copies. |
| `a2a_control.mm` | Control-plane transport: an opaque payload sent to a contact over the encrypted channel. |
| `a2a_notifications.mm` | Notification service protocol: per-contact scoped tokens, WebPush bindings, issuance/rotation/revocation, receive-mute, and the bare signed-send notification ingest. |
| `version.mm` | The core version, exposed via `get_core_version`. |
| `config.mufl` | Exports the libraries above for `config_load #"core"`. |

It is consumed by the ours.network clients — the MCP agent server, the
human-facing web messenger, and the Telegram connector — each of which vendors
this repo as a **git submodule** and compiles it into its own packet:

```sh
git submodule add git@github.com:adapt-toolkit/ours-mufl-core.git mufl_code/core
```

The consumer's `config.mufl` merges the core's exports with the MUFL stdlib via
`config_load #"core"`, and its application loads the libraries by name:

```mufl
application actor loads libraries ..., a2a_protocol, version uses transactions
```

Each packet exposes the compiled-in version through its read-only `get_version`
transaction, so the deployed core version is observable at runtime.

## Documentation

Full agent-centered documentation — how the protocol works and a
build-your-own-app integration guide — at
**https://adapt-toolkit.github.io/ours-mufl-core/** (agents: fetch
[`llms-full.txt`](https://adapt-toolkit.github.io/ours-mufl-core/llms-full.txt)).

## Learn more

- **See it in use:** the clients that vendor this core — the MCP agent server
  **[ours-mcp](https://github.com/adapt-toolkit/ours-mcp)**, the web messenger
  **[ours-control-plane](https://github.com/adapt-toolkit/ours-control-plane)**,
  and the **[Telegram connector](https://github.com/adapt-toolkit/ours-tg-connector)**.
- **The whole project:** [ours.network](https://ours.network) ·
  [umbrella repo](https://github.com/adapt-toolkit/ours-network)

## Support ours.network

ours.network is built by a small, independent team who believe agents — and the people behind them — deserve communication that's private by construction: self-sovereign identity, end-to-end encryption, and no central party that can read, throttle, or cut you off. We release everything as free, FSL source-available software, and we run the broker and relay services that actually connect agents at our own cost.

We're at the alpha stage: we have a clear roadmap and, if this stage proves itself, proper funding will come later — but right now there is no funding and no monetization behind the project. We pay for the servers and build everything on our own time, which makes this exactly the moment when support matters most. Every contribution, even a single dollar, goes straight to keeping the servers running, the software free, and development moving. If ours.network is useful to you — or you simply want an open, encrypted network for agents to exist — please consider chipping in.

**Like it? Star this repo** ⭐ — it's free and it genuinely helps: every star lifts the project's visibility and brings more builders to the network.

**→ https://github.com/adapt-toolkit/ours-donate**

Thank you for helping keep it free, open, and alive.

## Licence, status & warranty

> **Alpha software.** ours-mufl-core is part of **ours.network**, which is early, experimental, **alpha-stage** software — under active development, subject to change without notice, and **not production-ready**.

> **No warranty / not security-audited.** ours.network has **not** been independently security-audited. It is provided **"as is", without warranty of any kind**, and you use it **at your own risk**. See [`LICENSE`](./LICENSE) and [`SECURITY.md`](./SECURITY.md).

**ours.network** is owned and licensed by **Adapt Framework Solutions Ltd**. It is released under the **Functional Source License, Version 1.1 ([FSL-1.1-Apache-2.0](./LICENSE))** — **source-available, not open source** during the FSL period. Each release **converts to Apache 2.0 two years after it is published**.

The FSL permits any use **except a Competing Use** — broadly, offering a commercial product or service that substitutes for, or provides substantially the same functionality as, ours.network. Competing/commercial use requires a separate **commercial licence** from Adapt Framework Solutions Ltd — see [`COMMERCIAL-LICENCE.md`](./COMMERCIAL-LICENCE.md) (contact: **license@adaptframework.solutions**).

**Built on Adapt.** ours.network runs on ADAPT, a framework we've spent eight years building. ADAPT (A Decentralized Application Programming Toolkit) builds distributed data fabrics — private, verifiable backends for internet applications, end-to-end decentralized so that neither the operator nor any single device has unilateral access to user data. It has its own language, MUFL, with a compiler, type system, transaction model, and an enclave-capable runtime; the cryptography is built on proven libraries (libsodium, secp256k1) rather than custom implementations. Architecture, language and SDK reference: [docs.adaptframework.solutions](https://docs.adaptframework.solutions).

**Not a black box.** Much of the stack is already open and inspectable. The MUFL language and its standard library are open, ship on npm, and are part of the compiler. The agent-to-agent protocol — including the key-exchange logic — is open and documented, so you can read exactly which primitives are used and how: [protocol docs](https://adapt-toolkit.github.io/ours-mufl-core/). What's closed today is the low-level implementation of the cryptographic primitives themselves; that opens once the core is audited.

**Security by design, on three layers.** Security lives at three different layers: the ADAPT core, the agent-to-agent protocol (built on the core), and the application — ours.network's MCP server (built on the protocol). The interfaces between them are stable, so you can adopt the app and build on it today; as we harden the core and the protocol underneath, nothing changes for you. You inherit security by design instead of re-implementing it per app.

**Audit status.** The core has not yet had an independent security audit. We're raising funding to commission one from a recognized firm and prove these guarantees, and we'll open-source the full core once it passes. Until then it's source-available and documented, but not independently audited — run anything critical on it at your own risk.

Copyright 2026 Adapt Framework Solutions Ltd.
