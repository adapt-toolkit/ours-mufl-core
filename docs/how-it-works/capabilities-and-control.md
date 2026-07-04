# Capabilities & control

Every ours node advertises a typed app manifest — a set of named capabilities,
each with its own schema and version — and receives structured requests through a
shared control envelope. `a2a_capabilities.mm` owns the envelope definition and
dispatch; `a2a_control.mm` owns the encrypted transport that carries envelopes
between nodes.

Sources:
[`a2a_capabilities.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_capabilities.mm),
[`a2a_control.mm`](https://github.com/adapt-toolkit/ours-mufl-core/blob/main/a2a_control.mm).

## The control envelope

All inbound capability requests arrive as a `control_envelope_t` record:

```mufl
metadef control_envelope_t: ($cap -> str, $verb -> str, $args -> any, $req_id -> str).
```

- `$cap` — the stable capability id (e.g. `"core.configuration"`). Dispatch keys
  only on this field; adding a capability never changes the wire shape.
- `$verb` — the operation within that capability.
- `$args` — native-typed arguments the handler interprets per verb.
- `$req_id` — correlation token. The sender receives a `response_envelope_t`
  keyed on `(sender_id, $req_id)`. An empty `$req_id` signals fire-and-forget:
  the envelope is processed but no response is expected.

## Transport

`send_control` in `a2a_control.mm` delivers an opaque payload to a named contact
over the `encrypted_channel`. The inbound side is the `control_message`
transaction, which validates origin and sender before invoking the
`$on_control_received` hook the app wires at startup.

The `a2a_capabilities` dispatch layer sits one step above this transport: the
app adapts the opaque `control_message` payload into a `control_envelope_t`
record and calls `dispatch`.

## Dispatch and the authz chokepoint

`dispatch` enforces a single, non-bypassable pre-route authorization check
before any handler runs:

1. `control_auth_class($cap, $verb)` classifies the requested operation as
   `"bootstrap"`, `"controller"`, or `"deny"`. (`get_manifest` is a standalone
   `trn readonly` that never routes through dispatch and is not classified here.)
2. `"controller"` verbs require the stateful `authorizer` gate (wired at init via
   `a2a_messaging::authorize_control`) to confirm the sender is the bound control
   plane. The gate is fail-closed: an unset authorizer aborts rather than
   permitting the verb.
3. Unknown or unlisted cap/verb combinations always classify as `"deny"` — a new
   verb must be consciously listed in `control_auth_class` to become reachable.

Handlers run only after this chokepoint clears. They return
`transaction::action::type[]` arrays; the daemon marshals responses to JSON and
ships them — no in-MUFL JSON encoding, no ad-hoc send inside a handler.

## Well-known capability ids

Four ids are reserved in `a2a_capabilities.mm`:

| Constant | Value | Purpose |
|---|---|---|
| `cap_configuration` | `"core.configuration"` | Opaque app config, read/written only by the bound control plane. |
| `cap_monitoring` | `"core.monitoring"` | Monitoring bind ceremony and disable. |
| `cap_connect` | `"core.connect"` | Peer introduction via the control plane. |
| `cap_cluster` | `"core.cluster"` | Child/subagent lifecycle and contact management. |

The `"core.*"` namespace is reserved; application capabilities use `"app.*"`.
Every node advertises `core.monitoring` — it is governance-required and
auto-present. Adding a new capability means registering a new id string and
wiring its handler; the wire shape is unchanged.

See [Cluster](./cluster.md) for the `core.cluster` verb surface, and
[Monitoring & config](./monitoring-and-config.md) for how `core.monitoring` and
`core.configuration` interact with the hidden gate state in `a2a_messaging`.
