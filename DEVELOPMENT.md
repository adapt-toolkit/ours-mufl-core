# Developing ours-mufl-core

This repo is the shared agent-to-agent protocol for [ours.network](https://ours.network),
written as pure MUFL (`.mm`) libraries. There is **no standalone build**: the
libraries are vendored as a submodule and compiled into each consumer's packet
(see [README.md](./README.md)). This document covers the protocol architecture,
how the code is compiled, and how to extend it safely.

## 1. Protocol / architecture

The network is a set of identities (roots and their delegated roles) that
exchange end-to-end-encrypted messages over a broker/relay. These libraries
define the wire format and the verification logic; the host application (daemon,
browser, connector) only moves bytes and supplies storage hooks.

### Wire shapes (`a2a_protocol`, `a2a_capabilities`)

All cross-node data is structural MUFL records, consumed by field key and by
`_value_id` over values — so **moving a shape between libraries never changes its
bytes, but renaming or retyping a `$field` does.** The core shapes are:

- **Invites, delegation certificates, root profiles, contact roots, local-book
  introduction credentials, and control-plane governance attestation** live in
  `a2a_protocol.mm`, together with their verification helpers
  (`verify_peer_delegation`, `rebuild_peer_address_document`,
  `verify_cp_attestation`, `verify_root_cp_binding`).
- **The app manifest** (`app_manifest_t`: `app_id` + name + a typed capability
  map) is defined in `a2a_capabilities.mm` and read via `get_manifest`.

### Capability / dispatch model (`a2a_capabilities`, `a2a_control`)

Control traffic is uniform. One opaque transport already exists —
`a2a_control::send_control($contact, $payload)` outbound, inbound
`a2a_control::control_message` (the `$on_control_received` seam). Every command
is a **capability envelope**:

```mufl
metadef control_envelope_t: ($cap -> str, $verb -> str, $args -> str, $req_id -> str).
```

- `$cap` — the capability id (`core.cluster`, `core.monitoring`, `core.connect`,
  `core.configuration`).
- `$verb` — the verb within that capability.
- `$args` — an **opaque JSON object**, schema per verb (`"{}"` when none).
- `$req_id` — correlates the response, returned by `(sender_id, $req_id)`.

The inbound seam authorizes the envelope **once** at a single pre-dispatch
chokepoint, then routes via `a2a_capabilities::dispatch`, which keys **only on
`$cap`** to `handlers[$cap]`. Verbs stay a documented convention — the wire
carries opaque `$verb`/`$args` strings, so reserving a capability adds one
constant plus a contract, with no wire/type/dispatch change.

Forced monitoring is split across two libraries: the node-side gate state and
bind ceremony live (`hidden`) in `a2a_messaging`, while `a2a_monitoring` holds
the control-plane **receiver** side (`receive_monitoring_copy`, known-contact
only). Cluster/subagent management is the `core.cluster` surface in
`a2a_cluster`.

**Authoritative contracts:**
- [`CLUSTER_API.md`](./CLUSTER_API.md) — the FROZEN control-protocol-over-MUFL
  contract: the envelope, the authz chokepoint, per-verb auth classes, host
  hooks, idempotency, and protocol-version negotiation.
- [`CLUSTER_CONTRACT.md`](./CLUSTER_CONTRACT.md) — the `core.cluster` verb
  contract (verb → reference handler/composition → wire alias) and its
  guardrails.

Companion design/plan docs in this repo (`CONFIGURATION_PLAN.md`,
`EPHEMERAL_INVITE_PLAN.md`, `GROUP_CHAT_DESIGN.md`, `CLUSTER_INTRODUCTION_PLAN.md`)
record the rationale behind individual feature sets, and `release-notes/` tracks
what shipped per core version.

## 2. How to build / compile

The core is never compiled alone — a consumer compiles it as part of its own
packet. The flow every consumer uses:

1. **Vendor the core** at `<app>/mufl_code/core/` (submodule).
2. **Merge exports.** The consumer's top-level `config.mufl` pulls the MUFL
   stdlib and this repo's exports together:

   ```mufl
   config script
   {
       stdlib_config = (config_load #$MUFL_STDLIB_PATH).
       core_config   = (config_load #"core").
       (
           $imports -> ( $libraries -> (stdlib_config $exports $libraries)'(core_config $exports $libraries), ),
           $exports -> ( $libraries -> (,), $applications -> (,) )
       ).
   }
   ```

   This repo's own [`config.mufl`](./config.mufl) is what `config_load #"core"`
   resolves; it exports `version`, `a2a_capabilities`, `a2a_protocol`,
   `a2a_messaging`, `a2a_cluster`, `a2a_monitoring`, and `a2a_control`.
3. **Compile** with the ADAPT toolkit. Consumers wrap this in a
   `scripts/compile-mufl.sh`; the underlying invocation is:

   ```sh
   MUFL_STDLIB_PATH="$ADAPT_TOOLKIT/mufl_stdlib" \
     "$ADAPT_TOOLKIT/build.linux.release/mufl-compile" \
     -mp "$ADAPT_TOOLKIT/meta" -mp "$ADAPT_TOOLKIT/transactions" \
     <top-level>.mu
   ```

   `ADAPT_TOOLKIT` points at the toolkit root (the `mufl-compile` binary, plus
   `mufl_stdlib`, `meta`, and `transactions`). The application then loads the
   libraries by name (`application actor loads libraries ..., a2a_protocol,
   version uses transactions`).

### Tests

The behavioural test suite ([`tests/`](./tests/)) compiles a self-contained
`test_actor.mu` against this repo's core, boots a local broker, and runs a
loopback driver asserting receiver-side state. It needs external tooling (the
ADAPT toolkit, a consumer's `@adapt-toolkit` Node SDK, and `dev-broker.mjs`),
overridable by env:

```sh
ADAPT_TOOLKIT=/path/to/adapt-toolkit \
OURS_SDK_NODE_MODULES=/path/to/ours-mcp/node_modules \
DEV_BROKER=/path/to/ours-mcp/scripts/dev-broker.mjs \
PORT=9799 ./tests/run.sh
```

Exit 0 = all green; see [`tests/README.md`](./tests/README.md) for the scenarios
and invariants exercised.

## 3. How to extend

### Add a new capability module

1. Create `a2a_<name>.mm` defining a `library a2a_<name>` with its shapes and
   transactions. Keep wire shapes structural; gate behind the capability so
   nodes that do not ship it are unaffected.
2. Reserve a capability constant (e.g. `cap_<name>`) and, in the consuming app,
   wire a handler under that constant in `a2a_capabilities::init`'s `$handlers`
   map and list it in `describe()`, gated with `self_supports(cap_<name>)` —
   exactly as `core.connect` / `core.cluster` are wired. `dispatch()` routes by
   `$cap` only, so no dispatch change is needed.
3. **Export it.** Add the module to [`config.mufl`](./config.mufl) under
   `$exports $libraries` so `config_load #"core"` resolves it.
4. Document the verb surface (a contract doc like `CLUSTER_CONTRACT.md`) and add
   a `release-notes/` entry.

### Adding to an existing module

Prefer adding new shapes/helpers (a backward-compatible **MIN** bump) over
changing existing ones. Never rename or retype an existing `$field`, and never
change the bytes of a shape that is already on the wire — that is a **MAJ** bump
and a protocol break for every deployed client.

### Bump the version (required, same commit)

Every change to this repo updates `core_version` in [`version.mm`](./version.mm)
in the **same commit**:

```mufl
core_version = create_version 0 0 1.   // MAJ MIN PATCH
```

- **PATCH** — fixes with no wire-shape or verification-semantics change.
- **MIN** — backward-compatible additions (new shapes, new helpers, new module).
- **MAJ** — any change to the bytes of an existing wire shape or to existing
  verification semantics.

Both consumer packets expose the compiled-in value via their read-only
`get_version` transaction, so the deployed core version is observable at runtime.
